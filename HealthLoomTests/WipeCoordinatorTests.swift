// WipeCoordinatorTests.swift
//
// WP-35 (implementation-plan.md) "Tests:" line: the wipe leaves
// keychain/store empty (scripted full run), and HK delete-by-source
// removes only app-written samples. Real Keychain can't run in the
// unsigned test process (WP-03 note), so keychain assertions go through
// `InMemoryCloudKeyStore`; real HealthKit needs granted authorization,
// so the app-written filter runs against stub samples with a
// metadata-keyed bundle-ID seam, plus a real-store integration test
// gated on authorization (SyncKit's integration precedent).

import CoreModel
import Foundation
import HealthKit
import Secrets
import SwiftData
import SyncKit
import Testing
@testable import HealthLoom

// MARK: - HealthKitSourceDeleter (stubbed store)

private enum StubSource {
    static let ownBundle = "com.healthloom.app.test"
    static let otherBundle = "com.watch.apple"

    static func sample(
        bundle: String?,
        steps: Double = 100,
        type: HKQuantityType
    ) -> HKQuantitySample {
        var metadata: [String: Any]? = nil
        if let bundle {
            metadata = ["stubSourceBundle": bundle]
        }
        return HKQuantitySample(
            type: type,
            quantity: HKQuantity(unit: .count(), doubleValue: steps),
            start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_700_003_600),
            metadata: metadata
        )
    }

    /// Steps quantity type or a recorded issue (N2: no force-unwrap —
    /// the type object may be absent where HealthKit is unavailable).
    static func stepsType() throws -> HKQuantityType {
        try #require(HKObjectType.quantityType(forIdentifier: .stepCount))
    }
}

@Suite("HealthKitSourceDeleter")
struct HealthKitSourceDeleterTests {
    @Test("deletes only this app's samples and reports per-type counts")
    func onlyOursDeleted() async throws {
        let steps = try StubSource.stepsType()
        let oursA = StubSource.sample(bundle: StubSource.ownBundle, steps: 100, type: steps)
        let oursB = StubSource.sample(bundle: StubSource.ownBundle, steps: 200, type: steps)
        let theirs = StubSource.sample(bundle: StubSource.otherBundle, steps: 9999, type: steps)
        let unknown = StubSource.sample(bundle: nil, type: steps)
        let deleted = Locked<[HKObject]>([])
        var progress: [Int] = []
        let deleter = HealthKitSourceDeleter(
            fetchAll: { _ in [oursA, oursB, theirs, unknown] },
            bundleID: { $0.metadata?["stubSourceBundle"] as? String },
            deleteObjects: { objects in
                deleted.append(contentsOf: objects)
            }
        )
        let stepsType = try StubSource.stepsType()
        let outcomes = await deleter.deleteAppWritten(
            types: [stepsType],
            ownBundleID: StubSource.ownBundle,
            onProgress: { _, count in progress.append(count) }
        )
        #expect(deleted.values.count == 2)
        #expect(!deleted.values.contains { ($0 as? HKQuantitySample)?.quantity.doubleValue(for: .count()) == 9999 })
        let result = try #require(outcomes[stepsType])
        #expect(try result.get() == 2)
        #expect(progress == [2])
    }

    @Test("one failing type neither throws nor strands the others")
    func perTypeIsolation() async throws {
        let stepsType = try StubSource.stepsType()
        let sleepType = try #require(HKObjectType.categoryType(forIdentifier: .sleepAnalysis))
        let deleter = HealthKitSourceDeleter(
            fetchAll: { type in
                if type == stepsType { throw WipeBoom() }
                return []
            },
            bundleID: { _ in nil },
            deleteObjects: { _ in }
        )
        let outcomes = await deleter.deleteAppWritten(types: [stepsType, sleepType], ownBundleID: "x")
        let stepsOutcome = try #require(outcomes[stepsType])
        guard case .failure = stepsOutcome else {
            Issue.record("steps should fail")
            return
        }
        let sleepOutcome = try #require(outcomes[sleepType])
        #expect(try sleepOutcome.get() == 0)
    }
}

/// Recording `HealthStoreProtocol` double (round-4-sync item 9): tracks
/// every query vs server-side delete, so the wipe-path test proves the
/// live route issues ZERO sample queries (no unbounded fetch) and
/// deletes per type via `deleteAllAppData`.
private final class RecordingWipeStore: HealthStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var queryCalls = 0
    private(set) var deleteAllAppDataCalls: [HKObjectType] = []
    var deleteError: [String: HealthKitWriterError] = [:]
    var cannedCounts: [String: Int] = [:]

    func save(_ objects: [HKObject]) async throws(HealthKitWriterError) {}
    func existingExternalIDs(ofType sampleType: HKSampleType, start: Date, end: Date) async throws(HealthKitWriterError) -> Set<String> {
        lock.withLock { queryCalls += 1 }
        return []
    }
    func appWrittenSampleRecords(ofType sampleType: HKSampleType, start: Date, end: Date) async throws(HealthKitWriterError) -> [AppWrittenSampleRecord] {
        lock.withLock { queryCalls += 1 }
        return []
    }
    func deleteObjects(ofType objectType: HKObjectType, externalIDs: Set<String>) async throws(HealthKitWriterError) -> Int {
        0
    }
    func deleteAllAppData(ofType objectType: HKObjectType) async throws(HealthKitWriterError) -> Int {
        lock.withLock { deleteAllAppDataCalls.append(objectType) }
        if let error = deleteError[objectType.identifier] { throw error }
        return cannedCounts[objectType.identifier] ?? 0
    }
}

@Suite("HealthKitSourceDeleter live path (server-side delete)")
struct HealthKitSourceDeleterLiveTests {
    @Test("live wipe issues zero queries and deletes per type")
    func liveWipeIsServerSide() async throws {
        // Round-4-sync item 9: the regression — 10k samples in the
        // store must NOT be fetched (queryCalls stays 0); each type is
        // deleted server-side exactly once with its count reported.
        let store = RecordingWipeStore()
        store.cannedCounts = [
            HKQuantityTypeIdentifier.stepCount.rawValue: 10_000,
            HKCategoryTypeIdentifier.sleepAnalysis.rawValue: 42,
        ]
        let stepsType = try StubSource.stepsType()
        let sleepType = try #require(HKObjectType.categoryType(forIdentifier: .sleepAnalysis))
        var progress: [(HKObjectType, Int)] = []
        let outcomes = await HealthKitSourceDeleter.deleteAppWrittenLive(
            types: [stepsType, sleepType],
            writer: HealthKitWriter(store: store),
            onProgress: { progress.append(($0, $1)) }
        )
        #expect(store.queryCalls == 0)
        #expect(store.deleteAllAppDataCalls == [stepsType, sleepType])
        #expect(try outcomes[stepsType]?.get() == 10_000)
        #expect(try outcomes[sleepType]?.get() == 42)
        #expect(progress.map(\.1) == [10_000, 42])
    }

    @Test("denied silent zero fails loud; undetermined zero is provably empty")
    func wipeStatusTable() async throws {
        // Fix-round F1: the full authorization-status table. Denied +
        // silent zero is unverifiable → failure row (ledger/partial).
        // Never-granted (.notDetermined) + zero is PROVABLY empty →
        // success (the old Bool seam failed the step here). A real
        // deletion count succeeds under any status; both types attempt.
        let store = RecordingWipeStore()
        let stepsType = try StubSource.stepsType()
        let sleepType = try #require(HKObjectType.categoryType(forIdentifier: .sleepAnalysis))
        let restType = try #require(HKObjectType.quantityType(forIdentifier: .restingHeartRate))
        store.cannedCounts = [sleepType.identifier: 7]
        let outcomes = await HealthKitSourceDeleter.deleteAppWrittenLive(
            types: [stepsType, sleepType, restType],
            writer: HealthKitWriter(store: store),
            authorizationStatus: { type in
                type == stepsType ? .sharingDenied : .notDetermined
            }
        )
        guard case .failure = try #require(outcomes[stepsType]) else {
            Issue.record("denied silent zero should fail")
            return
        }
        #expect(try outcomes[sleepType]?.get() == 7)
        #expect(try outcomes[restType]?.get() == 0) // never granted: provably empty
        #expect(store.deleteAllAppDataCalls == [stepsType, sleepType, restType]) // all ATTEMPTED
    }

    @Test("live wipe isolates per-type failures")
    func liveWipePerTypeIsolation() async throws {
        // One failing type neither throws nor strands the other — same
        // contract as the seam path, now on the server-side route.
        struct WipeBoom: Error {}
        let store = RecordingWipeStore()
        let stepsType = try StubSource.stepsType()
        let sleepType = try #require(HKObjectType.categoryType(forIdentifier: .sleepAnalysis))
        store.deleteError = [stepsType.identifier: .underlying("boom")]
        store.cannedCounts = [sleepType.identifier: 7]
        let outcomes = await HealthKitSourceDeleter.deleteAppWrittenLive(
            types: [stepsType, sleepType],
            writer: HealthKitWriter(store: store)
        )
        guard case .failure = try #require(outcomes[stepsType]) else {
            Issue.record("steps should fail")
            return
        }
        #expect(try outcomes[sleepType]?.get() == 7)
    }
}

/// Trivial Sendable box (test-only).
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    var values: Value
    init(_ values: Value) { self.values = values }
    func append(contentsOf new: [HKObject]) where Value == [HKObject] {
        lock.withLock { values.append(contentsOf: new) }
    }
}

private struct WipeBoom: Error {}

/// Trivial Sendable box (test-only).

@Suite("StoreDeleter")
struct StoreDeleterTests {
    @Test("removes main plus SQLite sidecars; missing is success")
    func removesSidecars() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let main = dir.appending(path: "CoreModel.store")
        let urls = [main.path, main.path + "-wal", main.path + "-shm"].map { URL(fileURLWithPath: $0) }
        for url in urls {
            try Data("x".utf8).write(to: url)
        }
        let removed = try StoreDeleter.deleteStoreFiles(in: urls)
        #expect(removed.count == 3)
        #expect(!FileManager.default.fileExists(atPath: main.path))
        // Second run: nothing there, still success.
        #expect(try StoreDeleter.deleteStoreFiles(in: urls).isEmpty)
    }

    @Test("wipe inventory covers journal mode and the sync log")
    func wipeInventoryComplete() throws {
        // Round-7 item 6: the wipe LIST (not just the loop) must name
        // `-journal` (rollback-mode sidecar) and `SyncLog.json` —
        // both survived the old list past a "cannot be undone" wipe.
        let names = try StoreDeleter.storeFileURLs().map(\.lastPathComponent)
        #expect(names.contains("CoreModel.store"))
        #expect(names.contains("CoreModel.store-wal"))
        #expect(names.contains("CoreModel.store-shm"))
        #expect(names.contains("CoreModel.store-journal"))
        #expect(names.contains("SyncLog.json"))
        // And the loop removes a journal file like any other entry.
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let journal = dir.appending(path: "CoreModel.store-journal")
        try Data("x".utf8).write(to: journal)
        #expect(try StoreDeleter.deleteStoreFiles(in: [journal]).count == 1)
        #expect(!FileManager.default.fileExists(atPath: journal.path))
    }

    @Test("store and export deletes are attempted independently")
    func storeAndExportsAggregate() throws {
        // Round-8 item 3: all four combinations — a throwing store
        // step must still sweep exports (and vice versa); the FIRST
        // error surfaces, nothing is skipped silently.
        struct Boom: Error {}
        let okURL = URL(fileURLWithPath: "/tmp/ok")
        #expect(try StoreDeleter.deleteStoreAndExports(deleteStore: { [okURL] }, deleteExports: { [okURL] }) == [okURL, okURL])
        #expect(throws: Boom.self) {
            try StoreDeleter.deleteStoreAndExports(deleteStore: { throw Boom() }, deleteExports: { [okURL] })
        }
        #expect(throws: Boom.self) {
            try StoreDeleter.deleteStoreAndExports(deleteStore: { [okURL] }, deleteExports: { throw Boom() })
        }
        // Both throw: the STORE error (first) surfaces.
        struct SecondBoom: Error {}
        do {
            _ = try StoreDeleter.deleteStoreAndExports(deleteStore: { throw Boom() }, deleteExports: { throw SecondBoom() })
            Issue.record("expected throw")
        } catch is Boom {
        } catch {
            Issue.record("expected the store error, got \(error)")
        }
    }

    @Test("enumeration cross-check names future files loudly")
    func uncoveredFilesTripwire() throws {
        // Round-7 fix N1: a directory holding exactly the inventory
        // reports nothing; one extra (future) file is named. The
        // production full-inventory path throws on a non-empty answer
        // (fail the step, never escape silently); explicit-subset
        // deletes stay quiet (their siblings are not their scope).
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let covered = dir.appending(path: "CoreModel.store")
        try Data("x".utf8).write(to: covered)
        #expect(try StoreDeleter.uncoveredFiles(in: dir, coveredBy: [covered]).isEmpty)
        let future = dir.appending(path: "FutureSidecar.db")
        try Data("x".utf8).write(to: future)
        #expect(try StoreDeleter.uncoveredFiles(in: dir, coveredBy: [covered]) == ["FutureSidecar.db"])
        // Explicit-subset deletes do not trip on siblings.
        #expect(try StoreDeleter.deleteStoreFiles(in: [covered]).count == 1)
    }
}

// MARK: - Full wipe (scripted doubles)

@Suite("WipeCoordinator")
struct WipeCoordinatorTests {
    @Test("ordered full wipe leaves keychain, store, and defaults empty")
    func fullWipe() async throws {
        let keys = InMemoryCloudKeyStore(values: [.googleRefreshToken: "rt", .claudeAPIKey: "ck"])
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeFile = dir.appending(path: "CoreModel.store")
        try Data("x".utf8).write(to: storeFile)
        let ephemeralWipe = try EphemeralDefaults(prefix: "wipecoordinator")
        // Round-3 item 11: the one KEPT explicit lifetime — this holder
        // is bound-but-otherwise-unused after the projections below
        // (only `defaults`/`suiteName` escape), so without the defer the
        // suite could drop before the domain-contents assertion reads it.
        defer { withExtendedLifetime(ephemeralWipe) {} }
        let defaults = ephemeralWipe.defaults
        let suiteName = ephemeralWipe.suiteName
        defaults.set(true, forKey: "someKey")

        var revoked = false
        var hkCalls = 0
        var cloudCalls = 0
        let coordinator = WipeCoordinator(
            deps: WipeCoordinator.Dependencies(
                revokeGoogle: {
                    revoked = true
                    return .revoked
                },
                deleteAllKeys: {
                    for key in SecretKey.allCases {
                        try await keys.delete(key)
                    }
                },
                deleteHealthKit: {
                    hkCalls += 1
                    // Absent type object (no HealthKit) fails the step
                    // instead of silently reporting zero types.
                    guard let steps = HKObjectType.quantityType(forIdentifier: .stepCount) else {
                        throw WipeBoom()
                    }
                    return [steps: .success(3)]
                },
                deleteCloudKit: {
                    cloudCalls += 1
                    return 5
                },
                deleteStore: {
                    try StoreDeleter.deleteStoreFiles(in: [storeFile])
                },
                resetDefaults: {
                    defaults.removePersistentDomain(forName: suiteName)
                }
            ),
            includeHealthKit: true
        )
        await coordinator.run()

        #expect(revoked)
        #expect(coordinator.isFinished)
        #expect(coordinator.failedSteps.isEmpty)
        for step in WipeCoordinator.Step.allCases {
            guard case .done = coordinator.states[step] else {
                Issue.record("\(step) should be done")
                return
            }
        }
        // Keychain empty (every provider key, not just Google's).
        for key in SecretKey.allCases {
            #expect(try await keys.get(key) == nil)
        }
        // Store gone, defaults reset, HK path exercised. (Assert the
        // written key is gone rather than whole-domain emptiness — the
        // domain always carries ambient host keys.)
        #expect(!FileManager.default.fileExists(atPath: storeFile.path))
        #expect(defaults.object(forKey: "someKey") == nil)
        #expect(hkCalls == 1)
        // Round-6 item 1: the iCloud step ran with its ledger row.
        #expect(cloudCalls == 1)
        guard case .done(let cloudDetail) = coordinator.states[.cloudKit] else {
            Issue.record("cloudKit should be done")
            return
        }
        #expect(cloudDetail.contains("5"))
    }

    @Test("one failure never strands the rest")
    func failureContinues() async {
        struct Boom: Error {}
        let coordinator = WipeCoordinator(
            deps: WipeCoordinator.Dependencies(
                revokeGoogle: { throw WipeBoom() },
                deleteAllKeys: {},
                deleteHealthKit: { [:] },
                deleteCloudKit: { 0 },
                deleteStore: { [] },
                resetDefaults: {}
            ),
            includeHealthKit: true
        )
        await coordinator.run()
        guard case .failed = coordinator.states[.revokeGoogle] else {
            Issue.record("revoke should fail")
            return
        }
        guard case .done = coordinator.states[.keychain] else {
            Issue.record("keychain should still run")
            return
        }
        #expect(coordinator.failedSteps == [.revokeGoogle])
        #expect(coordinator.isFinished)
    }

    @Test("opting out marks HealthKit skipped, not failed")
    func healthKitOptOut() async {
        var hkCalls = 0
        let coordinator = WipeCoordinator(
            deps: WipeCoordinator.Dependencies(
                revokeGoogle: { .nothingStored },
                deleteAllKeys: {},
                deleteHealthKit: {
                    hkCalls += 1
                    return [:]
                },
                deleteCloudKit: { 0 },
                deleteStore: { [] },
                resetDefaults: {}
            ),
            includeHealthKit: false
        )
        await coordinator.run()
        #expect(hkCalls == 0)
        guard case .done(let detail) = coordinator.states[.healthKit] else {
            Issue.record("healthKit should be done-skipped")
            return
        }
        #expect(detail.contains("skipped"))
        #expect(coordinator.failedSteps.isEmpty)
    }
}

@Suite("WipeableTypes derivation")
struct WipeableTypesTests {
    @Test("wipe set equals exactly the authorized set (F1/F2/F10)")
    func matchesShareRequest() throws {
        // Pinned against the SHARED computation (F10), not rebuilt from
        // its sources: a future share extension through
        // `authorizedShareTypes` lands in the wipe automatically, and one
        // through any other channel breaks this equality loudly.
        let wipeable = try HealthKitSourceDeleter.wipeableTypes()
        let expected = try HealthKitAuth().authorizedShareTypes(
            sharing: AppEnvironment.p0Types,
            includingWorkoutShare: true
        )
        #expect(Set(wipeable) == expected)
        // Every cleanup distance bucket rides along (F2: cycling /
        // swimming / rowing distances must not survive).
        for identifier in HealthKitWriter.distanceIdentifiersForCleanup {
            let distance = try #require(HKObjectType.quantityType(forIdentifier: identifier))
            #expect(wipeable.contains(distance))
        }
    }

    @Test("narrowed request still wipes the historical floor")
    func narrowedRequestKeepsHistory() throws {
        // Round-6 item 14: if `p0Types` ever narrows (or a grant is
        // revoked), previously-written types stay in the wipe — a
        // narrowed request of just sleep must still wipe steps (and
        // the workout/energy/table types, which never depended on the
        // request list at all).
        let narrowed = try HealthKitSourceDeleter.wipeableTypes(requesting: [.sleep])
        let steps = try #require(HKObjectType.quantityType(forIdentifier: .stepCount))
        let sleep = try #require(HKObjectType.categoryType(forIdentifier: .sleepAnalysis))
        #expect(narrowed.contains(steps))
        #expect(narrowed.contains(sleep))
        #expect(narrowed.contains(HKObjectType.workoutType()))
        if let energy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) {
            #expect(narrowed.contains(energy))
        }
    }
}

// MARK: - Real HealthKit (integration, authorization-gated)

nonisolated private func hasRealHealthKitStepWriteAuthorization() -> Bool {
    guard HKHealthStore.isHealthDataAvailable() else { return false }
    guard let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) else { return false }
    return HKHealthStore().authorizationStatus(for: stepType) == .sharingAuthorized
}

@Suite("HealthKitSourceDeleter against the real store (integration)")
struct HealthKitSourceDeleterIntegrationTests {
    @Test(
        "real store: save two samples, delete-by-source removes both",
        .enabled(
            if: hasRealHealthKitStepWriteAuthorization(),
            "Needs granted HealthKit step-count write authorization (interactive only — same gap as SyncKit's integration suite)."
        )
    )
    func realDeleteBySource() async throws {
        let store = HKHealthStore()
        let stepsType = try StubSource.stepsType()
        let ownBundle = Bundle.main.bundleIdentifier ?? "com.healthloom.app"
        let base = Date().addingTimeInterval(-3600)
        let samples = (0..<2).map { i in
            HKQuantitySample(
                type: stepsType,
                quantity: HKQuantity(unit: .count(), doubleValue: Double(100 + i)),
                start: base.addingTimeInterval(Double(i) * 60),
                end: base.addingTimeInterval(Double(i) * 60 + 30)
            )
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.save(samples) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: HealthKitDeleteError.deleteReturnedFalse)
                }
            }
        }
        let deleter = HealthKitSourceDeleter.live(store: store)
        let outcomes = await deleter.deleteAppWritten(types: [stepsType], ownBundleID: ownBundle)
        let result = try #require(outcomes[stepsType])
        #expect(try result.get() == 2)
    }
}
