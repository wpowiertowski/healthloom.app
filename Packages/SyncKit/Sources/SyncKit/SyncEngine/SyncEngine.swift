// SyncEngine.swift
//
// WP-09 (implementation-plan.md): orchestrates pull -> map -> write with
// cursor + lookback (architecture.md D3), per Google data type. Built on
// WP-05's `GoogleReconcileClient` seam (SyncEngineTypes.swift), WP-07's
// `TypeMapper.map(_:)`, and WP-08's `HealthKitWriter` (existingExternalIDs/
// save -- HealthKitWriter.swift already implements D4's batched existence
// diff; this file only calls it, never re-implementing it).
//
// Guarded `#if canImport(HealthKit)`: needs `HKObject`/`HKSampleType` and
// `HealthKitWriter` itself (HealthKitWriter.swift), both HealthKit-only per
// WP-06/07/08's platform boundary -- see those files' headers.
//
// Concurrency (architecture.md §3): `actor SyncEngine` is its own, distinct
// actor -- NOT MainActor, unlike almost everything else in this package
// (`TypeMapper`, `HealthKitObjectTypeResolver`, `HealthKitWriter`, ... all
// inherit SyncKit's `.defaultIsolation(MainActor.self)` package default
// because none of them declares its own isolation). Crossing from this actor
// into any of that MainActor-isolated code -- `type.writability`,
// `HealthKitObjectTypeResolver.sampleType(for:)`, `TypeMapper.map(_:)` --
// therefore needs an explicit `await`, exactly the pattern
// `GoogleHealthClient`'s own `@concurrent fetchPage` already established for
// `type.endpointName` (progress.md's WP-04/05 entry) and that WP-07's
// TypeMapper.swift header explicitly anticipated ("a future actor-isolated
// caller (e.g. WP-09's actor SyncEngine) can still call either function with
// a plain await even though neither is declared async -- standard cross-actor
// call syntax for a synchronous isolated function").

#if canImport(HealthKit)
import CoreModel
import Foundation
import GoogleHealthClient
import HealthKit
import SwiftData

/// Orchestrates the Google -> HealthKit sync pipeline for every
/// `GoogleDataType`, one `SyncState` row per type (implementation-plan.md
/// WP-09).
///
/// **What `itemCount` counts** (WP-09's "decide and document exactly what
/// itemCount counts"): one Google *data point* processed this run, counted
/// exactly once regardless of how many HealthKit samples it expanded into (a
/// multi-stage sleep session is one data point -> one HK category batch ->
/// one item, not N items for N stage segments). A data point contributes to
/// `itemCount` in exactly one of three mutually-exclusive ways:
///   1. **Newly written** to HealthKit -- its external ID was not already
///      present per the batched existence diff (architecture.md D4). A
///      re-synced, already-present point contributes 0 (idempotency: "second
///      run writes 0 new HK objects" never inflates `itemCount` either).
///   2. **`.localOnly` upserted** into `LocalSample` -- every upsert counts,
///      insert or update, since it represents this run re-processing that
///      point (unlike the HK path, `LocalSample`'s upsert has no
///      "already-present, skip" branch here -- WP-14 owns richer per-type
///      upsert semantics later).
///   3. **`.skip`** -- an unmapped/unimplemented/out-of-range point
///      `TypeMapper` dropped (WP-07's "counting out-of-range drops is
///      explicitly deferred to WP-09's SyncEngine" note -- this is that
///      wiring).
/// `SyncState.itemCount` is a **running cumulative total across the type's
/// entire history**, incremented by a run's count only when that run's full
/// window succeeds (see below) -- never reset, never decremented.
///
/// **Cursor semantics** (architecture.md D3): `SyncState.lastSyncedAt` only
/// advances to the run's `window.end` when *every* page of *every* fetch in
/// that run succeeds. Any failure -- a page fetch, an existence check, a
/// save -- leaves `lastSyncedAt` exactly where it was; the next run
/// recomputes the same (or a superset) window from the untouched cursor and
/// safely re-pulls it, relying entirely on D4's idempotent existence diff to
/// avoid duplicate writes for whatever the failed run already wrote.
/// `SyncOutcome.itemCount` on a failed run still reports whatever partial
/// progress was made before the failure (informational), but that partial
/// count is *not* added to the persisted `SyncState.itemCount` -- only a
/// fully-successful run commits its count.
public actor SyncEngine {
    private let client: any GoogleReconcileClient
    private let writer: HealthKitWriter
    private let modelContainer: ModelContainer
    private let clock: any SyncClock
    private let configuration: SyncConfiguration
    private let conflictFilter: any ConflictFiltering
    /// WP-18 (implementation-plan.md) hook point: the **one, minimal,
    /// additive** change this WP makes to this file, following the exact
    /// shape its own brief suggested ("an optional injected
    /// `SyncRunRecording` callback/delegate"). `nil` by default -- every
    /// pre-existing call site (every `SyncEngine(...)` constructed by
    /// WP-09..17's own tests and by `AppEnvironment` before this WP) keeps
    /// compiling and behaving identically; only `AppEnvironment`'s
    /// production wiring (WP-18) actually passes one, via
    /// `SyncEngineLogRecorder` (Diagnostics/SyncRunRecording.swift).
    /// Deliberately *not* a restructure: `performSync` below gains exactly
    /// two `await runRecorder?.record(outcome)` lines, one per existing
    /// return point, nothing else in this file's control flow changes.
    private let runRecorder: (any SyncRunRecording)?

    /// One in-flight `Task` per currently-syncing type (architecture.md §3:
    /// "a `Set<GoogleDataType>` of in-flight types drops duplicate
    /// requests"). Keyed by `Task`, not a bare `Set`, so a *second* concurrent
    /// caller doesn't just get turned away empty-handed -- it awaits the
    /// *same* result the first caller's run produces (WP-09's "coalesce ...
    /// rather than interleave", not merely "drop").
    private var inFlight: [GoogleDataType: InFlightRun] = [:]

    /// A running sync plus the token identifying it. `Task` itself isn't
    /// `Equatable`, so the token is what `clearInFlight` compares: a
    /// completing run only clears the entry it created, never a newer run
    /// stored concurrently (the doc claim the previous `= nil` body did not
    /// actually implement).
    private struct InFlightRun {
        let task: Task<SyncOutcome, Never>
        let runID: UUID
    }

    public init(
        client: any GoogleReconcileClient,
        writer: HealthKitWriter,
        modelContainer: ModelContainer,
        clock: any SyncClock = SystemSyncClock(),
        configuration: SyncConfiguration = SyncConfiguration(),
        conflictFilter: any ConflictFiltering = IdentityConflictFilter(),
        runRecorder: (any SyncRunRecording)? = nil
    ) {
        self.client = client
        self.writer = writer
        self.modelContainer = modelContainer
        self.clock = clock
        self.configuration = configuration
        self.conflictFilter = conflictFilter
        self.runRecorder = runRecorder
    }

    // MARK: - Public API

    /// Sync one type. Concurrent calls for the *same* `type` while a sync is
    /// already running coalesce onto the same in-flight `Task` -- the
    /// pipeline runs exactly once; every caller gets the identical
    /// `SyncOutcome`.
    @discardableResult
    public func sync(type: GoogleDataType) async -> SyncOutcome {
        if let running = inFlight[type] {
            return await running.task.value
        }
        let runID = UUID()
        let task = Task { [self] in
            let outcome = await performSync(type: type)
            // Cleared inside the task, before any waiter resumes: a caller
            // arriving after completion finds no entry and starts a fresh
            // run instead of receiving this run's stale outcome. (Clearing
            // after `await task.value` below used to race that arrival.)
            self.clearInFlight(type, runID: runID)
            return outcome
        }
        inFlight[type] = InFlightRun(task: task, runID: runID)
        return await task.value
    }

    /// Runs every type in `types` **sequentially** (WP-09 step 3:
    /// "predictable quota usage") and always continues past a failing type --
    /// `sync(type:)` never throws, so one type's `.error` outcome can't halt
    /// the loop. Returns one `SyncOutcome` per type, in `types`' order.
    public func syncAll(types: [GoogleDataType]) async -> [SyncOutcome] {
        var results: [SyncOutcome] = []
        results.reserveCapacity(types.count)
        for type in types {
            results.append(await sync(type: type))
        }
        return results
    }

    /// **WP-15 coordination point** (implementation-plan.md WP-15 step 2:
    /// "SyncEngine exposes an `isBusy` signal"): read-only probe over the
    /// existing `inFlight` bookkeeping above -- no new state, no
    /// restructuring, just a public accessor for a fact this actor already
    /// tracks. `BackfillCoordinator` (`Backfill/BackfillCoordinator.swift`)
    /// polls this before pulling a chunk for `type` so a historical backfill
    /// never races a foreground/background incremental sync of the same
    /// type. Flagged here since WP-16 (background sync) may also want to
    /// read `SyncEngine`'s in-flight state for its own scheduling decisions --
    /// this method is additive and safe for either WP to call.
    public func isBusy(for type: GoogleDataType) -> Bool {
        inFlight[type] != nil
    }

    /// Task-side completion of the `inFlight` entry (see `sync(type:)`).
    /// Identity-checked: only clears if the stored entry is still this
    /// run's, so a newer run stored concurrently is never wiped. (Without
    /// the check, a `performSync` tail gaining an `await` -- or a detached
    /// task -- would let a completing run A clear run B's entry, and
    /// `isBusy(for:)` would lie to `BackfillCoordinator` mid-flight.)
    private func clearInFlight(_ type: GoogleDataType, runID: UUID) {
        guard inFlight[type]?.runID == runID else { return }
        inFlight[type] = nil
    }

    // MARK: - Per-type pipeline

    private func performSync(type: GoogleDataType) async -> SyncOutcome {
        let context = ModelContext(modelContainer)
        let now = clock.now()
        let syncState = fetchOrCreateSyncState(for: type, context: context)

        let lookback = configuration.lookback(for: type)
        let baseline = syncState.lastSyncedAt ?? now.addingTimeInterval(-configuration.initialWindow)
        let windowStart = baseline.addingTimeInterval(-lookback)
        let windowEnd = now

        // `await`: `.writability` is a MainActor-isolated computed property
        // (CoreModel's `.defaultIsolation(MainActor.self)`), and this actor
        // is not MainActor -- see this file's header.
        let writability = await type.writability
        var hkSampleType: HKSampleType?
        if case .healthKit(let identifier) = writability {
            hkSampleType = try? await HealthKitObjectTypeResolver.sampleType(for: identifier)
        } else {
            hkSampleType = nil
        }

        var totalItemCount = 0
        do {
            // WP-12b: give the conflict filter its per-run window *before*
            // the existence query below -- the real resolver
            // (`WatchConflictResolver`) refreshes its watch-coverage cache
            // here and performs D13.4's retroactive cleanup (deleting
            // app-written objects that now conflict with coverage), so the
            // existence snapshot taken next already reflects those
            // deletions and the run's own re-pull re-resolves the affected
            // points. The default `IdentityConflictFilter` no-ops.
            try await conflictFilter.beginRun(type: type, windowStart: windowStart, windowEnd: windowEnd)

            var knownExternalIDs: Set<String> = []
            if let hkSampleType {
                // One batched existence query per (type, window) --
                // architecture.md D4's invariant, computed once up front
                // (not re-queried per page) and threaded through
                // `processPage` so a point appearing in more than one page of
                // the same window still can't be double-written within a
                // single run.
                knownExternalIDs = try await writer.existingExternalIDs(
                    type: hkSampleType, start: windowStart, end: windowEnd
                )
            }

            var pageToken: String?
            repeat {
                let page = try await client.reconcile(
                    type: type, since: windowStart, until: windowEnd, pageToken: pageToken
                )
                totalItemCount += try await processPage(
                    page.points,
                    knownExternalIDs: &knownExternalIDs,
                    context: context
                )
                pageToken = page.nextPageToken
            } while pageToken != nil

            // WP-12b: apply deferred-session links (external ID -> watch
            // workout UUID) to the LocalSample rows the pages above
            // upserted -- the resolver records the link at `resolve` time,
            // but the row only exists after `upsertLocalSample` ran
            // (fetches see pending inserts in the same context). Identity
            // filter drains nothing.
            applyDeferredSessionLinks(await conflictFilter.drainDeferredSessionLinks(for: type), context: context)
            let suppressedCount = await conflictFilter.drainSuppressedCount(for: type)

            // Full window succeeded (every page fetched, mapped, and
            // written/upserted without throwing) -- advance the cursor and
            // commit this run's count.
            syncState.lastSyncedAt = windowEnd
            syncState.lastStatus = SyncStatus.ok.rawValue
            syncState.lastError = nil
            syncState.itemCount += totalItemCount
            do {
                try context.save()
            } catch {
                // A save failure leaves lastSyncedAt where it was (the
                // in-memory cursor advance above dies with this context):
                // report the failure instead of an `.ok` nothing was
                // persisted under.
                // Raw description here, redacted once at the catch
                // below (the documented D11 boundary) -- redacting at both
                // layers just burns regex passes and hides the ownership.
                throw HealthKitWriterError.underlying(String(describing: error))
            }
            let outcome = SyncOutcome(
                dataType: type, status: .ok, itemCount: totalItemCount, suppressedCount: suppressedCount
            )
            await runRecorder?.record(outcome) // WP-18: additive diagnostics hook, see this actor's `runRecorder` doc comment.
            return outcome
        } catch {
            // Roll back FIRST: the success path above may have thrown out of
            // its own `context.save()` with `lastSyncedAt` already advanced
            // in memory -- without this, the error-row save below would
            // commit that cursor advance anyway and the failed window would
            // never be re-pulled. Rollback also discards this run's
            // `LocalSample` upserts (re-pulled idempotently next run); the
            // resolver's actor-side drains below are unaffected. A rollback
            // on a context with nothing pending (mid-pipeline failures) is
            // a harmless no-op.
            context.rollback()
            // Re-acquire after the rollback: it may have undone
            // `fetchOrCreateSyncState`'s insert on a first-ever sync.
            let syncState = fetchOrCreateSyncState(for: type, context: context)

            // WP-12b: same drains on the failure path -- draining the count
            // both reports partial progress and resets the resolver's state
            // so nothing leaks into the next run. (Links drain too, but
            // their rows were rolled back above, so they drop silently per
            // `applyDeferredSessionLinks`' contract and are re-recorded on
            // the re-pull.)
            applyDeferredSessionLinks(await conflictFilter.drainDeferredSessionLinks(for: type), context: context)
            let suppressedCount = await conflictFilter.drainSuppressedCount(for: type)

            // Cancellation is a stop, not a failure: no error status, no
            // message, cursor untouched -- the next run retries the same
            // window. (Without this branch a routine expiration-handler
            // cancel paints a red dashboard row for the system doing its
            // job.)
            if error is CancellationError || (error as? GoogleHealthClientError) == .cancelled {
                // Status moves, message stays: a previous run's genuine
                // error is evidence for the user/support, and a stop
                // resolves nothing about it. Clearing it here would trade
                // the red row for silent amnesia.
                syncState.lastStatus = SyncStatus.cancelled.rawValue
                try? context.save()
                let stopped = SyncOutcome(
                    dataType: type, status: .cancelled, itemCount: totalItemCount,
                    suppressedCount: suppressedCount
                )
                await runRecorder?.record(stopped)
                return stopped
            }

            // Partial-window failure: `lastSyncedAt` is deliberately left
            // untouched (architecture.md D3) so the *entire* window --
            // including whatever pages already succeeded this run -- is
            // safely re-pulled next time; idempotent existence-diff means
            // re-processing already-written pages costs nothing but a query.
            // Redacted (architecture.md D11, SyncState.lastError's own
            // doc): pipeline errors can embed bearer tokens or
            // authenticated URLs; the sync-log path already redacts via
            // SyncLogRedactor -- this persisted/UI-rendered path must too.
            let message = SyncLogRedactor.redact(String(describing: error))
            syncState.lastStatus = SyncStatus.error.rawValue
            syncState.lastError = message
            try? context.save()
            let outcome = SyncOutcome(
                dataType: type,
                status: .error,
                itemCount: totalItemCount,
                suppressedCount: suppressedCount,
                errorMessage: message
            )
            await runRecorder?.record(outcome) // WP-18: additive diagnostics hook, see this actor's `runRecorder` doc comment.
            return outcome
        }
    }

    /// Maps, conflict-filters, batches, and writes/upserts every point in one
    /// page. `knownExternalIDs` is threaded through by `inout` (rather than
    /// re-queried per page) so the existence check genuinely happens once
    /// per (type, window) -- D4's invariant, met even more strictly than
    /// "once per page".
    private func processPage(
        _ points: [GoogleDataPoint],
        knownExternalIDs: inout Set<String>,
        context: ModelContext
    ) async throws -> Int {
        var batch: [HKObject] = []
        var newExternalIDs: [String] = []
        var localOnlyPoints: [GoogleDataPoint] = []
        var skipCount = 0
        var workoutCount = 0

        for point in points {
            // `await`: `TypeMapper.map(_:)` is MainActor-isolated (see this
            // file's header); `conflictFilter.resolve` is declared `async`
            // regardless of isolation (SyncEngineTypes.swift).
            let mapped = await conflictFilter.resolve(await TypeMapper.map(point), for: point)
            switch mapped {
            case .quantity(let sample):
                guard !knownExternalIDs.contains(point.id) else { continue }
                batch.append(sample)
                newExternalIDs.append(point.id)
            case .quantities(let samples):
                // WP-12b: a cumulative sample split at watch-coverage edges
                // (`WatchConflictResolver`, architecture.md D13.3) -- N part
                // samples for one point, all sharing `point.id`'s external-ID
                // metadata, exactly `.category`'s existing one-point-many-
                // samples shape. One point, one itemCount contribution.
                guard !knownExternalIDs.contains(point.id) else { continue }
                batch.append(contentsOf: samples)
                newExternalIDs.append(point.id)
            case .category(let samples):
                guard !knownExternalIDs.contains(point.id) else { continue }
                batch.append(contentsOf: samples)
                newExternalIDs.append(point.id)
            case .correlation(let correlation):
                // WP-13 addition (coordination note: this arm was added
                // alongside WP-14's concurrent SyncKit work -- see
                // progress.md's WP-13 entry). Unlike `.workout` below, an
                // `HKCorrelation` is itself a plain `HKObject`/`HKSample`
                // (built synchronously by `TypeMapper.map(_:)` -- see
                // MappedObject.swift's `MappedNutritionCorrelation
                // .makeHKCorrelation()`), so it slots into the exact same
                // batch/existence-diff path as `.quantity`/`.category`
                // above -- no parallel dedupe or save mechanism, per WP-13's
                // explicit "verify this, don't build a parallel mechanism"
                // instruction.
                guard !knownExternalIDs.contains(point.id) else { continue }
                batch.append(correlation)
                newExternalIDs.append(point.id)
            case .workout(let workout):
                // WP-12b: the follow-up WP-12 flagged, now wired. A workout
                // reaching this arm has already passed D13's conflict
                // resolution (the `conflictFilter.resolve` call above
                // downgrades watch-covered sessions to `.localOnly` before
                // they ever get here), so anything left is a genuine
                // Fitbit-only activity. Dedupe uses the exact same
                // per-(type, window) existence set as every other arm --
                // `knownExternalIDs` was queried against
                // `HKObjectType.workoutType()` for `.exercise` runs (the
                // writability table's `"HKWorkoutType"` sentinel resolves to
                // it); only the *write* path differs, unavoidably:
                // `HKWorkoutBuilder.finishWorkout()` saves directly to the
                // store (HealthKitWriter.swift's `saveWorkout` doc comment),
                // so a saved workout is inserted into `knownExternalIDs`
                // immediately rather than batched.
                guard !knownExternalIDs.contains(point.id) else { continue }
                _ = try await writer.saveWorkout(workout)
                knownExternalIDs.insert(point.id)
                workoutCount += 1
            case .localOnly:
                localOnlyPoints.append(point)
            case .skip:
                skipCount += 1
            }
        }

        if !batch.isEmpty {
            try await writer.save(batch)
            knownExternalIDs.formUnion(newExternalIDs)
        }

        for point in localOnlyPoints {
            upsertLocalSample(for: point, context: context)
        }

        return newExternalIDs.count + workoutCount + localOnlyPoints.count + skipCount
    }

    /// WP-12b (architecture.md D13.2): stamp `LocalSample.linkedWatchWorkoutUUID`
    /// for every session the run's conflict filter deferred to a watch
    /// workout. Fetch-by-externalID sees the rows `upsertLocalSample`
    /// inserted earlier in this same context (pending inserts are visible to
    /// `FetchDescriptor` by default). A link whose row is missing (e.g. the
    /// page that would have upserted it failed mid-run) is dropped silently
    /// -- the window is fully re-pulled next run and the link re-recorded.
    private func applyDeferredSessionLinks(_ links: [String: UUID], context: ModelContext) {
        guard !links.isEmpty else { return }
        for (externalID, workoutUUID) in links {
            let descriptor = FetchDescriptor<LocalSample>(predicate: #Predicate { $0.externalID == externalID })
            if let sample = try? context.fetch(descriptor).first {
                sample.linkedWatchWorkoutUUID = workoutUUID
            }
        }
    }

    // MARK: - SwiftData bookkeeping

    private func fetchOrCreateSyncState(for type: GoogleDataType, context: ModelContext) -> SyncState {
        // `.rawValue`, not `.filterName` -- identical string value, but
        // `.rawValue` is compiler-synthesized and so isn't subject to
        // CoreModel's `.defaultIsolation(MainActor.self)` inference the way
        // `.filterName` (a hand-written computed property) is -- the same
        // substitution `GoogleHealthClient`'s data client and `TypeMapper`
        // already made for the same reason (progress.md's WP-04/05 entry).
        let key = type.rawValue
        let descriptor = FetchDescriptor<SyncState>(predicate: #Predicate { $0.dataType == key })
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }
        let created = SyncState(dataType: key)
        context.insert(created)
        return created
    }

    /// Upserts by `externalID` (WP-09 step 4). Fetches any existing row
    /// first -- rather than blindly inserting a fresh `LocalSample` and
    /// relying on SwiftData's `.unique`-attribute upsert behavior (confirmed
    /// last-write-wins by WP-02's own tests) -- specifically so
    /// `linkedWatchWorkoutUUID` (set later by WP-12b's `ConflictResolver`,
    /// architecture.md D13.2) is never silently wiped back to `nil` by a
    /// routine re-sync of the same point.
    private func upsertLocalSample(for point: GoogleDataPoint, context: ModelContext) {
        let externalID = point.id
        let payload = SyncEngineLocalPayload(point: point)
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
}

/// Minimal, self-contained JSON shape for `LocalSample.payloadJSON` -- WP-09
/// only needs *a* full-fidelity encoding to satisfy "route .localOnly to
/// LocalSample upsert"; WP-14 (implementation-plan.md) owns the real
/// per-type payload schema/decoding for the in-app "Not in Apple Health"
/// badge rows and may replace this shape entirely. Deliberately `private` to
/// this file -- nothing else in SyncKit depends on its exact fields.
nonisolated private struct SyncEngineLocalPayload: Codable {
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
