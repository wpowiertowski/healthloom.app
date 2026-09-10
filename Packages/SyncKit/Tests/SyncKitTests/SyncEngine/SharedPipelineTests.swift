// SharedPipelineTests.swift
//
// Round-4-sync item 15 ("Tests" line): the shared `PagePipeline` proves
// itself through BOTH engines — the same duplicate-page fixture driven
// through `SyncEngine.sync(type:)` and `BackfillCoordinator.runNextChunk`
// must produce identical write counts and item counts (either engine
// alone passing would not prove sharing). Plus item 5 (resolver-throw
// surfaces on both engines, zero writes), item 10 (failed completion
// save surfaces `.failed`), and the shared-payload shape pin.
//
// Same house rules as the neighboring suites: `MockGoogleReconcileClient`
// instead of networking, `MockHealthStore` instead of HealthKit
// entitlements, in-memory containers, virtual clocks.

#if canImport(HealthKit)
import CoreModel
import Foundation
import GoogleHealthClient
import HealthKit
import SwiftData
import Testing
@testable import SyncKit

@Suite struct SharedPipelineTests {
    static let fixedNow = BackfillTestFixtures.date("2026-07-10T12:00:00Z")

    static func stepsPoint(id: String) -> GoogleDataPoint {
        let start = fixedNow.addingTimeInterval(-3600)
        return BackfillTestFixtures.stepsPoint(id: id, start: start, end: start.addingTimeInterval(1800))
    }

    // MARK: - Item 6, fixed once in the shared pipeline (both engines)

    @Test func duplicatePointInOnePageWrittenAndCountedOnce() async throws {
        // Round-4-sync item 6: the same point.id twice in ONE page must
        // write + count once (exactly-once contract). Pre-fix this wrote
        // 2 samples and reported itemCount 2.
        let container = try CoreModel.makeContainer(inMemory: true)
        let mock = MockGoogleReconcileClient()
        let point = Self.stepsPoint(id: "dup-1")
        mock.setPage(type: .steps, pageToken: nil, page: Page(points: [point, point], nextPageToken: nil))
        let store = MockHealthStore()
        let engine = SyncEngine(
            client: mock,
            writer: HealthKitWriter(store: store),
            modelContainer: container,
            clock: TestSyncClock(Self.fixedNow)
        )

        let outcome = await engine.sync(type: .steps)
        #expect(outcome.status == .ok)
        #expect(outcome.itemCount == 1)
        #expect(store.savedBatches.flatMap { $0 }.count == 1)
    }

    @Test func duplicatePointInOnePageWrittenAndCountedOnceBackfill() async throws {
        // Round-4-sync items 6+15: the IDENTICAL fixture through the
        // backfill chunk path — identical counts prove both engines run
        // the one shared pipeline (not two copies that happen to agree
        // today).
        let container = try CoreModel.makeContainer(inMemory: true)
        let mock = MockGoogleReconcileClient()
        let point = Self.stepsPoint(id: "dup-1")
        mock.setPage(type: .steps, pageToken: nil, page: Page(points: [point, point], nextPageToken: nil))
        let store = MockHealthStore()
        let coordinator = BackfillCoordinator(
            types: [.steps],
            client: mock,
            writer: HealthKitWriter(store: store),
            modelContainer: container,
            clock: TestSyncClock(Self.fixedNow),
            horizon: .days90
        )

        let outcome = await coordinator.runNextChunk(for: .steps)
        guard case .processedChunk(_, let itemCount) = outcome else {
            Issue.record("expected processedChunk, got \(outcome)")
            return
        }
        #expect(itemCount == 1)
        #expect(store.savedBatches.flatMap { $0 }.count == 1)
    }

    // MARK: - Item 5, resolver failure surfaces (both engines, zero writes)

    @Test func resolverThrowSurfacesErrorWithZeroWrites() async throws {
        // Round-4-sync item 5: a throwing resolver must surface (error
        // status + persisted message, non-ok outcome) with ZERO writes
        // and ZERO network calls — never a silent green rewrite.
        let container = try CoreModel.makeContainer(inMemory: true)
        let mock = MockGoogleReconcileClient()
        let store = MockHealthStore()
        let engine = SyncEngine(
            client: mock,
            writer: HealthKitWriter(store: store),
            modelContainer: container,
            clock: TestSyncClock(Self.fixedNow),
            sampleTypeResolver: { _ throws(UnresolvedHealthKitIdentifier) in throw UnresolvedHealthKitIdentifier(identifier: "bogus") }
        )

        let outcome = await engine.sync(type: .steps)
        #expect(outcome.status == .error)
        #expect(mock.calls.isEmpty)
        #expect(store.savedBatches.isEmpty)
        let context = ModelContext(container)
        let key = GoogleDataType.steps.rawValue
        let state = try #require(try context.fetch(
            FetchDescriptor<SyncState>(predicate: #Predicate { $0.dataType == key })
        ).first)
        #expect(state.lastStatus == SyncStatus.error.rawValue)
        #expect(state.lastError != nil)
    }

    @Test func resolverThrowFailsChunkWithZeroWrites() async throws {
        // Round-4-sync item 5, backfill half: `.failed` (never green),
        // zero writes, zero network.
        let container = try CoreModel.makeContainer(inMemory: true)
        let mock = MockGoogleReconcileClient()
        let store = MockHealthStore()
        let coordinator = BackfillCoordinator(
            types: [.steps],
            client: mock,
            writer: HealthKitWriter(store: store),
            modelContainer: container,
            clock: TestSyncClock(Self.fixedNow),
            sampleTypeResolver: { _ throws(UnresolvedHealthKitIdentifier) in throw UnresolvedHealthKitIdentifier(identifier: "bogus") },
            horizon: .days90
        )

        let outcome = await coordinator.runNextChunk(for: .steps)
        guard case .failed(let message) = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
        #expect(!message.isEmpty)
        #expect(mock.calls.isEmpty)
        #expect(store.savedBatches.isEmpty)
    }

    // MARK: - Item 4, disabled types are never pulled or written (backfill)

    @Test func disabledTypeIsNeverPulledOrWrittenBackfill() async throws {
        // Round-4-sync item 4, backfill half: a disabled type reports
        // `.suspendedDisabled` with zero client calls and zero writes;
        // an enabled sibling on the same coordinator still runs.
        let container = try CoreModel.makeContainer(inMemory: true)
        let mock = MockGoogleReconcileClient()
        mock.setPage(
            type: .sleep,
            pageToken: nil,
            page: Page(points: [], nextPageToken: nil)
        )
        let store = MockHealthStore()
        let coordinator = BackfillCoordinator(
            types: [.steps, .sleep],
            client: mock,
            writer: HealthKitWriter(store: store),
            modelContainer: container,
            clock: TestSyncClock(Self.fixedNow),
            disabledTypes: { [.steps] },
            horizon: .days90
        )
        #expect(await coordinator.runNextChunk(for: .steps) == .suspendedDisabled)
        #expect(mock.calls.isEmpty)
        #expect(store.savedBatches.isEmpty)
        let sibling = await coordinator.runNextChunk(for: .sleep)
        guard case .processedChunk = sibling else {
            Issue.record("expected sibling processedChunk, got \(sibling)")
            return
        }
        #expect(mock.calls.count == 1)
    }

    // MARK: - Item 8, echoing server terminates (both engines)

    @Test func constantTokenServerTerminates() async throws {
        // Round-6 item 8: a server that echoes the requested token
        // forever must terminate via the same-token break — never spin
        // burning quota (foreground Sync Now was unstoppable).
        let container = try CoreModel.makeContainer(inMemory: true)
        let mock = MockGoogleReconcileClient()
        mock.setPage(
            type: .steps,
            pageToken: nil,
            page: Page(points: [Self.stepsPoint(id: "echo-1")], nextPageToken: "echo")
        )
        mock.setPage(
            type: .steps,
            pageToken: "echo",
            page: Page(points: [Self.stepsPoint(id: "echo-1")], nextPageToken: "echo")
        )
        let store = MockHealthStore()
        let engine = SyncEngine(
            client: mock,
            writer: HealthKitWriter(store: store),
            modelContainer: container,
            clock: TestSyncClock(Self.fixedNow)
        )
        let outcome = await engine.sync(type: .steps)
        #expect(outcome.status == .ok)
        #expect(outcome.itemCount == 1) // second echo dedupes via the shared set
        #expect(mock.callCount(type: .steps, pageToken: nil) == 1)
        #expect(mock.callCount(type: .steps, pageToken: "echo") == 1)
    }

    @Test func constantTokenServerTerminatesBackfill() async throws {
        // Round-6 item 8, backfill half: same echo, same termination.
        let container = try CoreModel.makeContainer(inMemory: true)
        let mock = MockGoogleReconcileClient()
        mock.setPage(
            type: .steps,
            pageToken: nil,
            page: Page(points: [Self.stepsPoint(id: "echo-1")], nextPageToken: "echo")
        )
        mock.setPage(
            type: .steps,
            pageToken: "echo",
            page: Page(points: [Self.stepsPoint(id: "echo-1")], nextPageToken: "echo")
        )
        let coordinator = BackfillCoordinator(
            types: [.steps],
            client: mock,
            writer: HealthKitWriter(store: MockHealthStore()),
            modelContainer: container,
            clock: TestSyncClock(Self.fixedNow),
            horizon: .days90
        )
        let outcome = await coordinator.runNextChunk(for: .steps)
        guard case .processedChunk(_, let itemCount) = outcome else {
            Issue.record("expected processedChunk, got \(outcome)")
            return
        }
        #expect(itemCount == 1)
        #expect(mock.callCount(type: .steps, pageToken: nil) == 1)
        #expect(mock.callCount(type: .steps, pageToken: "echo") == 1)
    }

    // MARK: - Item 11, duplicated localOnly point writes+counts once

    @Test func duplicateLocalOnlyPointWritesAndCountsOnce() async throws {
        // Round-6 item 11: the same `.localOnly` point twice in one
        // page must upsert once and count once (exactly-once). The
        // upsert itself is idempotent (one row either way), so the
        // count is the contract observable — pre-fix it read 2.
        let container = try CoreModel.makeContainer(inMemory: true)
        let mock = MockGoogleReconcileClient()
        let start = Self.fixedNow.addingTimeInterval(-3600)
        // `.electrocardiogram` is `.localOnly`-writability: maps
        // unconditionally, regardless of values (same shape as
        // SyncEngineTests' own ecgPoint helper).
        let point = GoogleDataPoint(
            id: "ecg-dup",
            dataType: .electrocardiogram,
            start: start,
            end: start.addingTimeInterval(30),
            source: DataSource(platform: "IOS", deviceDisplayName: "Apple Watch", recordingMethod: "AUTOMATICALLY_RECORDED"),
            values: [:]
        )
        mock.setPage(type: .electrocardiogram, pageToken: nil, page: Page(points: [point, point], nextPageToken: nil))
        let engine = SyncEngine(
            client: mock,
            writer: HealthKitWriter(store: MockHealthStore()),
            modelContainer: container,
            clock: TestSyncClock(Self.fixedNow)
        )
        let outcome = await engine.sync(type: .electrocardiogram)
        #expect(outcome.status == .ok)
        #expect(outcome.itemCount == 1)
        let context = ModelContext(container)
        #expect(try context.fetch(FetchDescriptor<LocalSample>()).count == 1)
    }

    // MARK: - Item 10, failed completion save surfaces

    struct SaveBoom: Error {}

    @Test func failedCompletionSaveSurfacesFailed() async throws {
        // Round-4-sync item 10: a failing completion save must report
        // `.failed` (with the error row surfaced best-effort) — never
        // `.alreadyDone`. Setup parks the type exactly in the
        // already-caught-up branch (cursor nil, last sync older than the
        // horizon, no completed record); the injected save then throws.
        let container = try CoreModel.makeContainer(inMemory: true)
        let context = ModelContext(container)
        context.insert(SyncState(
            dataType: GoogleDataType.steps.rawValue,
            lastSyncedAt: Self.fixedNow.addingTimeInterval(-400 * 24 * 3600)
        ))
        try context.save()
        let horizonStore = InMemoryBackfillHorizonRecordStore()
        let coordinator = BackfillCoordinator(
            types: [.steps],
            client: MockGoogleReconcileClient(),
            writer: HealthKitWriter(store: MockHealthStore()),
            modelContainer: container,
            clock: TestSyncClock(Self.fixedNow),
            persistCompletionState: { _ in throw SaveBoom() },
            horizonStore: horizonStore,
            horizon: .days90
        )

        let outcome = await coordinator.runNextChunk(for: .steps)
        guard case .failed(let message) = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
        #expect(!message.isEmpty)
        // Surfaced via the error row (best-effort persist of the row
        // itself may also fail — the OUTCOME is the guarantee)…
        let check = ModelContext(container)
        let key = GoogleDataType.steps.rawValue
        let state = try #require(try check.fetch(
            FetchDescriptor<SyncState>(predicate: #Predicate { $0.dataType == key })
        ).first)
        #expect(state.backfillStatus == SyncStatus.error.rawValue)
        #expect(state.backfillError != nil)
        // …and completion was NOT recorded against a cursor that
        // disagrees…
        #expect(horizonStore.completedHorizon(for: .steps) == nil)
        // …and the next round reports failure again (retries visibly —
        // the loop no longer spins silently).
        let again = await coordinator.runNextChunk(for: .steps)
        guard case .failed = again else {
            Issue.record("expected failed again, got \(again)")
            return
        }
    }

    // MARK: - Shared payload shape pin

    @Test func sharedPayloadEncodesTheDocumentedFields() throws {
        // Round-4-sync item 15: `SharedLocalPayload` is the field-identical
        // union of the two deleted per-file payloads (same fields, same
        // declaration order — synthesized `Codable` therefore emits
        // byte-identical JSON). This pins the shape against future drift.
        let payload = SharedLocalPayload(point: Self.stepsPoint(id: "payload-1"))
        let data = try JSONEncoder().encode(payload)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == [
            "id", "dataType", "start", "end", "values",
            "sourcePlatform", "sourceDeviceDisplayName", "sourceRecordingMethod",
        ])
        #expect(json["id"] as? String == "payload-1")
    }
}
#endif
