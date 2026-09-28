// BackfillIdempotencyTests.swift
//
// WP-15 (implementation-plan.md) "Tests:" line: "idempotency with
// overlapping incremental sync." Step 2: "suspends when a foreground
// incremental sync is active for a type (SyncEngine exposes an isBusy
// signal)." Two angles, both covered here:
//   1. The `BackfillBusyProbe` suspension itself (a stubbed probe, no real
//      `SyncEngine` needed to prove the coordinator honors it).
//   2. The real dedupe path: `SyncEngine` and `BackfillCoordinator` sharing
//      one `HealthKitWriter`/`MockHealthStore` and independently "pulling"
//      the *same* external ID into overlapping windows must still leave
//      exactly one sample in the store (architecture.md D4's existing
//      batched existence-diff mechanism, reused verbatim -- not a parallel
//      one built for backfill).

#if canImport(HealthKit)
import CoreModel
import Foundation
import GoogleHealthClient
import HealthKit
import SwiftData
import Testing
@testable import SyncKit

@Suite struct BackfillIdempotencyTests {
    static let fixedNow = BackfillTestFixtures.date("2026-07-10T12:00:00Z")

    // MARK: - Busy-probe suspension

    @Test func aTypeReportedBusyIsSuspendedAndNeitherPullsNorAdvancesItsCursor() async throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let clock = TestSyncClock(Self.fixedNow)
        let mock = MockGoogleReconcileClient()
        mock.setPage(type: .steps, pageToken: nil, page: Page(points: [], nextPageToken: nil))
        let busyProbe = StubBusyProbe(busy: [.steps])

        let coordinator = BackfillCoordinator(
            types: [.steps],
            client: mock,
            writer: HealthKitWriter(store: MockHealthStore()),
            modelContainer: container,
            clock: clock,
            horizonStore: InMemoryBackfillHorizonRecordStore(),
            busyProbe: busyProbe,
            horizon: .days90
        )

        let outcome = await coordinator.runNextChunk(for: .steps)
        #expect(outcome == .suspendedBusy)
        #expect(mock.calls.isEmpty, "a busy type must not be pulled at all")
        #expect(try BackfillTestFixtures.syncState(container, type: .steps)?.backfillCursor == nil)

        // Once the incremental sync finishes (busy flag clears), the exact
        // same chunk becomes available again.
        busyProbe.setBusy(false, for: .steps)
        let secondOutcome = await coordinator.runNextChunk(for: .steps)
        guard case .processedChunk = secondOutcome else {
            Issue.record("expected the chunk to process once no longer busy, got \(secondOutcome)"); return
        }
        #expect(mock.calls.count == 1)
        // Catches: a claim never released (the suspended round claimed
        // nothing; the processed one must hand its claim back).
        #expect(busyProbe.released == [.steps])
    }

    // MARK: - Real dedupe across SyncEngine + BackfillCoordinator

    @Test func aPointAlreadyWrittenByIncrementalSyncIsNotDuplicatedByAnOverlappingBackfillChunk() async throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let clock = TestSyncClock(Self.fixedNow)
        let sharedStore = MockHealthStore()
        let sharedWriter = HealthKitWriter(store: sharedStore)

        // 1. A foreground incremental sync (SyncEngine) writes one steps
        //    point via the real pipeline.
        let syncMock = MockGoogleReconcileClient()
        let overlapPoint = BackfillTestFixtures.stepsPoint(
            id: "steps-overlap-1",
            start: Self.fixedNow.addingTimeInterval(-10 * 24 * 3600),
            end: Self.fixedNow.addingTimeInterval(-10 * 24 * 3600 + 3600)
        )
        // SyncEngine's own default 7d initial window + 72h lookback covers
        // this point's timestamp (10 days back) comfortably.
        syncMock.setPage(type: .steps, pageToken: nil, page: Page(points: [overlapPoint], nextPageToken: nil))
        let syncEngine = SyncEngine(client: syncMock, writer: sharedWriter, modelContainer: container, clock: clock)

        let syncOutcome = await syncEngine.sync(type: .steps)
        #expect(syncOutcome.status == .ok)
        #expect(sharedStore.savedBatches.count == 1)
        let stepsType = try #require(HKObjectType.quantityType(forIdentifier: .stepCount))
        #expect(sharedStore.sampleCount(ofType: stepsType) == 1)

        // 2. A backfill chunk, independently scripted with the *same*
        //    external ID inside its window, must not write it again --
        //    proving the dedupe path is shared, not reimplemented.
        let backfillMock = MockGoogleReconcileClient()
        backfillMock.setPage(type: .steps, pageToken: nil, page: Page(points: [overlapPoint], nextPageToken: nil))
        let coordinator = BackfillCoordinator(
            types: [.steps],
            client: backfillMock,
            writer: sharedWriter,
            modelContainer: container,
            clock: clock,
            horizonStore: InMemoryBackfillHorizonRecordStore(),
            horizon: .days30
        )

        // .steps' SyncState now has lastSyncedAt == fixedNow (SyncEngine
        // just advanced it), so the first backfill chunk walks
        // [now-30d, now] -- which contains the overlap point (10 days back).
        let chunkOutcome = await coordinator.runNextChunk(for: .steps)
        guard case .processedChunk(let window, _) = chunkOutcome else {
            Issue.record("expected the backfill chunk to process, got \(chunkOutcome)"); return
        }
        #expect(window.lowerBound <= overlapPoint.start && overlapPoint.end <= window.upperBound)

        // No new save call was needed (the batch was empty -- the point's
        // external ID was already present per the batched existence diff),
        // and the store still holds exactly one sample.
        #expect(sharedStore.savedBatches.count == 1, "backfill must not issue a second save for an already-written external ID")
        #expect(sharedStore.sampleCount(ofType: stepsType) == 1)
    }
}
#endif
