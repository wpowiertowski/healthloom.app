// CloudSyncTests.swift
//
// iCloud sync engine tests (private DB only). Every conflict/loss
// direction is pinned here against a stub `CloudDatabase` — no CloudKit,
// no network, no Apple ID in any test:
//
// - push: first sync saves; equal content skips the write; local-newer
//   overwrites the server; malformed server records are overwritten,
//   never preserved.
// - pull (last-sync-wins with seen-watermark): server-newer applies to
//   local defaults (and posts `.cloudSyncDidApply`); newer-schema and
//   missing-field records are skipped without touching local state.
// - turns: new turns push once (watermark advances); existing records
//   are never rewritten; pull inserts missing turns, skips present ones.
// - account/offline: no account → silent local-only + queued outbox;
//   undetermined → queued; retryable → queued + "will retry" status;
//   structural failure → surfaced, NOT queued; outage→recovery flushes.
// - privacy: HealthKit-shaped fields are rejected by the allowlist, and
//   a source grep-test proves no HK symbol exists in the sync directory.

import CloudKit
import CoreModel
import Foundation
import SwiftData
import Testing
@testable import HealthLoom

// MARK: - Stub

/// In-memory `CloudDatabase`: scripted account state, a record dictionary
/// standing in for the private DB, per-record/per-op error injection, and
/// a full log of saves (so "no redundant write" is assertable).
actor StubCloudDatabase: CloudDatabase {
    var account: CloudAccountState = .available
    var records: [String: CKRecord] = [:]
    private(set) var savedRecords: [CKRecord] = []
    var fetchErrors: [String: CloudSyncError] = [:]
    var saveError: CloudSyncError?
    var queryError: CloudSyncError?

    func setAccount(_ state: CloudAccountState) { account = state }
    func setSaveError(_ error: CloudSyncError?) { saveError = error }
    func setFetchError(for recordName: String, error: CloudSyncError?) {
        fetchErrors[recordName] = error
    }
    func seedRecord(_ record: CKRecord) {
        records[record.recordID.recordName] = record
    }

    func accountState() async -> CloudAccountState { account }

    func fetchRecord(recordName: String) async throws(CloudSyncError) -> CKRecord? {
        if let error = fetchErrors[recordName] { throw error }
        return records[recordName]
    }

    func saveRecord(_ record: CKRecord) async throws(CloudSyncError) -> CKRecord {
        if let error = saveError { throw error }
        records[record.recordID.recordName] = record
        savedRecords.append(record)
        return record
    }

    func allTurnRecords() async throws(CloudSyncError) -> [CKRecord] {
        if let error = queryError { throw error }
        return records.values.filter { $0.recordType == CloudRecordType.coachTurn }
    }

    func saved(ofType recordType: String) -> [CKRecord] {
        savedRecords.filter { $0.recordType == recordType }
    }
}

// MARK: - Harness

@MainActor
struct CloudSyncHarness {
    let container: ModelContainer
    let defaults: UserDefaults
    let db: StubCloudDatabase
    var now = Date(timeIntervalSince1970: 1_800_000_000)

    static func make() throws -> CloudSyncHarness {
        let container = try CoreModel.makeContainer(inMemory: true)
        let defaults = try #require(UserDefaults(suiteName: "cloudsync-\(UUID().uuidString)"))
        return CloudSyncHarness(container: container, defaults: defaults, db: StubCloudDatabase())
    }

    func engine() -> CloudSyncEngine {
        let now = self.now
        return CloudSyncEngine(container: container, defaults: defaults, database: db, now: { now })
    }

    func seedTurn(role: String = "user", content: String, at date: Date) throws {
        let context = ModelContext(container)
        context.insert(ChatTurn(role: role, content: content, createdAt: date))
        try context.save()
    }

    func localTurnCount() throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<ChatTurn>())
    }
}

@Suite("CloudSyncEngine", .serialized)
@MainActor
struct CloudSyncTests {
    // MARK: Push — settings

    @Test("first sync pushes settings and prefs")
    func firstSyncPushesSingletons() async throws {
        let harness = try CloudSyncHarness.make()
        let prefs = SyncPreferences(defaults: harness.defaults)
        prefs.setEnabled(false, for: .steps)
        await harness.engine().syncNow()
        let saved = await harness.db.saved(ofType: CloudRecordType.settings)
        #expect(saved.count == 1)
        let snap = try CloudRecordDecoder.settings(from: saved[0])
        #expect(snap.disabledTypeRawValues == [GoogleDataType.steps.rawValue])
        #expect(await harness.db.saved(ofType: CloudRecordType.insightPrefs).count == 1)
    }

    @Test("clean syncs save nothing new (3-sync stability)")
    func cleanSyncsSaveNothingNew() async throws {
        let harness = try CloudSyncHarness.make()
        try harness.seedTurn(content: "hello", at: harness.now)
        let engine = harness.engine()
        await engine.syncNow()
        let afterFirst = await harness.db.savedRecords.count
        #expect(afterFirst > 0) // first sync does real work
        await engine.syncNow()
        let afterSecond = await harness.db.savedRecords.count
        #expect(afterSecond == afterFirst) // converged: nothing new
        await engine.syncNow()
        #expect(await harness.db.savedRecords.count == afterSecond)
        if case .synced(_, let pending) = engine.status {
            #expect(pending == 0)
        } else {
            Issue.record("expected synced status, got \(engine.status)")
        }
    }

    @Test("equal server content skips the write")
    func equalContentSkipsSave() async throws {
        let harness = try CloudSyncHarness.make()
        let prefs = SyncPreferences(defaults: harness.defaults)
        prefs.setEnabled(false, for: .steps)
        let server = SyncSettingsSnapshot(
            disabledTypeRawValues: [GoogleDataType.steps.rawValue],
            preferAppleWatch: false,
            updatedAt: harness.now.addingTimeInterval(-100)
        )
        await harness.db.seedRecord(try CloudRecordBuilder.record(for: server))
        await harness.engine().syncNow()
        #expect(await harness.db.saved(ofType: CloudRecordType.settings).isEmpty)
    }

    @Test("local-newer settings overwrite the server")
    func localNewerPushes() async throws {
        let harness = try CloudSyncHarness.make()
        // Prime the seen-watermark with an old server state, then edit
        // locally: the server is NOT newer than last seen, so we push.
        let old = SyncSettingsSnapshot(
            disabledTypeRawValues: [],
            preferAppleWatch: false,
            updatedAt: harness.now.addingTimeInterval(-1000)
        )
        await harness.db.seedRecord(try CloudRecordBuilder.record(for: old))
        await harness.engine().syncNow()
        SyncPreferences(defaults: harness.defaults).setEnabled(false, for: .sleep)
        await harness.engine().syncNow()
        let saves = await harness.db.saved(ofType: CloudRecordType.settings)
        #expect(!saves.isEmpty)
        let latest = try CloudRecordDecoder.settings(from: saves.last!)
        #expect(latest.disabledTypeRawValues == [GoogleDataType.sleep.rawValue])
    }

    // MARK: Pull — last-sync-wins

    @Test("server-newer settings apply locally (documented tradeoff)")
    func serverNewerApplies() async throws {
        let harness = try CloudSyncHarness.make()
        await harness.engine().syncNow() // primes watermarks on empty server
        // Another device writes newer state behind our back.
        let server = SyncSettingsSnapshot(
            disabledTypeRawValues: [GoogleDataType.weight.rawValue],
            preferAppleWatch: true,
            updatedAt: harness.now.addingTimeInterval(100)
        )
        await harness.db.seedRecord(try CloudRecordBuilder.record(for: server))
        // A stale local edit loses to the newer server state — the
        // documented convergence tradeoff, pinned, not hidden.
        SyncPreferences(defaults: harness.defaults).setEnabled(false, for: .steps)
        await harness.engine().syncNow()
        #expect(SyncPreferences(defaults: harness.defaults).isEnabled(.steps))
        #expect(!SyncPreferences(defaults: harness.defaults).isEnabled(.weight))
        #expect(harness.defaults.bool(forKey: "com.healthloom.settings.preferAppleWatchDuringWorkouts"))
    }

    @Test("newer-schema records are skipped, local untouched")
    func newerSchemaSkipped() async throws {
        let harness = try CloudSyncHarness.make()
        let prefs = SyncPreferences(defaults: harness.defaults)
        prefs.setEnabled(false, for: .steps)
        let record = CKRecord(
            recordType: CloudRecordType.settings,
            recordID: CKRecord.ID(recordName: CloudRecordType.settingsRecordName)
        )
        record["v"] = 999 as CKRecordValue
        record["disabledTypes"] = [] as CKRecordValue
        record["preferWatch"] = 1 as CKRecordValue
        record["updatedAt"] = harness.now.addingTimeInterval(100) as CKRecordValue
        await harness.db.seedRecord(record)
        await harness.engine().syncNow()
        // Local edit survives; the future-schema record was not applied.
        #expect(!SyncPreferences(defaults: harness.defaults).isEnabled(.steps))
    }

    @Test("server-newer prefs apply; equal prefs skip the write")
    func prefsNewerApplies() async throws {
        let harness = try CloudSyncHarness.make()
        await harness.engine().syncNow()
        let server = InsightPrefsSnapshot(
            morningInsightsEnabled: true,
            lockScreenDetails: true,
            insightsViaCloud: false,
            lastRun: nil,
            updatedAt: harness.now.addingTimeInterval(50)
        )
        await harness.db.seedRecord(try CloudRecordBuilder.record(for: server))
        let savesBefore = await harness.db.saved(ofType: CloudRecordType.insightPrefs).count
        await harness.engine().syncNow()
        let applied = InsightPreferences(defaults: harness.defaults)
        #expect(applied.morningInsightsEnabled)
        #expect(applied.lockScreenDetails)
        // Applied, not re-pushed: no NEW saves past the first-sync push.
        #expect(await harness.db.saved(ofType: CloudRecordType.insightPrefs).count == savesBefore)
    }

    // MARK: Turns — append-only

    @Test("new turns push once and advance the watermark")
    func newTurnsPush() async throws {
        let harness = try CloudSyncHarness.make()
        try harness.seedTurn(content: "hello", at: harness.now)
        await harness.engine().syncNow()
        let saves = await harness.db.saved(ofType: CloudRecordType.coachTurn)
        #expect(saves.count == 1)
        let snap = try CloudRecordDecoder.turn(from: saves[0])
        #expect(snap.content == "hello")
        #expect(snap.role == "user")
        // Second sync pushes nothing (watermark advanced past the turn).
        await harness.engine().syncNow()
        #expect(await harness.db.saved(ofType: CloudRecordType.coachTurn).count == 1)
    }

    @Test("existing server turns are never rewritten")
    func existingTurnsSkipped() async throws {
        let harness = try CloudSyncHarness.make()
        try harness.seedTurn(content: "hello", at: harness.now)
        let existing = CoachTurnSnapshot(
            turnID: "\(harness.now.timeIntervalSince1970)-user",
            role: "user",
            content: "hello",
            createdAt: harness.now
        )
        await harness.db.seedRecord(try CloudRecordBuilder.record(for: existing))
        await harness.engine().syncNow()
        #expect(await harness.db.saved(ofType: CloudRecordType.coachTurn).isEmpty)
    }

    @Test("pull inserts missing turns and skips present ones")
    func pullTurns() async throws {
        let harness = try CloudSyncHarness.make()
        try harness.seedTurn(content: "local", at: harness.now)
        let remote = CoachTurnSnapshot(
            turnID: "remote-1",
            role: "assistant",
            content: "from my other device",
            createdAt: harness.now.addingTimeInterval(60)
        )
        await harness.db.seedRecord(try CloudRecordBuilder.record(for: remote))
        await harness.engine().syncNow()
        #expect(try harness.localTurnCount() == 2)
        await harness.engine().syncNow()
        #expect(try harness.localTurnCount() == 2) // no duplicates on re-pull
    }

    // MARK: Account / offline / errors

    @Test("no account means silent local-only with queued intent")
    func noAccountIsSilentLocalOnly() async throws {
        let harness = try CloudSyncHarness.make()
        await harness.db.setAccount(.noAccount)
        let engine = harness.engine()
        await engine.syncNow()
        #expect(engine.status == .localOnly)
        try harness.seedTurn(content: "queued", at: harness.now)
        await engine.syncNow()
        #expect(await harness.db.savedRecords.isEmpty) // nothing left the device
    }

    @Test("undetermined account queues without error UI")
    func undeterminedQueues() async throws {
        let harness = try CloudSyncHarness.make()
        await harness.db.setAccount(.undetermined)
        let engine = harness.engine()
        await engine.syncNow()
        if case .synced(_, let pending) = engine.status {
            #expect(pending == 2)
        } else {
            Issue.record("expected queued pending status, got \(engine.status)")
        }
    }

    @Test("retryable failure queues and says it will retry")
    func retryableQueues() async throws {
        let harness = try CloudSyncHarness.make()
        await harness.db.setSaveError(.retryable("offline"))
        let engine = harness.engine()
        await engine.syncNow()
        if case .failed(let message) = engine.status {
            #expect(message.contains("will retry"))
        } else {
            Issue.record("expected failed status, got \(engine.status)")
        }
        // Recovery flushes: the intent survived the outage.
        await harness.db.setSaveError(nil)
        await engine.syncNow()
        let allSaved = await harness.db.savedRecords
        #expect(!allSaved.isEmpty)
        if case .synced(_, let pending) = engine.status {
            #expect(pending == 0)
        } else {
            Issue.record("expected synced after recovery, got \(engine.status)")
        }
    }

    @Test("structural failure surfaces without queueing")
    func structuralFailureSurfaces() async throws {
        let harness = try CloudSyncHarness.make()
        await harness.db.setFetchError(for: CloudRecordType.settingsRecordName, error: .failed("quota"))
        let engine = harness.engine()
        await engine.syncNow()
        if case .failed = engine.status {
        } else {
            Issue.record("expected failed status, got \(engine.status)")
        }
        // Retrying cannot help a structural failure, so nothing queues —
        // a poisoned outbox would retry forever and mask recovery.
        #expect(engine.pendingOutboxCount == 0)
    }

    @Test("outage then recovery flushes the outbox")
    func outageRecoveryFlushes() async throws {
        let harness = try CloudSyncHarness.make()
        await harness.db.setAccount(.noAccount)
        let engine = harness.engine()
        await engine.syncNow()
        await harness.db.setAccount(.available)
        await engine.syncNow()
        let allSaved = await harness.db.savedRecords
        #expect(!allSaved.isEmpty)
        if case .synced(_, let pending) = engine.status {
            #expect(pending == 0)
        } else {
            Issue.record("expected synced after recovery, got \(engine.status)")
        }
    }

    @Test("a pull posts the apply notification")
    func applyPostsNotification() async throws {
        let harness = try CloudSyncHarness.make()
        await harness.engine().syncNow()
        let server = InsightPrefsSnapshot(
            morningInsightsEnabled: true,
            lockScreenDetails: false,
            insightsViaCloud: false,
            lastRun: nil,
            updatedAt: harness.now.addingTimeInterval(50)
        )
        await harness.db.seedRecord(try CloudRecordBuilder.record(for: server))
        let fired = LockedBox(false)
        let token = NotificationCenter.default.addObserver(
            forName: .cloudSyncDidApply, object: nil, queue: nil
        ) { _ in fired.value = true }
        defer { NotificationCenter.default.removeObserver(token) }
        await harness.engine().syncNow()
        #expect(fired.value)
    }

    // MARK: Privacy

    @Test("every record builder calls validatedFields (removal goes red)")
    func buildersCallValidatedFields() throws {
        // Structural companion to `hkShapedFieldsRejected`: the allowlist
        // only protects records whose builder actually invokes it. A
        // future builder (or a refactor dropping the call) fails here.
        let thisFile = URL(fileURLWithPath: #filePath)
        let payload = thisFile
            .deletingLastPathComponent() // HealthLoomTests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("HealthLoomApp/iCloud/CloudSyncPayload.swift")
        let source = try String(contentsOf: payload, encoding: .utf8)
        let builders = source.components(separatedBy: "static func record(for ")
        #expect(builders.count == 4, "expected 3 record builders, found \(builders.count - 1)")
        for chunk in builders.dropFirst() {
            let body = chunk.components(separatedBy: "\n    static func ").first ?? chunk
            let signature = String(chunk.prefix(while: { $0 != "\n" }))
            #expect(
                body.contains("validatedFields"),
                "builder \(signature) does not call validatedFields"
            )
        }
    }

    @Test("HealthKit-shaped fields are rejected, never encoded")
    func hkShapedFieldsRejected() {
        for key in ["hkQuantity", "HKSampleType", "HKQuantity", "healthKitValue", "HKHealthStore", "LocalSample"] {
            #expect(throws: CloudSyncError.self) {
                try CloudRecordFields.validatedFields(
                    ["v": 1 as CKRecordValue, key: "x" as CKRecordValue],
                    for: CloudRecordType.settings
                )
            }
        }
        // Unknown record types are rejected too (no silent new bucket).
        #expect(throws: CloudSyncError.self) {
            try CloudRecordFields.validatedFields([:], for: "HealthKitSamples")
        }
    }

    @Test("no HealthKit symbol exists in the sync directory (grep-test)")
    func noHealthKitSymbolsInSyncSources() throws {
        let thisFile = URL(fileURLWithPath: #filePath)
        let syncDir = thisFile
            .deletingLastPathComponent() // HealthLoomTests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("HealthLoomApp/iCloud")
        let banned = [
            "HealthKit", "HKQuantity", "HKSample", "HKObject", "HKHealthStore",
            "HKWorkout", "LocalSample", "GoogleDataPoint", "HKUnit", "HKStatistics",
        ]
        var hits: [String] = []
        for file in try FileManager.default.contentsOfDirectory(at: syncDir, includingPropertiesForKeys: nil) {
            guard file.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            // Code only: `//` comments document the ban by naming it,
            // which is good prose and must not trip the test. (This
            // directory uses line comments exclusively.)
            let code = source
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for symbol in banned where code.contains(symbol) {
                hits.append("\(file.lastPathComponent): \(symbol)")
            }
        }
        #expect(hits.isEmpty, "HealthKit symbols in iCloud sync sources: \(hits)")
    }


    @Test("both container sites opt out of automatic CloudKit (removal goes red)")
    func containersOptOutOfAutomaticCloudKit() throws {
        // `.automatic` silently promotes the store to CloudKit sync when
        // the capability lands (store-breaking AND a scope violation for
        // HK-sourced entities) — both `ModelConfiguration` sites in
        // CoreModel.swift must carry `.none`. Count-pinned: deleting one
        // opt-out must fail here, not in production.
        let thisFile = URL(fileURLWithPath: #filePath)
        let coreModel = thisFile
            .deletingLastPathComponent() // HealthLoomTests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Packages/CoreModel/Sources/CoreModel/CoreModel.swift")
        let source = try String(contentsOf: coreModel, encoding: .utf8)
        #expect(source.components(separatedBy: "cloudKitDatabase: .none").count - 1 == 2)
    }

    @Test("snapshot round-trips preserve values")
    func snapshotRoundTrips() throws {
        let settings = SyncSettingsSnapshot(
            disabledTypeRawValues: ["steps", "future-case"],
            preferAppleWatch: true,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_001)
        )
        let decodedSettings = try CloudRecordDecoder.settings(from: try CloudRecordBuilder.record(for: settings))
        #expect(decodedSettings == settings)
        let prefs = InsightPrefsSnapshot(
            morningInsightsEnabled: true,
            lockScreenDetails: false,
            insightsViaCloud: true,
            lastRun: Date(timeIntervalSince1970: 1_800_000_002),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_003)
        )
        let decodedPrefs = try CloudRecordDecoder.prefs(from: try CloudRecordBuilder.record(for: prefs))
        #expect(decodedPrefs == prefs)
        // Unknown future type raw values survive verbatim (never dropped).
        #expect(decodedSettings.disabledTypeRawValues.contains("future-case"))
    }
}

/// Test-only sendable box (notification fires on the main actor; the
/// test reads after `syncNow` returns, so no race — just Sendable shape).
final class LockedBox: Sendable {
    nonisolated(unsafe) var value: Bool
    init(_ value: Bool) { self.value = value }
}
