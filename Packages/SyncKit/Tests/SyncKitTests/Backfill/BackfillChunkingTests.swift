// BackfillChunkingTests.swift
//
// WP-15 (implementation-plan.md) "Tests:" line, first two items verbatim:
//   "chunk boundaries exact (no gap/overlap between chunks); kill-resume
//   from checkpoint."

#if canImport(HealthKit)
import CoreModel
import Foundation
import GoogleHealthClient
import HealthKit
import SwiftData
import Testing
@testable import SyncKit

/// Stop-completion flag (round-9 item 14): test-side completion
/// observation must not mutate a captured `var` from a `Task`
/// (Swift 6 concurrent-mutation error under strict flags).
actor StopFlag {
    private var done = false
    func set() { done = true }
    func get() -> Bool { done }
}

@Suite struct BackfillChunkingTests {
    static let fixedNow = BackfillTestFixtures.date("2026-07-10T12:00:00Z")

    /// `.year1`'s 365-day span isn't an exact multiple of the default 30-day
    /// chunk size (365 / 30 = 12 remainder 5), so this horizon deliberately
    /// exercises the "final, shorter chunk clipped to the horizon" boundary
    /// case, not just a run of uniform 30-day chunks.
    static func makeCoordinator(
        types: [GoogleDataType] = [.steps],
        client: MockGoogleReconcileClient,
        writer: HealthKitWriter = HealthKitWriter(store: MockHealthStore()),
        container: ModelContainer,
        clock: TestSyncClock,
        horizonStore: any BackfillHorizonRecordStore = InMemoryBackfillHorizonRecordStore(),
        busyProbe: any BackfillBusyProbe = AlwaysAvailableBusyProbe(),
        horizon: BackfillHorizon = .year1
    ) -> BackfillCoordinator {
        BackfillCoordinator(
            types: types,
            client: client,
            writer: writer,
            modelContainer: container,
            clock: clock,
            conflictFilter: IdentityConflictFilter(),
            horizonStore: horizonStore,
            busyProbe: busyProbe,
            horizon: horizon
        )
    }

    // MARK: - Chunk boundaries exact

    @Test func chunkBoundariesHaveNoGapOrOverlapAndTheFinalChunkClipsExactlyToTheHorizon() async throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let clock = TestSyncClock(Self.fixedNow)
        let mock = MockGoogleReconcileClient()
        mock.setPage(type: .steps, pageToken: nil, page: Page(points: [], nextPageToken: nil))
        let coordinator = Self.makeCoordinator(client: mock, container: container, clock: clock)

        var windows: [ClosedRange<Date>] = []
        chunkLoop: while true {
            let outcome = await coordinator.runNextChunk(for: .steps)
            switch outcome {
            case .processedChunk(let window, _):
                windows.append(window)
            case .alreadyDone:
                break chunkLoop
            default:
                Issue.record("unexpected outcome: \(outcome)")
                return
            }
        }

        #expect(!windows.isEmpty)
        let horizonDate = Self.fixedNow.addingTimeInterval(-365 * 24 * 3600)
        let chunkDuration: TimeInterval = 30 * 24 * 3600

        // Walk starts at "now" (never-synced .steps -> min(lastSyncedAt ??
        // now, now) == now) and the very first chunk's upper bound is
        // exactly that.
        #expect(windows.first?.upperBound == Self.fixedNow)

        // No gap, no overlap: each chunk's lower bound is exactly the next
        // chunk's upper bound.
        for i in 0..<(windows.count - 1) {
            #expect(windows[i].lowerBound == windows[i + 1].upperBound)
        }

        // Every chunk but the last is exactly `chunkDuration` wide.
        for window in windows.dropLast() {
            #expect(window.upperBound.timeIntervalSince(window.lowerBound) == chunkDuration)
        }

        // The final chunk is clipped exactly to the horizon (365 d isn't a
        // multiple of 30 d, so this is strictly shorter than a full chunk --
        // the boundary-math case this test exists to catch).
        #expect(windows.last?.lowerBound == horizonDate)
        let lastDuration = windows.last!.upperBound.timeIntervalSince(windows.last!.lowerBound)
        #expect(lastDuration < chunkDuration)
        #expect(lastDuration == (365 * 24 * 3600).truncatingRemainder(dividingBy: chunkDuration))

        // Exactly ceil(365/30) = 13 chunks (12 full + 1 partial).
        #expect(windows.count == 13)
    }

    @Test func everyChunkRequestSendsTheExactWindowToTheReconcileClient() async throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let clock = TestSyncClock(Self.fixedNow)
        let mock = MockGoogleReconcileClient()
        mock.setPage(type: .steps, pageToken: nil, page: Page(points: [], nextPageToken: nil))
        let coordinator = Self.makeCoordinator(client: mock, container: container, clock: clock, horizon: .days90)

        _ = await coordinator.runNextChunk(for: .steps) // chunk 1: now-30d ... now
        _ = await coordinator.runNextChunk(for: .steps) // chunk 2: now-60d ... now-30d
        _ = await coordinator.runNextChunk(for: .steps) // chunk 3 (final, clipped): now-90d ... now-60d

        #expect(mock.calls.count == 3)
        let day: TimeInterval = 24 * 3600
        #expect(mock.calls[0].since == Self.fixedNow.addingTimeInterval(-30 * day))
        #expect(mock.calls[0].until == Self.fixedNow)
        #expect(mock.calls[1].since == Self.fixedNow.addingTimeInterval(-60 * day))
        #expect(mock.calls[1].until == Self.fixedNow.addingTimeInterval(-30 * day))
        #expect(mock.calls[2].since == Self.fixedNow.addingTimeInterval(-90 * day))
        #expect(mock.calls[2].until == Self.fixedNow.addingTimeInterval(-60 * day))

        // .days90 (90d) is an exact multiple of the 30d chunk size, so the
        // third chunk should exactly reach the horizon and report done.
        let fourth = await coordinator.runNextChunk(for: .steps)
        #expect(fourth == .alreadyDone)
    }

    // MARK: - Kill-resume from checkpoint

    @Test func killAndReconstructResumesFromTheCheckpointNotFromScratch() async throws {
        // One shared, persistent-for-the-test container + horizon store --
        // standing in for "the on-disk SwiftData store and UserDefaults
        // survive the app being killed", exactly as `SyncEngineTests`' own
        // shared-in-memory-container pattern stands in for real persistence.
        let container = try CoreModel.makeContainer(inMemory: true)
        let horizonStore = InMemoryBackfillHorizonRecordStore()
        let clock = TestSyncClock(Self.fixedNow)
        let mock = MockGoogleReconcileClient()
        mock.setPage(type: .steps, pageToken: nil, page: Page(points: [], nextPageToken: nil))

        var coordinator: BackfillCoordinator? = Self.makeCoordinator(
            client: mock, container: container, clock: clock, horizonStore: horizonStore, horizon: .year1
        )

        // Run three chunks, then "kill" -- discard the coordinator entirely
        // without ever calling stop()/pause() on it, simulating a hard
        // process kill mid-backfill.
        _ = await coordinator!.runNextChunk(for: .steps)
        _ = await coordinator!.runNextChunk(for: .steps)
        let thirdOutcome = await coordinator!.runNextChunk(for: .steps)
        guard case .processedChunk(let thirdWindow, _) = thirdOutcome else {
            Issue.record("expected the third chunk to process"); return
        }
        coordinator = nil // "kill": the only reference is dropped.

        let checkpointAfterKill = try BackfillTestFixtures.syncState(container, type: .steps)?.backfillCursor
        #expect(checkpointAfterKill == thirdWindow.lowerBound)

        // Reconstruct a brand-new `BackfillCoordinator` from the persisted
        // `SyncState` (same container) + persisted horizon-completion record
        // (same horizon store) -- nothing else carried over from the killed
        // instance.
        let resumed = Self.makeCoordinator(
            client: mock, container: container, clock: clock, horizonStore: horizonStore, horizon: .year1
        )
        let fourthOutcome = await resumed.runNextChunk(for: .steps)
        guard case .processedChunk(let fourthWindow, _) = fourthOutcome else {
            Issue.record("expected resumption to process a fourth chunk, got \(fourthOutcome)"); return
        }

        // Resumes from exactly the checkpoint -- the fourth chunk's upper
        // bound is the third chunk's lower bound, *not* a restart from
        // `now` (which would instead re-request `[now-30d, now]`, identical
        // to the very first chunk).
        #expect(fourthWindow.upperBound == thirdWindow.lowerBound)
        #expect(fourthWindow.upperBound != Self.fixedNow)
        #expect(mock.calls.count == 4)
    }

    // MARK: - No-progress loop exit (round-7 item 9)

    /// Mutable disabled-set behind the coordinator's per-chunk provider.
    final class MutableDisabledTypes: @unchecked Sendable {
        private let lock = NSLock()
        private var disabled: Set<GoogleDataType>
        init(disabled: Set<GoogleDataType>) { self.disabled = disabled }
        func get() -> Set<GoogleDataType> { lock.withLock { disabled } }
        func set(_ value: Set<GoogleDataType>) { lock.withLock { disabled = value } }
    }

    @Test func allDisabledRoundSuspendsEveryType() async throws {
        // The deterministic half: an all-disabled round reports
        // `.suspendedDisabled` per type with zero client calls and
        // zero writes (no timing involved).
        let container = try CoreModel.makeContainer(inMemory: true)
        let clock = TestSyncClock(Self.fixedNow)
        let mock = MockGoogleReconcileClient()
        let coordinator = BackfillCoordinator(
            types: [.steps],
            client: mock,
            writer: HealthKitWriter(store: MockHealthStore()),
            modelContainer: container,
            clock: clock,
            disabledTypes: { [.steps] },
            horizonStore: InMemoryBackfillHorizonRecordStore(),
            horizon: .days90
        )
        #expect(await coordinator.runRound() == [.steps: .suspendedDisabled])
        #expect(mock.calls.isEmpty)
    }

    @Test func doubleStopThenStartLaunchesASingleLoop() async throws {
        // Round-8 item 9: stop#1 publishes the retiring loop; stop#2
        // (nil handle) must preserve it — otherwise a start() arriving
        // mid-drain sails past into a second concurrent walk over the
        // same cursor. Round-9 item 14 reconciliation: stop#2 now
        // SUSPENDS on the in-flight drain (stop returns only when no
        // loop is running), so the second stop runs CONCURRENTLY here
        // — a sequential `await stop()` while parked would deadlock
        // the test body before `gate.open()` by design, not by bug.
        // The pins are unchanged: publication preserved, start
        // suspends mid-drain (single loop after), everything drains
        // orderly. Every phase is watchdog-bounded (fail loud, never
        // hang the suite).
        let container = try CoreModel.makeContainer(inMemory: true)
        let clock = TestSyncClock(Self.fixedNow)
        let mock = MockGoogleReconcileClient()
        mock.setPage(type: .steps, pageToken: nil, page: Page(points: [], nextPageToken: nil))
        let gate = AsyncGate()
        mock.gate = gate
        let coordinator = BackfillCoordinator(
            types: [.steps],
            client: mock,
            writer: HealthKitWriter(store: MockHealthStore()),
            modelContainer: container,
            clock: clock,
            // Hermetic horizon store (round-8 item 9 follow-up): the
            // default is UserDefaults-backed and persists across runs
            // on the host — a completed horizon recorded here (or by
            // any earlier run on this machine) would flip this test's
            // first branch to `.alreadyDone` and hang it at the gate.
            // Never share mutable host state between test runs.
            horizonStore: InMemoryBackfillHorizonRecordStore(),
            horizon: .days90
        )
        // Watchdog: poll `condition` until true or timeout; records
        // (never hangs) on timeout. Returns whether it succeeded.
        func settle(_ what: String, _ condition: () async -> Bool) async -> Bool {
            let start = Date.now
            while await condition() == false {
                await Task.yield()
                if Date.now.timeIntervalSince(start) > 10 {
                    Issue.record("watchdog: \(what)")
                    return false
                }
            }
            return true
        }
        await coordinator.start()
        await gate.waitUntilEntered()
        let stopFirst = Task { await coordinator.stop() }
        guard await settle("stop#1 nils the handle", { !(await coordinator.isLoopRunning) }) else { return }
        // Concurrent (see header): stop#2 must WAIT here, not return.
        let secondDone = StopFlag()
        let stopSecond = Task {
            await coordinator.stop()
            await secondDone.set()
        }
        var startReturned = false
        let restart = Task {
            await coordinator.start()
            startReturned = true
        }
        // Verdict phase: give both tasks generous time to run their
        // calls, then pin SUSPENSION (a start launch here is the
        // round-8 bug — the publication was erased; a stop#2 return
        // here is the round-9 bug — the drain was skipped).
        try await Task.sleep(for: .milliseconds(500))
        #expect(!startReturned)
        #expect(await secondDone.get() == false)
        await gate.open()
        // Drain phase: every join bounded by the same watchdog.
        await stopFirst.value
        await stopSecond.value
        guard await settle("restart launches after drain", { startReturned }) else { return }
        await restart.value
        guard await settle("restarted loop drains", { !(await coordinator.isLoopRunning) }) else { return }
        #expect(mock.callCount(type: .steps, pageToken: nil) >= 2)
        await coordinator.stop()
        #expect(!(await coordinator.isLoopRunning))
    }

    @Test func failedChunkLeavesNoResolverResidue() async throws {
        // Round-8 item 12: a chunk failing AFTER beginRun created its
        // run entry must still drain (converging on SyncEngine's catch
        // shape) — pre-fix the coverage slot + run entry leaked until
        // some later run's beginRun reset them.
        let container = try CoreModel.makeContainer(inMemory: true)
        let clock = TestSyncClock(Self.fixedNow)
        let mock = MockGoogleReconcileClient()
        mock.setScript(type: .steps, pageToken: nil, results: [.failure(.server(status: 500))])
        let resolver = WatchConflictResolver(
            coverageProvider: StubWatchCoverageProvider(),
            writer: HealthKitWriter(store: MockHealthStore())
        )
        let coordinator = BackfillCoordinator(
            types: [.steps],
            client: mock,
            writer: HealthKitWriter(store: MockHealthStore()),
            modelContainer: container,
            clock: clock,
            conflictFilter: resolver,
            horizonStore: InMemoryBackfillHorizonRecordStore(),
            horizon: .days90
        )
        let outcome = await coordinator.runNextChunk(for: .steps)
        guard case .failed = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
        #expect(await resolver.trackedRunCount() == 0)
    }

    @Test func failedChunkLeavesNoLinkResidueOnSurvivingRows() async throws {
        // Round-9 item 7: the exercised session records a link for its
        // row, then page 2 fails. The upsert rolls back — but the row
        // PRE-EXISTED (committed before the run), so it survives. The
        // old catch applied the drained links and `try?` saved them
        // onto that survivor (stale link permanent — upsert never
        // resets `linkedWatchWorkoutUUID`). Drained must mean DROPPED.
        let container = try CoreModel.makeContainer(inMemory: true)
        let clock = TestSyncClock(Self.fixedNow)
        let survivor = LocalSample(
            externalID: "flip-link-1",
            dataType: GoogleDataType.exercise.rawValue,
            payloadJSON: Data(),
            start: BackfillTestFixtures.date("2026-07-09T10:02:00Z"),
            end: BackfillTestFixtures.date("2026-07-09T10:43:00Z"),
            source: "flip"
        )
        let seed = ModelContext(container)
        seed.insert(survivor)
        try seed.save()
        let mock = MockGoogleReconcileClient()
        let session = [TypeMapperFixtures.exercisePoint(
            id: "flip-link-1",
            start: BackfillTestFixtures.date("2026-07-09T10:02:00Z"),
            end: BackfillTestFixtures.date("2026-07-09T10:43:00Z")
        )]
        mock.setScript(
            type: .exercise,
            pageToken: nil,
            results: [.success(Page(points: session, nextPageToken: "flip-p2"))]
        )
        mock.setScript(
            type: .exercise,
            pageToken: "flip-p2",
            results: [.failure(.server(status: 500))]
        )
        let coverage = StubWatchCoverageProvider()
        coverage.windows = [WatchConflictResolverTests.morningRunWindow()]
        let resolver = WatchConflictResolver(
            coverageProvider: coverage,
            writer: HealthKitWriter(store: MockHealthStore()),
            preference: StubWatchPriorityPreference(enabled: true)
        )
        let coordinator = BackfillCoordinator(
            types: [.exercise],
            client: mock,
            writer: HealthKitWriter(store: MockHealthStore()),
            modelContainer: container,
            clock: clock,
            conflictFilter: resolver,
            horizonStore: InMemoryBackfillHorizonRecordStore(),
            horizon: .days90
        )
        let outcome = await coordinator.runNextChunk(for: .exercise)
        guard case .failed = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
        let survivors = try ModelContext(container).fetch(FetchDescriptor<LocalSample>(
            predicate: #Predicate { $0.externalID == "flip-link-1" }
        ))
        let row = try #require(survivors.first)
        #expect(row.linkedWatchWorkoutUUID == nil)
        #expect(await resolver.trackedRunCount() == 0)
    }

    @Test func stopWaitsForDrainOnAllPaths() async throws {
        // Round-9 item 14: stop#1 publishes the draining loop; stop#2
        // (nil handle) must ALSO wait for it — not return while the
        // retired walk still drains (postcondition broken for
        // stop-then-wipe callers). Pre-fix stop#2 returned immediately.
        let container = try CoreModel.makeContainer(inMemory: true)
        let clock = TestSyncClock(Self.fixedNow)
        let mock = MockGoogleReconcileClient()
        mock.setPage(type: .steps, pageToken: nil, page: Page(points: [], nextPageToken: nil))
        let gate = AsyncGate()
        mock.gate = gate
        let coordinator = BackfillCoordinator(
            types: [.steps],
            client: mock,
            writer: HealthKitWriter(store: MockHealthStore()),
            modelContainer: container,
            clock: clock,
            horizonStore: InMemoryBackfillHorizonRecordStore(),
            horizon: .days90
        )
        await coordinator.start()
        await gate.waitUntilEntered()
        let stopFirst = Task { await coordinator.stop() }
        let start = Date.now
        while await coordinator.isLoopRunning {
            await Task.yield()
            if Date.now.timeIntervalSince(start) > 10 {
                Issue.record("stop#1 never nilled the handle")
                break
            }
        }
        let secondDone = StopFlag()
        let stopSecond = Task {
            await coordinator.stop()
            await secondDone.set()
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await secondDone.get() == false)
        await gate.open()
        await stopFirst.value
        await stopSecond.value
        #expect(!(await coordinator.isLoopRunning))
    }

    @Test func allDisabledLoopExitsAndRestartsOnReenable() async throws {
        // Round-7 item 9: an all-disabled loop EXITS (no 2s-delay spin
        // for process lifetime) and restarts when the type is
        // re-enabled (the view polls `isLoopRunning` for exactly this).
        let container = try CoreModel.makeContainer(inMemory: true)
        let clock = TestSyncClock(Self.fixedNow)
        let mock = MockGoogleReconcileClient()
        mock.setPage(type: .steps, pageToken: nil, page: Page(points: [], nextPageToken: nil))
        let gate = MutableDisabledTypes(disabled: [.steps])
        let coordinator = BackfillCoordinator(
            types: [.steps],
            client: mock,
            writer: HealthKitWriter(store: MockHealthStore()),
            modelContainer: container,
            clock: clock,
            disabledTypes: { gate.get() },
            horizonStore: InMemoryBackfillHorizonRecordStore(),
            horizon: .days90
        )
        await coordinator.start()
        let start = Date.now
        while await coordinator.isLoopRunning {
            await Task.yield()
            if Date.now.timeIntervalSince(start) > 10 {
                Issue.record("disabled loop never exited")
                break
            }
        }
        #expect(!(await coordinator.isLoopRunning))
        // Re-enable: the type runs again (restart path the view drives).
        gate.set([])
        let outcome = await coordinator.runNextChunk(for: .steps)
        guard case .processedChunk = outcome else {
            Issue.record("expected re-enabled type to process, got \(outcome)")
            return
        }
    }
}
#endif
