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
/// entire history**, incremented by each span's count when that span
/// commits (see below) -- never reset, never decremented.
///
/// **Cursor semantics** (architecture.md D3, WP-52): a run's window is
/// walked in `SyncConfiguration.chunkSpan` pieces, oldest first.
/// `SyncState.lastSyncedAt` advances to a span's end only when *every* page
/// of that span succeeds and its rows are saved. Any failure -- a page
/// fetch, an existence check, a save -- leaves `lastSyncedAt` at the last
/// committed span (or where the run found it); the next run recomputes its
/// window from there, one lookback earlier, and safely re-pulls, relying on
/// D4's idempotent existence diff to avoid duplicate writes for whatever
/// the failed span already wrote. `SyncOutcome.itemCount` on a failed run
/// reports all progress made before the failure (informational); only the
/// committed spans' counts reach the persisted `SyncState.itemCount`.
public actor SyncEngine {
    private let client: any GoogleReconcileClient
    private let writer: HealthKitWriter
    private let modelContainer: ModelContainer
    private let clock: any SyncClock
    private let configuration: SyncConfiguration
    private let conflictFilter: any ConflictFiltering
    /// Round-4-sync item 5: the HealthKit type resolver, injected so a
    /// resolution failure is testable. Default is the real static
    /// resolver; tests inject a thrower to prove the failure surfaces
    /// (error status + non-ok outcome, zero writes) instead of `try?`'ing
    /// into a silent green run.
    /// Quiesce probe (third-party r9: the wipe latch — a post-wipe `syncAll` would
    /// resurrect HealthKit samples the wipe deleted and write store rows through
    /// the unlinked handle). Init-injected (default inert) so tests script it.
    /// Checked in `sync(type:)` — the single choke point `syncAll` funnels through.
    private let isQuiesced: @Sendable () -> Bool
    private let sampleTypeResolver: @Sendable @MainActor (String) throws(UnresolvedHealthKitIdentifier) -> HKSampleType
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

    /// Types a backfill chunk holds (`claimForBackfill(_:)`), and the
    /// `sync(type:)` callers waiting for each to be released.
    private var backfillClaims: Set<GoogleDataType> = []
    private var claimWaiters: [GoogleDataType: [UUID: CheckedContinuation<Void, Never>]] = [:]

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
        runRecorder: (any SyncRunRecording)? = nil,
        sampleTypeResolver: @escaping @Sendable @MainActor (String) throws(UnresolvedHealthKitIdentifier) -> HKSampleType = HealthKitObjectTypeResolver.sampleType,
        isQuiesced: @escaping @Sendable () -> Bool = { false }
    ) {
        self.client = client
        self.writer = writer
        self.modelContainer = modelContainer
        self.clock = clock
        self.configuration = configuration
        self.conflictFilter = conflictFilter
        self.runRecorder = runRecorder
        self.sampleTypeResolver = sampleTypeResolver
        self.isQuiesced = isQuiesced
    }

    // MARK: - Public API

    /// Sync one type. Concurrent calls for the *same* `type` while a sync is
    /// already running coalesce onto the same in-flight `Task` -- the
    /// pipeline runs exactly once; every caller gets the identical
    /// `SyncOutcome`.
    @discardableResult
    public func sync(type: GoogleDataType) async -> SyncOutcome {
        // Third-party r9: quiesced (wipe latched, relaunch pending) — a stop, not
        // a failure. Checked before the coalesce map so a post-wipe Sync Now
        // returns stopped without touching HealthKit or the store.
        if isQuiesced() {
            return SyncOutcome(dataType: type, status: .cancelled, itemCount: 0)
        }
        if let running = inFlight[type] {
            return await running.task.value
        }
        // WP-58: a backfill chunk claimed this type -- wait for it to
        // finish instead of writing the same overlap window alongside it
        // (each pipeline diffs against its own existence snapshot, so both
        // would write the shared points). Re-checked after every wait: the
        // actor is reentrant, so another caller may have started the run.
        while backfillClaims.contains(type) {
            await waitForBackfillRelease(of: type)
            if Task.isCancelled || isQuiesced() {
                return SyncOutcome(dataType: type, status: .cancelled, itemCount: 0)
            }
            if let running = inFlight[type] {
                return await running.task.value
            }
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
        // WP-58: the run is an unstructured task (so coalesced callers can
        // share it), which cancellation does not reach on its own. Forward
        // the starting caller's cancellation -- the background expiration
        // handler's -- so the walk stops at its next span or page instead
        // of running past the system's deadline. A coalesced caller's
        // cancellation isn't forwarded: the run belongs to its starter.
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Runs every type in `types`, `SyncSchedule.maxConcurrentTypes` at a
    /// time (WP-63; sequential before, for WP-09's "predictable quota
    /// usage" -- a small fixed bound keeps that), and always continues past
    /// a failing type -- `sync(type:)` never throws, so one type's `.error`
    /// outcome can't halt the rest. Returns one `SyncOutcome` per type, in
    /// `types`' order.
    public func syncAll(types: [GoogleDataType]) async -> [SyncOutcome] {
        await SyncSchedule.run(types) { type in await self.sync(type: type) }
    }

    /// WP-58: deletes the extra copies of `type`'s samples this app wrote
    /// more than once, across all time, and returns how many it deleted
    /// (0 for a type that doesn't write to HealthKit). A one-time repair
    /// for the day-keyed summaries the pre-WP-58 span loop wrote twice;
    /// the app runs it once per install.
    public func removeDuplicateWrites(of type: GoogleDataType) async throws -> Int {
        guard case .healthKit(let identifier) = await type.writability else { return 0 }
        let sampleType = try await sampleTypeResolver(identifier)
        return try await writer.deleteDuplicateWrites(type: sampleType)
    }

    /// **WP-15 coordination point, made a claim in WP-58.**
    /// `BackfillCoordinator` claims `type` before pulling a chunk and
    /// releases it after. The claim is atomic on this actor: it fails while
    /// an incremental run of `type` is in flight, and while it's held
    /// `sync(type:)` waits instead of starting. (The WP-15 read-only
    /// `isBusy` probe was checked once before a minutes-long chunk; an
    /// incremental run starting after the check wrote the same overlap
    /// window concurrently.)
    public func claimForBackfill(_ type: GoogleDataType) -> Bool {
        guard inFlight[type] == nil, !backfillClaims.contains(type) else { return false }
        backfillClaims.insert(type)
        return true
    }

    /// Ends a `claimForBackfill(_:)` claim and wakes every `sync(type:)`
    /// waiting on it.
    public func releaseBackfillClaim(_ type: GoogleDataType) {
        backfillClaims.remove(type)
        for waiter in (claimWaiters.removeValue(forKey: type) ?? [:]).values {
            waiter.resume()
        }
    }

    /// Suspends until `type`'s backfill claim is released or the caller is
    /// cancelled. The cancellation hop may land before the waiter is
    /// registered; the registration re-checks `Task.isCancelled`, so the
    /// waiter can't be stranded.
    private func waitForBackfillRelease(of type: GoogleDataType) async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled || !backfillClaims.contains(type) {
                    continuation.resume()
                } else {
                    claimWaiters[type, default: [:]][waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.resumeClaimWaiter(waiterID, of: type) }
        }
    }

    private func resumeClaimWaiter(_ waiterID: UUID, of type: GoogleDataType) {
        claimWaiters[type]?.removeValue(forKey: waiterID)?.resume()
    }

    /// Task-side completion of the `inFlight` entry (see `sync(type:)`).
    /// Identity-checked: only clears if the stored entry is still this
    /// run's, so a newer run stored concurrently is never wiped. (Without
    /// the check, a `performSync` tail gaining an `await` -- or a detached
    /// task -- would let a completing run A clear run B's entry, and
    /// `claimForBackfill(_:)` would admit a chunk mid-flight.)
    private func clearInFlight(_ type: GoogleDataType, runID: UUID) {
        guard inFlight[type]?.runID == runID else { return }
        inFlight[type] = nil
    }

    // MARK: - Per-type pipeline

    private func performSync(type: GoogleDataType) async -> SyncOutcome {
        let context = ModelContext(modelContainer)
        let now = clock.now()

        let lookback = configuration.lookback(for: type)
        let windowEnd = now
        // Third-party r9: cursor fetch throws (never `try?`) — a fetch failure fails
        // the run as an error outcome with the cursor untouched, never a silent
        // duplicate row. Early return (not the pipeline catch): nothing ran yet.
        let syncState: SyncState
        do {
            syncState = try fetchOrCreateSyncState(for: type, context: context)
        } catch {
            let message = SyncLogRedactor.redact(String(describing: error))
            return SyncOutcome(dataType: type, status: .error, itemCount: 0, errorMessage: message)
        }
        let baseline = syncState.lastSyncedAt ?? now.addingTimeInterval(-configuration.initialWindow)
        let windowStart = baseline.addingTimeInterval(-lookback)

        // `await`: `.writability` is a MainActor-isolated computed property
        // (CoreModel's `.defaultIsolation(MainActor.self)`), and this actor
        // is not MainActor -- see this file's header.
        let writability = await type.writability

        var totalItemCount = 0
        var totalSkipped = 0
        do {
            var hkSampleType: HKSampleType?
            if case .healthKit(let identifier) = writability {
                // Round-4-sync item 5: resolution failure THROWS into
                // this run's catch (error status + `.failed`, zero
                // writes — nothing below has run yet). The old `try?`
                // swallowed it into `nil`, and the run then rewrote
                // the whole window reporting green `.ok`.
                hkSampleType = try await sampleTypeResolver(identifier)
            }
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

            // WP-52: a dense type's window is walked one `chunkSpan` at a
            // time (WP-63: other types in one piece, `chunks(for:)`), oldest
            // first, and each completed span commits its rows AND the
            // cursor (`lastSyncedAt` = the span's end) before the next
            // begins. An interrupted run -- cancelled, suspended, killed,
            // or failed -- keeps every finished day; the next run resumes
            // one lookback before the last committed span. (One whole-window
            // walk restarted from zero every run and never finished a first
            // heart-rate sync, and a page-cap hit advanced the cursor past
            // the unwalked remainder.)
            for chunk in configuration.chunks(for: type, from: windowStart, to: windowEnd) {
                // Re-checked per span, not just at `sync(type:)`'s door: a
                // dense first sync runs for minutes, and a wipe latched
                // mid-run must not let the remaining days write behind it.
                // Thrown as a cancellation -- the stop-not-failure branch
                // below, cursor at the last committed span.
                if isQuiesced() { throw CancellationError() }
                // WP-58: a cancelled caller (background expiry) stops at the
                // span boundary too, not only at the next page fetch.
                try Task.checkCancellation()
                // Round-6 item 8: the bounded shared walk (same-token
                // break, page cap, cancellation probe — see PagePipeline).
                // `.localOnly` upserts stay on this executor (round-10 item
                // 14: the pipeline resumes off-actor after its awaits, and
                // `ModelContext` is not thread-safe — context work never
                // crosses into it). A throwing page propagates
                // `PageWalkPartial` to the run's catch below, which commits
                // the completed pages' rows there; earlier spans are
                // already saved.
                let walked = try await PagePipeline(conflictFilter: conflictFilter, writer: writer)
                    .processPages(knownExternalIDs: knownExternalIDs) { token in
                        try await client.reconcile(
                            type: type, since: chunk.start, until: chunk.end, pageToken: token
                        )
                    }
                // Round-8 item 13: throws on unencodable payloads (no
                // silent zero-byte rows) — into the run's existing failure
                // path (cursor at the last committed span, error surfaced).
                // One batch per span (WP-68).
                try PagePipeline.upsertLocalSamples(walked.localOnly, context: context)
                totalItemCount += walked.total
                totalSkipped += walked.skipped
                // WP-58: this span's writes are known to the next span (see
                // `PagePipeline.processPages`).
                knownExternalIDs = walked.known
                // A span past the cap (100 pages in one day) is
                // pathological; its remainder is recovered only through
                // lookback overlap on later runs, so say so loudly.
                if walked.hitPageCap {
                    DiagnosticsLog.sync.notice(
                        "Page cap (\(PagePipeline.maxPages, privacy: .public)) hit for \(String(describing: type), privacy: .public) in one span — partial span committed; remainder beyond lookback overlap will not be revisited."
                    )
                }

                // WP-12b: apply deferred-session links (external ID -> watch
                // workout UUID) to the LocalSample rows this span upserted
                // -- the resolver records the link at `resolve` time, but
                // the row only exists after `upsertLocalSample` ran
                // (fetches see pending inserts in the same context).
                // Identity filter drains nothing.
                PagePipeline.applyDeferredSessionLinks(await conflictFilter.drainDeferredSessionLinks(for: type), context: context)

                // Span succeeded (every page fetched, mapped, and
                // written/upserted without throwing) -- advance the cursor
                // to its end and commit its count.
                syncState.lastSyncedAt = chunk.end
                syncState.lastStatus = SyncStatus.ok.rawValue
                syncState.lastError = nil
                syncState.itemCount += walked.total
                do {
                    try context.save()
                } catch {
                    // A save failure leaves lastSyncedAt at the last
                    // committed span (the in-memory advance above dies with
                    // this context's rollback): report the failure instead
                    // of an `.ok` nothing was persisted under.
                    // Raw description here, redacted once at the catch
                    // below (the documented D11 boundary) -- redacting at
                    // both layers just burns regex passes and hides the
                    // ownership.
                    throw HealthKitWriterError.underlying(String(describing: error))
                }
            }
            let suppressedCount = await conflictFilter.drainSuppressedCount(for: type)
            let outcome = SyncOutcome(
                dataType: type, status: .ok, itemCount: totalItemCount, suppressedCount: suppressedCount,
                skippedCount: totalSkipped
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
            // Unwrap for everything below — a bare check on the wrapper
            // would misclassify a cancelled walk as failed.
            let effective = (error as? PageWalkPartial)?.underlying ?? error
            let walk = error as? PageWalkPartial
            // The walk's skipped points count on every path, the error-row
            // fetch failure included (WP-74): they were never going to be
            // written, whatever happens to the rows around them.
            totalSkipped += walk?.skipped ?? 0

            // WP-12b: same drains on the failure path -- draining the count
            // both reports partial progress and resets the resolver's state
            // so nothing leaks into the next run. Links drain WITHOUT
            // applying (round-9 item 7): the old apply-then-save stamped
            // them onto SURVIVING pre-existing rows, and the upsert never
            // resets `linkedWatchWorkoutUUID` -- a stale link went
            // permanent. Drained here means DROPPED here (re-recorded on
            // the re-pull, like the resolver state itself). Drained before
            // the error-row fetch (WP-74), so its failure can't skip them.
            _ = await conflictFilter.drainDeferredSessionLinks(for: type)
            let suppressedCount = await conflictFilter.drainSuppressedCount(for: type)

            /// Every failure-path outcome, with the run's counts (WP-74:
            /// the error-row fetch failure built its own and dropped them).
            func outcome(_ status: SyncStatus, errorMessage: String? = nil) -> SyncOutcome {
                SyncOutcome(
                    dataType: type, status: status, itemCount: totalItemCount,
                    suppressedCount: suppressedCount, skippedCount: totalSkipped, errorMessage: errorMessage
                )
            }

            // Re-acquire after the rollback: it may have undone
            // `fetchOrCreateSyncState`'s insert on a first-ever sync.
            // Best-effort: if the fetch itself throws here, the error row cannot
            // be persisted — report the ORIGINAL failure without masking it.
            let syncState: SyncState
            do {
                syncState = try fetchOrCreateSyncState(for: type, context: context)
            } catch {
                let failed = outcome(.error, errorMessage: SyncLogRedactor.redact(String(describing: error)))
                await runRecorder?.record(failed)
                return failed
            }

            // Round-10 item 14: commit the completed pages' `.localOnly`
            // rows even though the walk failed (upserted here, on this
            // executor, ahead of the error-row saves below that commit
            // them — the cursor still holds, so the window re-pulls
            // idempotently around the persisted rows). The walk counted
            // them, so the count reflects persisted rows exactly:
            // subtract any upsert that fails rather than masking the
            // original error with a new throw.
            if let walk {
                totalItemCount += walk.total
                var upsertFailures = 0
                for point in walk.localOnly {
                    do {
                        try PagePipeline.upsertLocalSample(for: point, context: context)
                    } catch {
                        upsertFailures += 1
                    }
                }
                if upsertFailures > 0 {
                    DiagnosticsLog.sync.notice(
                        "Dropped \(upsertFailures, privacy: .public) unencodable local-only point(s) from a failed walk's count — rows never persisted, never counted."
                    )
                    totalItemCount -= upsertFailures
                }
            }

            // Cancellation is a stop, not a failure: no error status, no
            // message, cursor at the last committed span -- the next run
            // resumes from there. (Without this branch a routine expiration-handler
            // cancel paints a red dashboard row for the system doing its
            // job.) A locked device is the same kind of stop (WP-52):
            // HealthKit can't be read until the phone is unlocked, and a
            // background wake on a locked phone painted every type red.
            if effective is CancellationError
                || (effective as? GoogleHealthClientError) == .cancelled
                || (effective as? HealthKitWriterError) == .protectedDataUnavailable {
                // Status moves, message stays: a previous run's genuine
                // error is evidence for the user/support, and a stop
                // resolves nothing about it. Clearing it here would trade
                // the red row for silent amnesia.
                syncState.lastStatus = SyncStatus.cancelled.rawValue
                try? context.save()
                let stopped = outcome(.cancelled)
                await runRecorder?.record(stopped)
                return stopped
            }

            // Partial-span failure: `lastSyncedAt` deliberately stays at the
            // last committed span (architecture.md D3) so the failed span --
            // including whatever pages already succeeded in it -- is safely
            // re-pulled next time; idempotent existence-diff means
            // re-processing already-written pages costs nothing but a query.
            // Redacted (architecture.md D11, SyncState.lastError's own
            // doc): pipeline errors can embed bearer tokens or
            // authenticated URLs; the sync-log path already redacts via
            // SyncLogRedactor -- this persisted/UI-rendered path must too.
            // `effective` (not the wrapper): the ledger should name the
            // page failure, never `PageWalkPartial(...)` debug output.
            let message = SyncLogRedactor.redact(String(describing: effective))
            syncState.lastStatus = SyncStatus.error.rawValue
            syncState.lastError = message
            try? context.save()
            let failed = outcome(.error, errorMessage: message)
            await runRecorder?.record(failed) // WP-18: additive diagnostics hook, see this actor's `runRecorder` doc comment.
            return failed
        }
    }

    // MARK: - SwiftData bookkeeping

    private func fetchOrCreateSyncState(for type: GoogleDataType, context: ModelContext) throws -> SyncState {
        // `.rawValue`, not `.filterName` -- identical string value, but
        // `.rawValue` is compiler-synthesized and so isn't subject to
        // CoreModel's `.defaultIsolation(MainActor.self)` inference the way
        // `.filterName` (a hand-written computed property) is -- the same
        // substitution `GoogleHealthClient`'s data client and `TypeMapper`
        // already made for the same reason (progress.md's WP-04/05 entry).
        // Third-party r9: the fetch THROWS (never `try?`). A fetch failure must
        // fail the run, not mint a second `SyncState` for the same type — the
        // old fall-through split the cursor and itemCount across duplicates
        // that later fetches returned nondeterministically. Catches: a throwing
        // fetch must surface, not duplicate.
        let key = type.rawValue
        let descriptor = FetchDescriptor<SyncState>(predicate: #Predicate { $0.dataType == key })
        if let existing = try context.fetch(descriptor).first {
            return existing
        }
        let created = SyncState(dataType: key)
        context.insert(created)
        return created
    }
}

#endif
