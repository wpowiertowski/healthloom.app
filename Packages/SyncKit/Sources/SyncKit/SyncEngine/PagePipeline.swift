// PagePipeline.swift
//
// Shared page pipeline (round-4-sync item 15): the pull→map→write/upsert
// core `SyncEngine.processPage` and `BackfillCoordinator.processPage`
// duplicated verbatim (~140 lines each; drift had already started —
// comment-only divergence today, logic divergence tomorrow). ONE
// implementation used by BOTH: points + knownExternalIDs in,
// `PageProcessing` out. Round-4-sync item 6's within-page
// check-then-insert lives here — fixed once, both engines inherit.
//
// Isolation boundary, stated exactly: `ModelContext` is executor-bound,
// so the pipeline never takes one. `processPage` maps, filters, batches,
// and writes (all `Sendable` values plus `await`ed MainActor deps) and
// returns the `.localOnly` points for the CALLER to upsert on its own
// executor via the static helpers below (both `sync`, so they run where
// the caller runs). `PagePipeline` itself is stateless + `Sendable` —
// each engine constructs one per call from deps it already holds, so no
// init changes were needed on either side.

#if canImport(HealthKit)
import CoreModel
import Foundation
import GoogleHealthClient
import HealthKit
import SwiftData

/// What one page produced: the count contract is WP-09's, unchanged —
/// one Google data point contributes exactly once (written, upserted, or
/// skipped); a multi-sample expansion still counts one.
nonisolated struct PageProcessing: Sendable {
    /// External IDs newly written to HealthKit this page (count only —
    /// the shared set already absorbed them; see `processPage`).
    var writtenCount: Int
    /// Points the caller must upsert via `upsertLocalSample` (its own
    /// executor) before counting this page done.
    var localOnlyPoints: [GoogleDataPoint]
    var workoutCount: Int
    var skipCount: Int
    var itemCount: Int {
        writtenCount + workoutCount + localOnlyPoints.count + skipCount
    }
}

nonisolated struct PagePipeline: Sendable {
    let conflictFilter: any ConflictFiltering
    let writer: HealthKitWriter

    /// Maps, conflict-filters, batches, and writes/upserts every point in
    /// one page. `knownExternalIDs` is the per-(type, window) existence
    /// set, threaded by `inout` (never re-queried per page — D4's
    /// invariant); it is committed only on success (see below).
    ///
    /// Within-page duplicates (round-4-sync item 6): every arm
    /// check-then-INSERTS per point within the loop, so the same
    /// `point.id` twice in one page writes + counts once — the old shape
    /// (union only after the page save) double-wrote and double-counted,
    /// violating the exactly-once contract the header claims.
    ///
    /// Failure semantics, preserved exactly: the loop works on a LOCAL
    /// copy committed to the caller's set only after the batch save
    /// succeeds. A throwing save therefore leaves the caller's set
    /// untouched — same as the old post-save-union shape — so a retried
    /// window re-pulls the failed points instead of skipping them as
    /// "known". (The `.workout` arm saves directly per point, exactly as
    /// before: a workout written before a later throw stays written —
    /// the retry's fresh existence query finds it, same as before.)
    func processPage(
        _ points: [GoogleDataPoint],
        knownExternalIDs: inout Set<String>
    ) async throws -> PageProcessing {
        var known = knownExternalIDs
        var batch: [HKObject] = []
        var writtenCount = 0
        var localOnlyPoints: [GoogleDataPoint] = []
        var skipCount = 0
        var workoutCount = 0

        for point in points {
            // `await`: `TypeMapper.map(_:)` is MainActor-isolated;
            // `conflictFilter.resolve` is declared `async` regardless of
            // isolation (SyncEngineTypes.swift).
            let mapped = await conflictFilter.resolve(await TypeMapper.map(point), for: point)
            switch mapped {
            case .quantity(let sample):
                guard !known.contains(point.id) else { continue }
                known.insert(point.id)
                batch.append(sample)
                writtenCount += 1
            case .quantities(let samples):
                // A cumulative sample split at watch-coverage edges
                // (architecture.md D13.3) — N part samples for one point,
                // all sharing `point.id`'s external-ID metadata. One
                // point, one itemCount contribution.
                guard !known.contains(point.id) else { continue }
                known.insert(point.id)
                batch.append(contentsOf: samples)
                writtenCount += 1
            case .category(let samples):
                guard !known.contains(point.id) else { continue }
                known.insert(point.id)
                batch.append(contentsOf: samples)
                writtenCount += 1
            case .correlation(let correlation):
                // An `HKCorrelation` is itself a plain
                // `HKObject`/`HKSample` built synchronously by
                // `TypeMapper.map(_:)` — same batch/existence-diff path
                // as every other arm, no parallel mechanism.
                guard !known.contains(point.id) else { continue }
                known.insert(point.id)
                batch.append(correlation)
                writtenCount += 1
            case .workout(let workout):
                // Unavoidably write-direct: `HKWorkoutBuilder`
                // saves the workout itself, so it never flows through
                // `writer.save(_:)` — but the idempotency *mechanism* is
                // identical (query-side existence diff, same set).
                // Anything reaching here already passed D13's conflict
                // resolution above.
                guard !known.contains(point.id) else { continue }
                _ = try await writer.saveWorkout(workout)
                known.insert(point.id)
                workoutCount += 1
            case .localOnly:
                localOnlyPoints.append(point)
            case .skip:
                skipCount += 1
            }
        }

        if !batch.isEmpty {
            try await writer.save(batch)
        }
        knownExternalIDs = known
        return PageProcessing(
            writtenCount: writtenCount,
            localOnlyPoints: localOnlyPoints,
            workoutCount: workoutCount,
            skipCount: skipCount
        )
    }

    /// Upserts by `externalID`: fetches any existing row first — never a
    /// blind reinsert — so `linkedWatchWorkoutUUID` (set later by WP-12b's
    /// conflict resolution, architecture.md D13.2) is never wiped back to
    /// `nil` by a routine re-sync re-touching the same point. `sync`: call
    /// on the executor that owns `context`.
    static func upsertLocalSample(for point: GoogleDataPoint, context: ModelContext) {
        let externalID = point.id
        let payload = SharedLocalPayload(point: point)
        let payloadJSON = (try? JSONEncoder().encode(payload)) ?? Data()
        let sourceLabel = point.source.deviceDisplayName ?? point.source.platform ?? "unknown"
        let dataTypeKey = point.dataType.rawValue

        let descriptor = FetchDescriptor<LocalSample>(predicate: #Predicate { $0.externalID == externalID })
        if let existing = try? context.fetch(descriptor).first {
            existing.dataType = dataTypeKey
            existing.payloadJSON = payloadJSON
            existing.start = point.start
            existing.end = point.end
            existing.source = sourceLabel
        } else {
            context.insert(
                LocalSample(
                    externalID: externalID,
                    dataType: dataTypeKey,
                    payloadJSON: payloadJSON,
                    start: point.start,
                    end: point.end,
                    source: sourceLabel
                )
            )
        }
    }

    /// Stamps `LocalSample.linkedWatchWorkoutUUID` for every session the
    /// run's conflict filter deferred to a watch workout. Fetch-by-
    /// externalID sees rows `upsertLocalSample` inserted earlier in the
    /// same context (pending inserts are visible by default). A link
    /// whose row is missing is dropped silently — the window is fully
    /// re-pulled next run and the link re-recorded. `sync`: call on the
    /// executor that owns `context`.
    static func applyDeferredSessionLinks(_ links: [String: UUID], context: ModelContext) {
        guard !links.isEmpty else { return }
        for (externalID, workoutUUID) in links {
            let descriptor = FetchDescriptor<LocalSample>(predicate: #Predicate { $0.externalID == externalID })
            if let sample = try? context.fetch(descriptor).first {
                sample.linkedWatchWorkoutUUID = workoutUUID
            }
        }
    }
}

/// Minimal, self-contained JSON shape for `LocalSample.payloadJSON` — the
/// field-identical union of `SyncEngine`'s `SyncEngineLocalPayload` and
/// `BackfillCoordinator`'s `BackfillLocalPayload` (same fields, same
/// order, so encoded bytes are unchanged — see the payload-shape test).
/// WP-14 owns the real per-type payload schema and may replace this shape
/// entirely; until then there is exactly one of it.
nonisolated struct SharedLocalPayload: Codable {
    var id: String
    var dataType: String
    var start: Date
    var end: Date
    var values: [String: Double]
    var sessionPayload: Data?
    var sourcePlatform: String?
    var sourceDeviceDisplayName: String?
    var sourceRecordingMethod: String?

    init(point: GoogleDataPoint) {
        self.id = point.id
        self.dataType = point.dataType.rawValue
        self.start = point.start
        self.end = point.end
        self.values = point.values
        self.sessionPayload = point.sessionPayload
        self.sourcePlatform = point.source.platform
        self.sourceDeviceDisplayName = point.source.deviceDisplayName
        self.sourceRecordingMethod = point.source.recordingMethod
    }
}
#endif
