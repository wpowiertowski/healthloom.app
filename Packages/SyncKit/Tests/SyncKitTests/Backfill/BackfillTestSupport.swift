// BackfillTestSupport.swift
//
// WP-15 (implementation-plan.md) test support, mirroring the house style
// `Tests/SyncKitTests/SyncEngine/{MockGoogleReconcileClient,TestSyncClock}.swift`
// already established: small, focused test doubles, no real networking/
// HealthKit-entitlement/UserDefaults/wall-clock dependency in any test.

#if canImport(HealthKit)
import CoreModel
import Foundation
import GoogleHealthClient
import SwiftData
@testable import SyncKit

/// In-memory `BackfillHorizonRecordStore` -- the test-target counterpart to
/// production's `UserDefaultsBackfillHorizonRecordStore` (BackfillTypes.swift),
/// same role `TestSyncClock` plays for `SystemSyncClock`. A plain
/// lock-protected dictionary; deliberately **not** wiped between a "kill" and
/// a freshly-constructed `BackfillCoordinator` in the kill-resume tests --
/// passing the *same instance* to both is exactly how those tests simulate
/// "the persisted side-store survived the process kill", the same way
/// reusing one in-memory `ModelContainer` simulates the SwiftData store
/// surviving it.
final class InMemoryBackfillHorizonRecordStore: BackfillHorizonRecordStore, @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var storage: [String: BackfillHorizon] = [:]

    init() {}

    nonisolated func completedHorizon(for type: GoogleDataType) -> BackfillHorizon? {
        lock.lock()
        defer { lock.unlock() }
        return storage[type.rawValue]
    }

    nonisolated func setCompletedHorizon(_ horizon: BackfillHorizon?, for type: GoogleDataType) {
        lock.lock()
        defer { lock.unlock() }
        storage[type.rawValue] = horizon
    }
}

/// Scriptable `BackfillBusyProbe` -- lets a test mark specific types "busy"
/// (a foreground/background incremental sync is in-flight for them) without
/// needing a real `SyncEngine`.
final class StubBusyProbe: BackfillBusyProbe, @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var busyTypes: Set<GoogleDataType> = []

    init(busy: Set<GoogleDataType> = []) {
        self.busyTypes = busy
    }

    func setBusy(_ isBusy: Bool, for type: GoogleDataType) {
        lock.lock()
        if isBusy { busyTypes.insert(type) } else { busyTypes.remove(type) }
        lock.unlock()
    }

    /// Every type released, in order -- a claim that isn't released would
    /// block that type's incremental sync forever.
    private nonisolated(unsafe) var releasedTypes: [GoogleDataType] = []
    var released: [GoogleDataType] { lock.withLock { releasedTypes } }

    // `NSLock.lock()`/`.unlock()` are unavailable from `async` contexts on
    // this toolchain -- same finding WP-09's own
    // `MockGoogleReconcileClient.reconcile` documents; `withLock` is a
    // synchronous closure, used here purely to protect the shared mutable
    // state.
    nonisolated func claimForBackfill(_ type: GoogleDataType) async -> Bool {
        lock.withLock { !busyTypes.contains(type) }
    }

    nonisolated func releaseBackfillClaim(_ type: GoogleDataType) async {
        lock.withLock { releasedTypes.append(type) }
    }
}

enum BackfillTestFixtures {
    static func date(_ iso8601: String) -> Date {
        guard let date = ISO8601DateFormatter().date(from: iso8601) else {
            preconditionFailure("Fixture date literal is not valid ISO 8601: \(iso8601)")
        }
        return date
    }

    /// A minimal `.steps` point at an arbitrary instant -- content doesn't
    /// matter for the window/bookkeeping-focused tests in this directory,
    /// only that it decodes and maps successfully via the real
    /// `TypeMapper.map(_:)` pipeline `BackfillCoordinator` drives.
    static func stepsPoint(id: String, start: Date, end: Date, count: Double = 100) -> GoogleDataPoint {
        GoogleDataPoint(
            id: id,
            dataType: .steps,
            start: start,
            end: end,
            source: DataSource(platform: "IOS", deviceDisplayName: "Fitbit Air", recordingMethod: "AUTOMATICALLY_RECORDED"),
            values: ["count": count]
        )
    }

    static func syncState(_ container: ModelContainer, type: GoogleDataType) throws -> SyncState? {
        let context = ModelContext(container)
        let key = type.rawValue
        let descriptor = FetchDescriptor<SyncState>(predicate: #Predicate { $0.dataType == key })
        return try context.fetch(descriptor).first
    }
}
#endif
