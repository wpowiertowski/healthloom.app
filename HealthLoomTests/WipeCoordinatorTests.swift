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
        let suiteName = "WipeCoordinatorTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "someKey")

        var revoked = false
        var hkCalls = 0
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
    }

    @Test("one failure never strands the rest")
    func failureContinues() async {
        struct Boom: Error {}
        let coordinator = WipeCoordinator(
            deps: WipeCoordinator.Dependencies(
                revokeGoogle: { throw WipeBoom() },
                deleteAllKeys: {},
                deleteHealthKit: { [:] },
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
