// SyncEngineQuiesceTests.swift
//
// Third-party r9, DashboardView finding (SyncEngine half): the foreground manual-sync
// path had no wipe-quiesce guard — `SyncEngine` exposed no `isQuiesced` seam at all,
// so a post-wipe "Sync Now" resurrected HealthKit samples the wipe just deleted and
// wrote store rows through the unlinked handle.

#if canImport(HealthKit)
import CoreModel
import Foundation
import GoogleHealthClient
import SwiftData
import Testing
@testable import SyncKit

@Suite struct SyncEngineQuiesceTests {
    @Test func quiescedSyncReturnsCancelledWithoutTouchingClientOrStore() async throws {
        // Catches: a latched wipe followed by Sync Now must not run the pipeline.
        let container = try CoreModel.makeContainer(inMemory: true)
        let mock = MockGoogleReconcileClient()
        mock.setPage(type: .steps, pageToken: nil, page: Page(points: [], nextPageToken: nil))
        let engine = SyncEngine(
            client: mock,
            writer: HealthKitWriter(store: MockHealthStore()),
            modelContainer: container,
            isQuiesced: { true }
        )
        let outcome = await engine.sync(type: .steps)
        #expect(outcome.status == .cancelled)
        #expect(outcome.itemCount == 0)
        #expect(mock.calls.isEmpty)
        // No cursor row minted either.
        let context = ModelContext(container)
        let key = GoogleDataType.steps.rawValue
        let rows = try context.fetch(FetchDescriptor<SyncState>(predicate: #Predicate { $0.dataType == key }))
        #expect(rows.isEmpty)
    }

    @Test func unquiescedSyncRunsNormally() async throws {
        // Pin: the default (unlatched) path is unaffected — an empty window still
        // succeeds and mints its cursor row.
        let container = try CoreModel.makeContainer(inMemory: true)
        let mock = MockGoogleReconcileClient()
        mock.setPage(type: .steps, pageToken: nil, page: Page(points: [], nextPageToken: nil))
        let engine = SyncEngine(
            client: mock,
            writer: HealthKitWriter(store: MockHealthStore()),
            modelContainer: container,
            isQuiesced: { false }
        )
        let outcome = await engine.sync(type: .steps)
        #expect(outcome.status == .ok)
        #expect(mock.calls.count == 1)
    }

    @Test func quiescedSyncAllReturnsCancelledPerType() async throws {
        // Catches: `syncAll` funnels through the same choke point — every type
        // stops, none touches the client.
        let container = try CoreModel.makeContainer(inMemory: true)
        let mock = MockGoogleReconcileClient()
        let engine = SyncEngine(
            client: mock,
            writer: HealthKitWriter(store: MockHealthStore()),
            modelContainer: container,
            isQuiesced: { true }
        )
        let outcomes = await engine.syncAll(types: [.steps, .heartRate])
        #expect(outcomes.count == 2)
        #expect(outcomes.allSatisfy { $0.status == .cancelled })
        #expect(mock.calls.isEmpty)
    }
}
#endif
