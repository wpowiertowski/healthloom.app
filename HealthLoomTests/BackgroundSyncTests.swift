// BackgroundSyncTests.swift
//
// Round-4-sync item 4 ("Tests" line): the background path honors Settings
// toggles end to end — a disabled type is never pulled or written by
// `HealthLoomBackgroundSync.run(context:)`, while an enabled sibling
// syncs normally. Drives the REAL due→filter→sync composition with a stub
// reconcile client and a recording health store; only `BGTaskScheduler`
// itself is out of reach in-process (so `run`, not the launch handler,
// is the unit under test — see its doc comment).
//
// Standard-defaults discipline: `run` reads the LIVE toggles by design
// (never snapshotted), so this test borrows the real key and hands it
// back via save/restore. Nothing else in this target touches
// `UserDefaults.standard` (see SyncPreferencesTests' header), so the
// borrow cannot skew a concurrent suite.

import CoreModel
import Foundation
import GoogleHealthClient
import HealthKit
import SwiftData
import SyncKit
import Testing
@testable import HealthLoom

/// Recording `GoogleReconcileClient`: scripted pages per type plus a full
/// call log, so the test asserts a disabled type was never even PULLED.
private final class BGStubReconcileClient: GoogleReconcileClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [GoogleDataType] = []
    var points: [GoogleDataType: [GoogleDataPoint]] = [:]

    nonisolated func reconcile(
        type: GoogleDataType,
        since: Date,
        until: Date,
        pageToken: String?
    ) async throws(GoogleHealthClientError) -> Page {
        lock.withLock { calls.append(type) }
        return Page(points: points[type] ?? [], nextPageToken: nil)
    }
}

/// Recording `HealthStoreProtocol`: saves are captured, existence is
/// empty — lets the test assert what the background path WROTE.
private final class BGRecordingHealthStore: HealthStoreProtocol, @unchecked Sendable {
    private(set) var savedBatches: [[HKObject]] = []

    func save(_ objects: [HKObject]) async throws(HealthKitWriterError) {
        savedBatches.append(objects)
    }

    func existingExternalIDs(
        ofType sampleType: HKSampleType,
        start: Date,
        end: Date
    ) async throws(HealthKitWriterError) -> Set<String> { [] }

    func appWrittenSampleRecords(
        ofType sampleType: HKSampleType,
        start: Date,
        end: Date
    ) async throws(HealthKitWriterError) -> [AppWrittenSampleRecord] { [] }

    func deleteObjects(
        ofType objectType: HKObjectType,
        externalIDs: Set<String>
    ) async throws(HealthKitWriterError) -> Int { 0 }

    func deleteAllAppData(
        ofType objectType: HKObjectType
    ) async throws(HealthKitWriterError) -> Int { 0 }
}

@Suite("BackgroundSync toggle filtering")
@MainActor
struct BackgroundSyncToggleTests {
    @Test("disabled type is never pulled or written on the background path")
    func disabledTypeSkipped() async throws {
        let prefs = SyncPreferences()
        let savedDisabled = prefs.disabledTypes
        defer {
            // Hand the real key back exactly as borrowed.
            let restore = SyncPreferences()
            for type in GoogleDataType.allCases {
                restore.setEnabled(!savedDisabled.contains(type), for: type)
            }
        }
        prefs.setEnabled(false, for: .steps)

        let container = try CoreModel.makeContainer(inMemory: true)
        let now = Date()
        func point(id: String, type: GoogleDataType, values: [String: Double]) -> GoogleDataPoint {
            GoogleDataPoint(
                id: id,
                dataType: type,
                start: now.addingTimeInterval(-3600),
                end: now.addingTimeInterval(-1800),
                source: DataSource(
                    platform: "IOS",
                    deviceDisplayName: "Fitbit Air",
                    recordingMethod: "AUTOMATICALLY_RECORDED"
                ),
                values: values
            )
        }
        let client = BGStubReconcileClient()
        client.points = [
            .steps: [point(id: "bg-steps-1", type: .steps, values: ["count": 100])],
            .heartRate: [point(id: "bg-hr-1", type: .heartRate, values: ["bpm": 70])],
        ]
        let store = BGRecordingHealthStore()
        let engine = SyncEngine(
            client: client,
            writer: HealthKitWriter(store: store),
            modelContainer: container
        )
        let context = BackgroundSyncLaunchContext(
            modelContainer: container,
            syncEngine: engine,
            syncableTypes: [.steps, .heartRate]
        )
        let outcomes = await HealthLoomBackgroundSync.run(context: context)
        // Steps disabled: never pulled…
        #expect(!client.calls.contains(.steps))
        // …heart rate enabled: pulled and written…
        #expect(client.calls.contains(.heartRate))
        let savedIDs = Set(
            store.savedBatches.flatMap { $0 }.compactMap { ($0 as? HKSample)?.sampleType.identifier }
        )
        #expect(!savedIDs.contains(HKQuantityTypeIdentifier.stepCount.rawValue))
        #expect(savedIDs.contains(HKQuantityTypeIdentifier.heartRate.rawValue))
        // …and the outcome list covers only the enabled type.
        #expect(outcomes.map(\.dataType) == [.heartRate])
    }

    @Test("cancelled background outcomes complete successfully")
    func cancelledIsSuccess() {
        // Round-6 item 7: an expiration-cancelled sync is a STOP, not
        // a failure — reporting failure throttles future wakes.
        func outcome(_ status: SyncStatus) -> SyncOutcome {
            SyncOutcome(dataType: .steps, status: status, itemCount: 0, suppressedCount: 0)
        }
        #expect(HealthLoomBackgroundSync.backgroundTaskSucceeded([]))
        #expect(HealthLoomBackgroundSync.backgroundTaskSucceeded([outcome(.ok)]))
        #expect(HealthLoomBackgroundSync.backgroundTaskSucceeded([outcome(.cancelled)]))
        #expect(HealthLoomBackgroundSync.backgroundTaskSucceeded([outcome(.ok), outcome(.cancelled)]))
        #expect(!HealthLoomBackgroundSync.backgroundTaskSucceeded([outcome(.error)]))
        #expect(!HealthLoomBackgroundSync.backgroundTaskSucceeded([outcome(.ok), outcome(.error)]))
    }
}
