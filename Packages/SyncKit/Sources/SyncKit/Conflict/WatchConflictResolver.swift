// WatchConflictResolver.swift
//
// WP-12b (implementation-plan.md) steps 2-3 / architecture.md D13: the real
// `ConflictFiltering` conformer, installed in the exact seam WP-09 left in
// `SyncEngine` (`conflictFilter:`) and `BackfillCoordinator`. Composes the
// pure classification rules in WatchCoverage.swift with three impure
// concerns this actor owns:
//   1. **Per-run coverage cache** (D13.1): `beginRun` fetches watch-workout
//      windows once per (type, window) sync run via the injected
//      `WatchCoverageProviding` and holds the resulting `WatchCoverageIndex`
//      for every `resolve` call in that run.
//   2. **Retroactive cleanup** (D13.4): also in `beginRun` -- app-written
//      samples/workouts in the run's window that now conflict with coverage
//      are deleted (by external ID, D4's machinery); the run's own re-pull
//      of that same window then re-resolves those points correctly
//      (suppress/split/defer). Late-arriving watch workouts are the norm
//      when the watch was away from the phone.
//   3. **Run bookkeeping**: deferred-session links (external ID → watch
//      workout UUID, applied to `LocalSample.linkedWatchWorkoutUUID` by the
//      caller after its upserts) and the suppressed count ("deferred to
//      Apple Watch" in the sync log).
//
// Its own actor (not MainActor) for the same reason as `SyncEngine`: called
// from `SyncEngine`'s/`BackfillCoordinator`'s hot paths, holds mutable
// per-run state, and every dependency seam it consumes is `nonisolated`/
// `Sendable`. One resolver instance **per pipeline** (one for `SyncEngine`,
// one for `BackfillCoordinator` -- see AppEnvironment.swift): per-run state
// is drained by whichever pipeline began the run, so sharing one instance
// across concurrently-running pipelines would cross-contaminate drains.
//
// Guarded `#if canImport(HealthKit)`: consumes `HealthKitWriter` and
// `MappedObject`'s HK cases directly.
#if canImport(HealthKit)
import CoreModel
import Foundation
import GoogleHealthClient
import HealthKit

public actor WatchConflictResolver: ConflictFiltering {
    /// D13.3's watch-covered stream types -- the only quantity types an
    /// Apple Watch records during a workout at higher fidelity than a
    /// Fitbit: heart rate, active energy, steps, distance. Every other type
    /// (weight, sleep, SpO₂, ...) passes through untouched regardless of
    /// coverage.
    static let coveredStreamTypes: Set<GoogleDataType> = [.heartRate, .steps, .distance, .activeEnergyBurned]
    /// The covered types whose value distributes over the sample's interval
    /// -- splittable at coverage edges with pro-rating (D13.3). Heart rate
    /// is the instantaneous remainder: dropped whole at edges.
    static let cumulativeStreamTypes: Set<GoogleDataType> = [.steps, .distance, .activeEnergyBurned]

    private let coverageProvider: any WatchCoverageProviding
    private let writer: HealthKitWriter
    private let preference: any WatchPriorityPreferenceReading
    private let policy: WatchConflictPolicy

    /// Per-type run state (keyed by the type whose run created it).
    /// Two types sync concurrently inside one pipeline (`SyncEngine.syncAll`
    /// is sequential, but two `sync(type:)` calls for *different* types are
    /// not serialized -- the actor suspends at every await, so a second
    /// type's `beginRun` can land mid-first-run): a single shared slot would
    /// let the second run wipe the first's coverage index and recorded
    /// links. Each entry's index is non-nil only while its run is active
    /// *and* the preference is ON *and* coverage was readable *and* at
    /// least one window exists -- every `resolve` fast-paths to identity
    /// otherwise (D13.5's toggle-OFF behavior falls out of this for free).
    private struct RunState {
        var index: WatchCoverageIndex?
        var deferredSessionLinks: [String: UUID] = [:]
        var suppressedCount = 0
    }
    private var runs: [GoogleDataType: RunState] = [:]

    public init(
        coverageProvider: any WatchCoverageProviding,
        writer: HealthKitWriter,
        preference: any WatchPriorityPreferenceReading = AlwaysOnWatchPriorityPreference(),
        policy: WatchConflictPolicy = .default
    ) {
        self.coverageProvider = coverageProvider
        self.writer = writer
        self.preference = preference
        self.policy = policy
    }

    // MARK: - ConflictFiltering

    /// Refreshes the per-run coverage cache and performs retroactive cleanup
    /// (see this file's header). Error posture, deliberately asymmetric:
    ///   - **Coverage read fails** (e.g. HealthKit read authorization not
    ///     yet granted -- onboarding's very first sync runs before the read
    ///     request): degrade to identity for this run rather than failing
    ///     the sync. The import behaves exactly as it did pre-WP-12b, and
    ///     the next run with readable coverage retroactively cleans up any
    ///     conflicts it left behind -- the same self-correcting D13.4
    ///     mechanism that already handles late-arriving watch workouts.
    ///   - **Cleanup delete fails**: propagate. A conflict we *know* about
    ///     but couldn't remove must fail the run (cursor untouched, safely
    ///     retried) rather than let double-counted data stand silently.
    public func beginRun(
        type: GoogleDataType,
        windowStart: Date,
        windowEnd: Date
    ) async throws(HealthKitWriterError) {
        // Reset THIS type's per-run state unconditionally so a previous
        // run's leftovers (e.g. after a mid-run failure) can never leak
        // into this one -- without touching any concurrently-running type's
        // entry (the shared-slot reset this replaces destroyed in-flight
        // runs of other types mid-stream).
        runs[type] = RunState()

        guard preference.isWatchPriorityEnabled() else { return }

        // Only the four covered stream types (D13.3) and Exercise sessions
        // (D13.2) ever consult the index -- skip the HealthKit coverage
        // query (and cleanup) entirely for the ~20 other types a `syncAll`
        // walks, so watch-priority costs one workout query per *relevant*
        // type per run, not per type.
        guard Self.coveredStreamTypes.contains(type) || type == .exercise else { return }

        // `runs[type]` was just reset above; every path below that resolves
        // coverage writes the index back into it (early returns leave the
        // empty state = identity resolution for this run).

        // Fetch coverage slightly beyond the sync window: a watch workout
        // starting just before `windowStart` still covers (pads into) the
        // window's early samples, and the session tolerance rule can match a
        // workout marginally outside it.
        let slack = policy.coveragePadding + policy.sessionStartEndTolerance
        let windows: [WatchCoverageWindow]
        do {
            windows = try await coverageProvider.watchWorkoutWindows(
                start: windowStart.addingTimeInterval(-slack),
                end: windowEnd.addingTimeInterval(slack)
            )
        } catch {
            return // degrade -- see doc comment
        }

        let index = WatchCoverageIndex(windows: windows, policy: policy)
        guard !index.isEmpty else { return }
        runs[type]?.index = index

        try await retroactiveCleanup(type: type, windowStart: windowStart, windowEnd: windowEnd, index: index)
    }

    public func resolve(_ mapped: MappedObject, for point: GoogleDataPoint) async -> MappedObject {
        guard let index = runs[point.dataType]?.index else { return mapped }

        switch mapped {
        case .workout(let workout):
            // D13.2: a Google Exercise session overlapping a watch workout
            // is never written as an HKWorkout -- it becomes a LocalSample
            // supplement linked to the watch workout (the caller applies the
            // link after its upsert, via drainDeferredSessionLinks).
            guard let match = index.matchingWorkout(forSessionStart: workout.start, end: workout.end) else {
                return mapped
            }
            runs[point.dataType]?.deferredSessionLinks[point.id] = match.workoutUUID
            runs[point.dataType]?.suppressedCount += 1
            return .localOnly

        case .quantity(let sample):
            guard Self.coveredStreamTypes.contains(point.dataType) else { return mapped }
            let cumulative = Self.cumulativeStreamTypes.contains(point.dataType)
            switch index.resolveStream(start: sample.startDate, end: sample.endDate, cumulative: cumulative) {
            case .keep:
                return mapped
            case .suppress:
                runs[point.dataType]?.suppressedCount += 1
                return .skip
            case .split(let slices):
                // Re-derive the pure decision (value/unit/identifier) to
                // rebuild pro-rated part samples -- the HK sample in hand
                // doesn't expose its unit generically. `await`:
                // `TypeMapper.decide` is MainActor-isolated (TypeMapper
                // .swift's header), this actor is not.
                let decision = await TypeMapper.decide(point)
                guard case .quantity(let pure) = decision else {
                    return mapped
                }
                let totalDuration = pure.end.timeIntervalSince(pure.start)
                guard totalDuration > 0 else {
                    runs[point.dataType]?.suppressedCount += 1
                    return .skip
                }
                var parts: [HKQuantitySample] = []
                for slice in slices {
                    var part = pure
                    part.start = slice.start
                    part.end = slice.end
                    part.value = pure.value * (slice.duration / totalDuration)
                    if let hkSample = part.makeHKQuantitySample() {
                        parts.append(hkSample)
                    }
                }
                runs[point.dataType]?.suppressedCount += 1 // partially deferred -- the covered portion
                guard !parts.isEmpty else { return .skip }
                return .quantities(parts)
            }

        case .category, .correlation, .quantities, .localOnly, .skip:
            // Sleep, nutrition, local-only and already-resolved decisions
            // are never watch-covered (D13.3 names exactly four stream
            // types; sleep/vitals are Fitbit's job in the target wear
            // pattern).
            return mapped
        }
    }

    /// Drains one type's recorded links. There is deliberately no
    /// typeless overload: draining without a type would cross-contaminate
    /// concurrently-running types, and a stale conformer implementing only
    /// a typeless drain must fail to compile rather than silently drop
    /// every link and count.
    public func drainDeferredSessionLinks(for type: GoogleDataType) async -> [String: UUID] {
        let links = runs[type]?.deferredSessionLinks ?? [:]
        runs[type]?.deferredSessionLinks = [:]
        // Both drains end the run: release the coverage index here (and in
        // the count drain below -- whichever runs first frees it) so five
        // synced types don't hold five padded coverage windows until their
        // next runs, and a deep-horizon backfill chunk doesn't hold a year
        // of workouts between chunks. Safe: no `resolve` can run after a
        // drain within the same run (drains are the run's last calls).
        runs[type]?.index = nil
        return links
    }

    public func drainSuppressedCount(for type: GoogleDataType) async -> Int {
        let count = runs[type]?.suppressedCount ?? 0
        runs[type]?.suppressedCount = 0
        runs[type]?.index = nil
        return count
    }

    // MARK: - Retroactive cleanup (D13.4)

    private func retroactiveCleanup(
        type: GoogleDataType,
        windowStart: Date,
        windowEnd: Date,
        index: WatchCoverageIndex
    ) async throws(HealthKitWriterError) {
        if Self.coveredStreamTypes.contains(type) {
            // `await`: `.writability` is MainActor-isolated (CoreModel's
            // default isolation) -- same crossing SyncEngine.swift documents.
            let writability = await type.writability
            guard case .healthKit(let identifier) = writability,
                  let sampleType = try? await HealthKitObjectTypeResolver.sampleType(for: identifier)
            else { return }

            // Read failures degrade (same posture as the coverage read in
            // beginRun -- an unreadable store means we can't *find*
            // conflicts, so this run imports as before and the next
            // readable run cleans up); delete failures propagate.
            guard let records = try? await writer.appWrittenSampleRecords(
                type: sampleType, start: windowStart, end: windowEnd
            ) else { return }

            let conflicting = records.filter { index.intersectsPaddedCoverage(start: $0.start, end: $0.end) }
            guard !conflicting.isEmpty else { return }
            try await writer.delete(externalIDs: Set(conflicting.map(\.externalID)), type: sampleType)
        } else if type == .exercise {
            let workoutType = HKObjectType.workoutType()
            guard let records = try? await writer.appWrittenSampleRecords(
                type: workoutType, start: windowStart, end: windowEnd
            ) else { return }

            let conflicting = records.filter {
                index.matchingWorkout(forSessionStart: $0.start, end: $0.end) != nil
            }
            guard !conflicting.isEmpty else { return }

            // The workout's attached distance/energy samples carry the same
            // external-ID stamp (HealthKitWriter.saveWorkout's metadata,
            // D4), so one multi-type delete removes the workout and its
            // attachments together. The sweep covers every distance bucket
            // the writer can emit (HealthKitWriter.distanceIdentifier's
            // non-nil rows) -- sweeping only walkingRunning would leave
            // cycling/swimming/rowing attachments behind as orphans.
            var sweepTypes: [HKObjectType] = [workoutType]
            for identifier in HealthKitWriter.distanceIdentifiersForCleanup {
                if let distanceType = HKObjectType.quantityType(forIdentifier: identifier) {
                    sweepTypes.append(distanceType)
                }
            }
            if let energyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) {
                sweepTypes.append(energyType)
            }
            try await writer.delete(externalIDs: Set(conflicting.map(\.externalID)), types: sweepTypes)
        }
    }
}
#endif
