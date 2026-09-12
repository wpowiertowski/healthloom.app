// BackfillQuiescePageCapTests.swift
//
// Third-party r9, two BackfillCoordinator findings:
// - F9 (`runNextChunk` choke point): only `start()`/`resume()` checked the wipe latch,
//   so a round already in progress kept pulling+writing after a wipe latched.
// - F7 (page-cap cursor): a page-cap hit inside a chunk still advanced `backfillCursor`
//   past the whole window with no lookback overlap to recover it — permanent loss
//   reported as `.processedChunk`.

#if canImport(HealthKit)
import CoreModel
import Foundation
import GoogleHealthClient
import SwiftData
import Testing
@testable import SyncKit

@Suite struct BackfillQuiescePageCapTests {
    static let fixedNow = BackfillTestFixtures.date("2026-07-10T12:00:00Z")

    static func makeCoordinator(
        client: MockGoogleReconcileClient,
        container: ModelContainer,
        clock: TestSyncClock,
        isQuiesced: @escaping @Sendable () -> Bool = { false }
    ) -> BackfillCoordinator {
        BackfillCoordinator(
            types: [.steps],
            client: client,
            writer: HealthKitWriter(store: MockHealthStore()),
            modelContainer: container,
            clock: clock,
            conflictFilter: IdentityConflictFilter(),
            horizonStore: InMemoryBackfillHorizonRecordStore(),
            busyProbe: AlwaysAvailableBusyProbe(),
            horizon: .year1,
            isQuiesced: isQuiesced
        )
    }

    static func backfillCursor(_ container: ModelContainer) throws -> Date? {
        let context = ModelContext(container)
        let key = GoogleDataType.steps.rawValue
        return try context.fetch(FetchDescriptor<SyncState>(predicate: #Predicate { $0.dataType == key })).first?.backfillCursor
    }

    @Test func quiescedChunkStopsWithoutPulling() async throws {
        // Catches: a latched wipe mid-round must stop the chunk at the choke point.
        let container = try CoreModel.makeContainer(inMemory: true)
        let clock = TestSyncClock(Self.fixedNow)
        let mock = MockGoogleReconcileClient()
        mock.setPage(type: .steps, pageToken: nil, page: Page(points: [], nextPageToken: nil))
        let coordinator = Self.makeCoordinator(client: mock, container: container, clock: clock, isQuiesced: { true })
        let outcome = await coordinator.runNextChunk(for: .steps)
        #expect(outcome == .suspendedCancelled)
        #expect(mock.calls.isEmpty)
    }

    @Test func unquiescedChunkStillProcesses() async throws {
        // Pin: the default path is unaffected.
        let container = try CoreModel.makeContainer(inMemory: true)
        let clock = TestSyncClock(Self.fixedNow)
        let mock = MockGoogleReconcileClient()
        mock.setPage(type: .steps, pageToken: nil, page: Page(points: [], nextPageToken: nil))
        let coordinator = Self.makeCoordinator(client: mock, container: container, clock: clock)
        let outcome = await coordinator.runNextChunk(for: .steps)
        guard case .processedChunk = outcome else {
            Issue.record("expected processedChunk, got \(outcome)")
            return
        }
        #expect(mock.calls.count == 1)
    }

    @Test func pageCapHitFailsWithoutAdvancingCursor() async throws {
        // Catches: 101 chained pages exceed `PagePipeline.maxPages` (100) inside one
        // chunk — the chunk must report `.failed` with the cursor held (nil, i.e. the
        // window retries), never `.processedChunk` past unwalked data.
        let container = try CoreModel.makeContainer(inMemory: true)
        let clock = TestSyncClock(Self.fixedNow)
        let mock = MockGoogleReconcileClient()
        // Chain pageToken nil -> "p1" -> ... -> "p100" (101 pages total).
        var token: String? = nil
        for i in 1...101 {
            let next = "p\(i)"
            mock.setPage(type: .steps, pageToken: token, page: Page(points: [], nextPageToken: next))
            token = next
        }
        let coordinator = Self.makeCoordinator(client: mock, container: container, clock: clock)
        let outcome = await coordinator.runNextChunk(for: .steps)
        guard case .failed = outcome else {
            Issue.record("expected failed on page-cap hit, got \(outcome)")
            return
        }
        #expect(try Self.backfillCursor(container) == nil)
        // Error row surfaced (not a silent green).
        let context = ModelContext(container)
        let key = GoogleDataType.steps.rawValue
        let state = try context.fetch(FetchDescriptor<SyncState>(predicate: #Predicate { $0.dataType == key })).first
        #expect(state?.backfillStatus == SyncStatus.error.rawValue)
    }
}
#endif
