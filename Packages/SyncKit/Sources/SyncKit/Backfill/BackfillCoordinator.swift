// BackfillCoordinator.swift
//
// WP-15 (implementation-plan.md) / architecture.md §4 D5: "Historical
// backfill is a separate, chunked flow... BackfillCoordinator walks backward
// in ~30-day chunks per type, checkpointing progress in
// SyncState.backfillCursor, resumable across app kills, throttled to
// respect API quotas. Regular incremental sync (D3) starts immediately and
// is independent of backfill progress."
//
// ## Why this is a leaner, standalone pipeline rather than a call into
// ## `SyncEngine.sync(type:)`
//
// The task brief for this WP explicitly asks: "consider whether
// BackfillCoordinator can literally delegate a chunk's work to
// SyncEngine.sync(type:) with a synthetic window, or whether it needs its
// own leaner path." Read `SyncEngine.swift`/`SyncEngineTypes.swift` in full
// before deciding (per the handoff protocol) and found:
//
//   1. `SyncEngine.sync(type:)` takes **no window parameter at all** -- its
//      window is *always* derived internally from `SyncState.lastSyncedAt`
//      and `clock.now()` (`window.start = (lastSyncedAt ?? now -
//      initialWindow) - lookback(type)`, `window.end = now`, verbatim from
//      `performSync`). There is no way to hand it an arbitrary historical
//      `[start, end)` -- the plan's own illustrative "synthetic window"
//      phrasing doesn't correspond to any real parameter on the actual
//      method.
//   2. Even if it did, `sync(type:)` advances `SyncState.lastSyncedAt` (the
//      *incremental* high-water mark) on success -- backfill must never
//      touch that field. Backfill's own cursor is the entirely separate
//      `SyncState.backfillCursor` (CoreModel, WP-02), walking the opposite
//      direction (backward, toward the past) from a different starting
//      point (`min(lastSyncedAt, now)`, not `lastSyncedAt` itself). Forcing
//      backfill through `sync(type:)` would require either corrupting
//      `lastSyncedAt` with a backward-walking value (breaking D3's
//      high-water-mark contract for every future incremental sync) or a
//      structural rewrite of `SyncEngine` to parameterize its window and
//      choose which cursor field to persist -- exactly the kind of
//      "restructure" this WP was told to avoid for shared files.
//
// So `BackfillCoordinator` reuses everything *else* WP-09 established --
// `GoogleReconcileClient` (the exact same protocol, SyncEngineTypes.swift),
// `TypeMapper.map(_:)` (WP-07/11/12/13), `ConflictFiltering`/
// `IdentityConflictFilter` (the WP-12b seam), and `HealthKitWriter`'s
// batched existence-diff/save/upsert primitives (WP-08) -- but drives them
// itself, keyed on `backfillCursor` and an explicit chunk window it computes
// per call, rather than going through `SyncEngine`'s cursor-anchored
// `performSync` (the two cursors' semantics — forward high-water-mark +
// lookback vs. backward chunk-walk + checkpoint — are genuinely different;
// see progress.md's WP-15 entry). The per-PAGE core, however, is shared:
// `pullMapWrite` below drives the single `PagePipeline.processPage`
// (round-4-sync item 15) both engines use — the old parallel copy is
// gone, so the page arms can never drift apart again.
//
// Guarded `#if canImport(HealthKit)`, identically to `SyncEngine.swift`
// (needs `HKObject`/`HKSampleType` and `HealthKitWriter` itself).
#if canImport(HealthKit)
import CoreModel
import Foundation
import GoogleHealthClient
import HealthKit
import SwiftData

/// Chunked, resumable, round-robin historical backfill across every
/// `GoogleDataType` this coordinator was configured with
/// (implementation-plan.md WP-15).
///
/// **Cursor semantics** (extends architecture.md D5 / D4 to the field WP-02
/// already reserved, `SyncState.backfillCursor`): a non-`nil` cursor is the
/// earliest point this type's backward walk has reached *so far* -- the
/// next chunk to pull is `[max(horizonDate, cursor - chunkDuration),
/// cursor)`. `nil` means either "never started" or "fully caught up to
/// whatever horizon was last completed" (honoring `SyncState.backfillCursor`'s
/// own doc comment literally); telling those two `nil` cases apart, and
/// resuming an "extend" (a deeper horizon chosen after a shallower one
/// completed) from the *old* horizon's boundary rather than from scratch,
/// is `BackfillHorizonRecordStore`'s one job (BackfillTypes.swift) -- see
/// that protocol's doc comment for the CoreModel-scope gap this papers over.
public actor BackfillCoordinator {
    private let types: [GoogleDataType]
    private let client: any GoogleReconcileClient
    private let writer: HealthKitWriter
    private let modelContainer: ModelContainer
    private let clock: any SyncClock
    private let sleeper: any BackoffSleeper
    private let conflictFilter: any ConflictFiltering
    /// Round-4-sync item 5: same injectable resolver as `SyncEngine` —
    /// a resolution failure throws into `runNextChunk`'s catch (error
    /// row + `.failed`, zero writes), never `try?`'d into silent green.
    private let sampleTypeResolver: @Sendable @MainActor (String) throws(UnresolvedHealthKitIdentifier) -> HKSampleType
    /// Types currently disabled in Settings, consulted per chunk
    /// (round-4-sync item 4): a closure over live `UserDefaults.standard`
    /// — never snapshotted — so a mid-walk toggle takes effect on the
    /// next chunk without rebuilding the coordinator. `runNextChunk`
    /// reports `.suspendedDisabled` (never pulls/writes) for these.
    private let disabledTypes: @Sendable @MainActor () -> Set<GoogleDataType>
    /// Persistence for the already-caught-up branch, injected so tests
    /// can simulate a save failure there (round-4-sync item 10): a real
    /// `ModelContext.save()` against a healthy store does not observably
    /// throw, so without this the failure arm is untestable — which is
    /// exactly how it shipped returning `.alreadyDone`.
    private let persistCompletionState: @Sendable (ModelContext) throws -> Void
    private let horizonStore: any BackfillHorizonRecordStore
    private let busyProbe: any BackfillBusyProbe
    private let configuration: BackfillConfiguration

    private var horizon: BackfillHorizon
    private var isPaused = false
    private var runLoopTask: Task<Void, Never>?
    /// Monotonic run-loop generation: `stop()` bumps it so a cancelled loop
    /// still draining its sleeper can't clear a newer loop's handle on exit
    /// (the two-concurrent-loops race on one `backfillCursor`).
    private var runLoopGeneration = 0
    /// The loop `stop()` most recently retired. `start()` awaits it before
    /// installing a new loop: without this, `stop()`'s suspension on the
    /// old loop lets a concurrent `start()` pass the `nil` guard first and
    /// two loops walk one cursor.
    /// Generation of the currently-published handle (round-8 item 9):
    /// the trailing clear in `stop()` keys off this, not the shared
    /// `runLoopGeneration` (which concurrent stops also bump).
    private var retiredLoop: Task<Void, Never>?
    private var retiredGeneration = 0

    public init(
        types: [GoogleDataType],
        client: any GoogleReconcileClient,
        writer: HealthKitWriter,
        modelContainer: ModelContainer,
        clock: any SyncClock = SystemSyncClock(),
        sleeper: any BackoffSleeper = SystemSleeper(),
        conflictFilter: any ConflictFiltering = IdentityConflictFilter(),
        persistCompletionState: @escaping @Sendable (ModelContext) throws -> Void = { try $0.save() },
        disabledTypes: @escaping @Sendable @MainActor () -> Set<GoogleDataType> = { [] },
        sampleTypeResolver: @escaping @Sendable @MainActor (String) throws(UnresolvedHealthKitIdentifier) -> HKSampleType = HealthKitObjectTypeResolver.sampleType,
        horizonStore: any BackfillHorizonRecordStore = UserDefaultsBackfillHorizonRecordStore(),
        busyProbe: any BackfillBusyProbe = AlwaysAvailableBusyProbe(),
        configuration: BackfillConfiguration = BackfillConfiguration(),
        horizon: BackfillHorizon = .defaultHorizon,
        isQuiesced: @escaping @Sendable () -> Bool = { false }
    ) {
        self.isQuiesced = isQuiesced
        self.types = types
        self.client = client
        self.writer = writer
        self.modelContainer = modelContainer
        self.clock = clock
        self.sleeper = sleeper
        self.conflictFilter = conflictFilter
        self.disabledTypes = disabledTypes
        self.persistCompletionState = persistCompletionState
        self.sampleTypeResolver = sampleTypeResolver
        self.horizonStore = horizonStore
        self.busyProbe = busyProbe
        self.configuration = configuration
        self.horizon = horizon
    }

    // MARK: - Public control surface (WP-15 step 3: pause/resume/horizon picker)

    public func currentHorizon() -> BackfillHorizon { horizon }

    public func completedHorizon(for type: GoogleDataType) -> BackfillHorizon? {
        horizonStore.completedHorizon(for: type)
    }

    public var isPausedNow: Bool { isPaused }

    public func pause() {
        isPaused = true
    }

    public func resume() async {
        isPaused = false
        await start()
    }

    /// WP-15 step 3: "chosen horizon changeable (extending re-opens the
    /// walk)". Purely updates the in-actor target; the next
    /// `runNextChunk`/`runRound`/background-loop touch of each type
    /// re-derives its resume point against the new horizon (see
    /// `runNextChunk`'s "frontier" computation). Choosing a *shallower*
    /// horizon than one already completed is a safe no-op -- this
    /// coordinator never deletes previously-imported history.
    public func setHorizon(_ newHorizon: BackfillHorizon) {
        horizon = newHorizon
    }

    /// Quiesce probe (round-10 item 1): a latched wipe stops new loops
    /// until relaunch (a post-wipe walk would write `LocalSample` +
    /// `SyncState` rows over cleared state). Init-injected (default
    /// inert) so tests script it without touching process state. The
    /// wipe ALSO stops a running loop via `stop()` — this guard covers
    /// restarts (view re-appears, resume paths).
    private let isQuiesced: @Sendable () -> Bool

    /// Starts (or restarts) the `.utility`-priority background walk (WP-15
    /// step 2). No-op if already running or currently paused. `async`
    /// because it first awaits a loop `stop()` retired (all callers already
    /// call it with `await`).
    public func start() async {
        // Round-10 item 1: quiesced loops never (re)start.
        guard !isQuiesced() else { return }
        // Serialize with an in-flight stop: `stop()` nils the handle before
        // the old loop actually exits, so without this await the guard
        // below passes while the old loop is still walking the cursor.
        // Loop until no retired loop remains: another `stop()` may retire a
        // newer loop while one await suspends.
        while let retired = retiredLoop {
            await retired.value
            // Round-8 item 9 (liveness): awaiting an already-completed
            // task can return WITHOUT yielding the executor — without
            // this explicit yield, a momentarily-stale handle spins a
            // tight non-yielding loop that can starve the very tasks
            // (exiting loop, trailing clear) that would clear it,
            // wedging the drain under pool pressure. Each pass
            // re-reads the handle, so a clear still lands promptly;
            // the yield only guarantees the waiter never pins a thread
            // while waiting for it.
            await Task.yield()
        }
        guard runLoopTask == nil, !isPaused else { return }
        runLoopGeneration += 1
        let generation = runLoopGeneration
        runLoopTask = Task(priority: .utility) { [self] in
            await runLoop(generation: generation)
        }
    }

    /// Cancels the background walk and waits for it to actually exit.
    /// `async` (all callers already await `start()`): cancelling alone is
    /// not enough -- the loop may be mid-`runRound()` (a full paged pull +
    /// writes, with no cancellation probe inside), and an immediate
    /// `start()` would otherwise launch a second loop over the same cursor
    /// while the first is still draining. When this returns, no loop is
    /// running and `start()` is safe.
    public func stop() async {
        let old = runLoopTask
        runLoopTask = nil
        // Bump so the exiting loop fails its generation check instead of
        // touching the handle (defense in depth -- by the await below it is
        // already done, but the check costs nothing). The bump doubles as
        // the ownership token for `retiredLoop` below.
        runLoopGeneration += 1
        let myGeneration = runLoopGeneration
        old?.cancel()
        // Publish before awaiting: a `start()` arriving during this
        // suspension must see (and await) the retiring loop, not sail past
        // the `nil` handle into a second concurrent walk. Round-8 item 9:
        // publish ONLY a live handle, and clear ONLY our own publication
        // — a second `stop()` with a nil handle must neither erase the
        // first stop's publication (the hole: `start()` then launched a
        // concurrent walk over the same cursor, which the generation
        // guard cannot repair) nor clear it on the way out. Ownership
        // keys off `retiredGeneration` (set only alongside a publish),
        // never the shared `runLoopGeneration` other stops also bump —
        // and a stale DONE handle can never linger: every publication
        // is cleared exactly once by its publisher, so `start()`'s
        // `while let` always terminates.
        if let old {
            retiredLoop = old
            retiredGeneration = myGeneration
        }
        // Round-9 item 14: drain WHATEVER is published — including a
        // previous stop's still-draining loop when this call arrived
        // with no handle of its own — so `stop()` returns only when no
        // loop is running, on EVERY path. The old `await old?.value`
        // skipped the drain entirely on the nil-handle path, breaking
        // the postcondition for stop-then-wipe callers (a wipe issued
        // right after a handle-less stop could race the draining walk).
        await retiredLoop?.value
        if retiredGeneration == myGeneration {
            retiredLoop = nil
        }
    }

    // MARK: - Status (WP-15 step 3: per-type progress UI)

    /// Live progress for `type`, derived fresh from `SyncState` +
    /// `BackfillHorizonRecordStore` + the current horizon on every call --
    /// never cached separately (the same "derive, don't duplicate" posture
    /// `Routing/ClinicalClassification.swift` documents).
    public func status(for type: GoogleDataType) async -> BackfillTypeStatus {
        let context = ModelContext(modelContainer)
        let now = clock.now()
        // Read-only probe (never inserts): a fetch failure reads as absent, surfacing
        // no error row — the chunk path above owns failure reporting. No duplicate
        // risk here since this never creates a row.
        let syncState = try? fetchSyncState(for: type, context: context)
        let horizonDate = horizon.horizonDate(now: now)
        let completed = horizonStore.completedHorizon(for: type)
        let isComplete = syncState?.backfillCursor == nil
            && (completed?.coversAtLeastAsMuchHistoryAs(horizon) ?? false)
        let reachedDate: Date?
        if let cursor = syncState?.backfillCursor {
            reachedDate = cursor
        } else if let completed {
            reachedDate = completed.horizonDate(now: now)
        } else {
            reachedDate = nil
        }
        return BackfillTypeStatus(
            dataType: type,
            reachedDate: reachedDate,
            horizonDate: horizonDate,
            isComplete: isComplete,
            lastError: syncState?.backfillStatus == SyncStatus.error.rawValue ? syncState?.backfillError : nil
        )
    }

    public func statuses() async -> [BackfillTypeStatus] {
        var results: [BackfillTypeStatus] = []
        results.reserveCapacity(types.count)
        for type in types {
            results.append(await status(for: type))
        }
        return results
    }

    /// Whether every configured type has reached the current horizon.
    public func isFullyDone() async -> Bool {
        for type in types where await status(for: type).isComplete == false {
            return false
        }
        return true
    }

    // MARK: - Round-robin driver (WP-15 step 1: "process types round-robin
    // ... so one huge type doesn't starve others")

    /// Attempts exactly one chunk for each configured type, in `types`'
    /// order -- the "one chunk per type per round" fairness rule that
    /// guarantees no single type can consume more than one chunk before
    /// every other type gets a turn.
    @discardableResult
    public func runRound() async -> [GoogleDataType: BackfillChunkOutcome] {
        var results: [GoogleDataType: BackfillChunkOutcome] = [:]
        for type in types {
            // Cancellation probe inside the round (not just around it): a
            // chunk is a full paged pull + writes, so without this a
            // `stop()` mid-round still walks every remaining type before
            // noticing.
            if Task.isCancelled { break }
            results[type] = await runNextChunk(for: type)
        }
        return results
    }

    // MARK: - Per-type, per-chunk pipeline

    /// Advances `type`'s backfill by exactly one ~30-day chunk, or reports
    /// why it didn't run one. Public on its own (not just reachable via
    /// `runRound`) so tests can drive/assert individual types deterministically.
    @discardableResult
    public func runNextChunk(for type: GoogleDataType) async -> BackfillChunkOutcome {
        // Round-4-sync item 4: stable user intent dominates transient
        // state — a disabled type is never pulled or written on ANY
        // path through this choke point (loop, round, or direct call).
        if await disabledTypes().contains(type) { return .suspendedDisabled }
        if isPaused { return .suspendedPaused }
        if await busyProbe.isBusy(for: type) { return .suspendedBusy }
        // Third-party r9: the documented per-chunk choke point enforces the wipe
        // latch like every other writer trigger (CloudSyncEngine, MorningInsightRunner,
        // HealthLoomApp BG handler). A round already in progress that latches mid-walk
        // must stop writing here — `stop()` cancellation alone is not enough since
        // the wipe never awaits it (WipeFlowView finding) and the loop only probes
        // cancellation between rounds. A stop, not a failure: no error row.
        if isQuiesced() { return .suspendedCancelled }

        let context = ModelContext(modelContainer)
        let now = clock.now()
        // Third-party r9: cursor fetch throws into a loud `.failed` (never a silent
        // duplicate row — same contract as `SyncEngine.fetchOrCreateSyncState`).
        let syncState: SyncState
        do {
            syncState = try fetchOrCreateSyncState(for: type, context: context)
        } catch {
            return .failed(SyncLogRedactor.redact(String(describing: error)))
        }
        let horizonDate = horizon.horizonDate(now: now)
        let completed = horizonStore.completedHorizon(for: type)

        // Already caught up to (at least) the current horizon. Checked via
        // the side-store, not `backfillCursor == nil` alone, since `nil` is
        // ambiguous between "never started" and "done" -- see
        // `BackfillHorizonRecordStore`'s doc comment (BackfillTypes.swift).
        if syncState.backfillCursor == nil, let completed, completed.coversAtLeastAsMuchHistoryAs(horizon) {
            return .alreadyDone
        }

        // Frontier = earliest point reached so far. Three cases:
        //   1. Mid-walk (`backfillCursor` set) -> resume from exactly there.
        //   2. Never started at all (`backfillCursor` nil, no completed
        //      horizon record) -> start from `min(lastSyncedAt, now)`,
        //      WP-15 step 1's literal starting point.
        //   3. "Extend" (`backfillCursor` nil, a *shallower* horizon already
        //      completed) -> resume from that old horizon's own boundary,
        //      continuing the walk further back instead of re-pulling
        //      everything from `min(lastSyncedAt, now)` again.
        let frontier: Date
        if let cursor = syncState.backfillCursor {
            frontier = cursor
        } else if let completed {
            frontier = completed.horizonDate(now: now)
        } else {
            frontier = min(syncState.lastSyncedAt ?? now, now)
        }

        guard frontier > horizonDate else {
            // Already at/beyond the horizon -- record completion rather
            // than issuing a zero-or-negative-width chunk (can happen right
            // after a narrowing `setHorizon` call, or a benign race between
            // two `runNextChunk` calls for the same type). Side store after
            // the save, like the chunk path below.
            syncState.backfillCursor = nil
            do {
                try persistCompletionState(context)
            } catch {
                // Round-4-sync item 10: a failed completion save is a
                // FAILURE, not a completion — returning `.alreadyDone`
                // here hot-looped the failing save every round with the
                // status screen showing healthy in-progress. Mirror the
                // chunk catch: roll back, surface via the error row
                // (best-effort — the store just refused a write), and
                // report `.failed` so the loop no longer spins silently.
                // The cursor is untouched on disk, so the next round
                // retries this same branch.
                context.rollback()
                // Best-effort error row: if the fetch itself throws, the row cannot be
                // persisted — report the original failure without masking it.
                do {
                    let syncState = try fetchOrCreateSyncState(for: type, context: context)
                    let message = SyncLogRedactor.redact(String(describing: error))
                    syncState.backfillStatus = SyncStatus.error.rawValue
                    syncState.backfillError = message
                    try? context.save()
                    return .failed(message)
                } catch {
                    return .failed(SyncLogRedactor.redact(String(describing: error)))
                }
            }
            horizonStore.setCompletedHorizon(horizon, for: type)
            return .alreadyDone
        }

        let chunkEnd = frontier
        let chunkStart = max(horizonDate, chunkEnd.addingTimeInterval(-configuration.chunkDuration))

        do {
            let itemCount = try await pullMapWrite(type: type, start: chunkStart, end: chunkEnd, context: context)

            let reachedHorizon = chunkStart <= horizonDate
            if reachedHorizon {
                // This chunk reached the horizon -- fully caught up.
                syncState.backfillCursor = nil
            } else {
                syncState.backfillCursor = chunkStart
            }
            syncState.backfillStatus = SyncStatus.ok.rawValue
            syncState.backfillError = nil
            syncState.itemCount += itemCount
            do {
                try context.save()
            } catch {
                // Same contract as SyncEngine's success path: an unpersisted
                // cursor advance must report failure, not `.ok`.
                // Raw here, redacted once at the catch below (same
                // single-boundary rule as `SyncEngine`).
                throw HealthKitWriterError.underlying(String(describing: error))
            }
            // Only after the save durably landed: the side store is never
            // rolled back, so recording completion before this point would
            // permanently disagree with `SyncState` on a save failure.
            if reachedHorizon {
                horizonStore.setCompletedHorizon(horizon, for: type)
            }
            return .processedChunk(window: chunkStart...chunkEnd, itemCount: itemCount)
        } catch {
            // Roll back first (same reason as SyncEngine's catch): the
            // success path above may have thrown out of its own save with
            // the cursor already advanced in memory, and the error-row save
            // below would commit it despite the "left untouched" contract.
            // Re-acquire after: rollback may undo a first-ever insert.
            // Best-effort: if the fetch itself throws, the error row cannot be
            // persisted — fall through with no row write and still report `.failed`.
            context.rollback()
            let syncState: SyncState
            do {
                syncState = try fetchOrCreateSyncState(for: type, context: context)
            } catch {
                return .failed(SyncLogRedactor.redact(String(describing: error)))
            }
            // Round-10 item 14: commit the completed pages' `.localOnly`
            // rows even though the chunk failed (upserted here, on this
            // executor, ahead of the error-row saves below that commit
            // them — the cursor still holds, so the next chunk re-pulls
            // idempotently around the persisted rows; the chunk outcome
            // carries no count, so no arithmetic is owed). Unwrap for
            // the cancellation branch below (same wrapper hazard as
            // SyncEngine's catch).
            let effective = (error as? PageWalkPartial)?.underlying ?? error
            if let walk = error as? PageWalkPartial {
                for point in walk.localOnly {
                    try? PagePipeline.upsertLocalSample(for: point, context: context)
                }
            }
            // Round-8 item 12 + round-9 item 7: drain on the failure
            // path too (converging on SyncEngine's catch shape) —
            // otherwise a failed chunk leaks the coverage index +
            // run entry. But drain WITHOUT applying or persisting:
            // the old shape applied the drained links and then `try?`
            // saved them onto SURVIVING (pre-existing) rows — and the
            // upsert never resets `linkedWatchWorkoutUUID`, so a stale
            // link went PERMANENT, contradicting the 'drops silently'
            // contract. Drained here means DROPPED here.
            _ = await conflictFilter.drainDeferredSessionLinks(for: type)
            _ = await conflictFilter.drainSuppressedCount(for: type)
            // Cancellation is a stop, not a failure: no error status, the
            // cursor stays where the last durable save left it.
            if effective is CancellationError || (effective as? GoogleHealthClientError) == .cancelled {
                syncState.backfillStatus = SyncStatus.cancelled.rawValue
                try? context.save()
                return .suspendedCancelled
            }
            // `effective`, not the wrapper (same ledger-hygiene reason
            // as SyncEngine's catch).
            let message = SyncLogRedactor.redact(String(describing: effective))
            syncState.backfillStatus = SyncStatus.error.rawValue
            syncState.backfillError = message
            try? context.save()
            return .failed(message)
        }
    }

    // MARK: - Background driver

    /// Whether the background walk loop is currently running (round-7
    /// item 9): lets the UI restart a loop that exited on no-progress
    /// (e.g. after re-enabling a type) — `start()` itself is a safe
    /// no-op when already running, so polling this is cheap.
    public var isLoopRunning: Bool { runLoopTask != nil }

    private func runLoop(generation: Int) async {
        while !Task.isCancelled, !isPaused {
            if await isFullyDone() { break }
            let results = await runRound()
            if Task.isCancelled || isPaused { break }
            if await isFullyDone() { break }
            // Round-7 item 9: no-progress exit. All-disabled (or
            // all-complete-but-unrecorded) rounds otherwise spin
            // forever at the inter-chunk delay — ModelContexts, fetches,
            // and MainActor hops every 2s for process lifetime, with no
            // UI surface. Transient states (busy, failed, cancelled,
            // fresh chunks) keep retrying; only the STABLE no-work
            // outcomes — done or disabled — exit. Re-enabling restarts
            // via `start()` (the view polls `isLoopRunning`).
            let idle = results.values.allSatisfy { $0 == .alreadyDone || $0 == .suspendedDisabled }
            if idle { break }
            try? await sleeper.sleep(seconds: configuration.interChunkDelay)
        }
        // Identity-checked: only the current generation clears the handle.
        // A stale loop (cancelled by `stop()`, resumed late from its
        // sleeper after `start()` stored a newer task) leaves the new
        // handle alone, so the `guard runLoopTask == nil` in `start()` can
        // never admit a second concurrent loop.
        if generation == runLoopGeneration {
            runLoopTask = nil
        }
    }

    // MARK: - Pull -> map -> conflict-filter -> write/upsert (one chunk window)

    /// Chunk-window driver over the SHARED page pipeline
    /// (`PagePipeline.processPage` — the same implementation
    /// `SyncEngine.performSync` uses). Applies the D4
    /// batched-existence-diff invariant (one query per (type, chunk
    /// window), computed once, threaded through every page of this
    /// chunk); only the window/cursor semantics are backfill's own.
    private func pullMapWrite(
        type: GoogleDataType,
        start: Date,
        end: Date,
        context: ModelContext
    ) async throws -> Int {
        // `await`: `.writability` is a MainActor-isolated computed property
        // (CoreModel's `.defaultIsolation(MainActor.self)`) -- same crossing
        // `SyncEngine.swift`'s header documents.
        let writability = await type.writability
        var hkSampleType: HKSampleType?
        if case .healthKit(let identifier) = writability {
            hkSampleType = try await sampleTypeResolver(identifier)
        }

        // WP-12b: refresh the conflict filter's coverage cache + retroactive
        // cleanup for this chunk window, *before* the existence query --
        // exactly mirroring `SyncEngine.performSync`'s own call (see the
        // comment there). Historical chunks hit historical watch workouts
        // just as incremental syncs hit recent ones.
        try await conflictFilter.beginRun(type: type, windowStart: start, windowEnd: end)

        var knownExternalIDs: Set<String> = []
        if let hkSampleType {
            knownExternalIDs = try await writer.existingExternalIDs(type: hkSampleType, start: start, end: end)
        }

        var totalItemCount = 0
        // Round-6 item 8: the bounded shared walk (see PagePipeline);
        // `.localOnly` upserts stay here (round-10 item 14: same
        // executor-confinement reason as SyncEngine — context work never
        // crosses into the pipeline). A throwing page propagates
        // `PageWalkPartial` to `runNextChunk`'s catch, which commits the
        // completed pages' rows there.
        let walked = try await PagePipeline(conflictFilter: conflictFilter, writer: writer)
            .processPages(knownExternalIDs: knownExternalIDs) { token in
                try await client.reconcile(type: type, since: start, until: end, pageToken: token)
            }
        for point in walked.localOnly {
            // Round-8 item 13: throws on unencodable payloads (no
            // silent zero-byte rows) — into the run's existing
            // failure path (cursor unmoved, error surfaced).
            try PagePipeline.upsertLocalSample(for: point, context: context)
        }
        totalItemCount += walked.total
        // Third-party r9: a cap-hit FAILS the chunk (cursor held) — it must never
        // advance `backfillCursor` past the whole window. Unlike incremental sync
        // (which recovers the remainder through lookback overlap), backfill walks
        // strictly backwards with no overlap, so advancing would permanently lose
        // every point past the cap. Throwing `PageWalkPartial` reuses the existing
        // failure path: completed pages' `.localOnly` rows still commit, HK partial
        // writes stand idempotently, the cursor holds for a loud retry. Catches: a
        // dense 30-day window exceeding 100 pages must surface as `.failed`, never
        // report `.processedChunk` past unwalked data.
        if walked.hitPageCap {
            DiagnosticsLog.backfill.notice(
                "Page cap (\(PagePipeline.maxPages, privacy: .public)) hit for \(String(describing: type), privacy: .public) — chunk failed without advancing the cursor; the window will retry."
            )
            throw PageWalkPartial(total: totalItemCount, localOnly: walked.localOnly, underlying: BackfillPageCapHit(typeName: type.rawValue))
        }

        // WP-12b: stamp deferred-session links onto the LocalSample rows the
        // pages above upserted (same mechanics as
        // `SyncEngine.applyDeferredSessionLinks`); the suppressed count is
        // drained purely to reset the filter's per-run state -- backfill has
        // no per-chunk log row to surface it in (`BackfillTypeStatus` tracks
        // cursor progress, not per-run counts).
        PagePipeline.applyDeferredSessionLinks(await conflictFilter.drainDeferredSessionLinks(for: type), context: context)
        _ = await conflictFilter.drainSuppressedCount(for: type)

        return totalItemCount
    }

    // MARK: - SwiftData bookkeeping (mirrors SyncEngine.swift's own helpers)

    private func fetchSyncState(for type: GoogleDataType, context: ModelContext) throws -> SyncState? {
        // Third-party r9: throws (never `try?`) — a fetch failure must fail the chunk,
        // not silently read "absent" and mint a duplicate cursor row.
        let key = type.rawValue
        let descriptor = FetchDescriptor<SyncState>(predicate: #Predicate { $0.dataType == key })
        return try context.fetch(descriptor).first
    }

    private func fetchOrCreateSyncState(for type: GoogleDataType, context: ModelContext) throws -> SyncState {
        if let existing = try fetchSyncState(for: type, context: context) {
            return existing
        }
        let created = SyncState(dataType: type.rawValue)
        context.insert(created)
        return created
    }
}

/// Page-cap hit inside a backfill chunk (third-party r9): the `underlying` error
/// `pullMapWrite` wraps in `PageWalkPartial` when a chunk window exceeds
/// `PagePipeline.maxPages`. Log-safe by construction (type name only, never payloads).
/// Surfaces through `runNextChunk`'s catch as `.failed` with the cursor held —
/// the window retries instead of being skipped past.
nonisolated struct BackfillPageCapHit: Error, Sendable {
    var typeName: String
}

#endif
