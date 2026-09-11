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
    func setTurnPageSize(_ size: Int?) { turnPageSize = size }
    func setTurnLoopCursor(_ cursor: Data?) { turnLoopCursor = cursor }
    /// Hostile fresh cursor (round-9 item 3): every page returns a
    /// DIFFERENT non-nil cursor — models a server that never settles,
    /// so the test proves the wipe walk terminates (cap-throw) instead
    /// of re-walking forever. Takes precedence over `turnLoopCursor`.
    private var hostileFreshCursor = false
    private var hostileCount = 0
    func setHostileFreshCursor(_ enabled: Bool) { hostileFreshCursor = enabled }

    func setAccount(_ state: CloudAccountState) { account = state }
    func setSaveError(_ error: CloudSyncError?) { saveError = error }
    func setFetchError(for recordName: String, error: CloudSyncError?) {
        fetchErrors[recordName] = error
    }
    func seedRecord(_ record: CKRecord) {
        records[record.recordID.recordName] = record
    }

    /// Gate rendezvous for the TOCTOU test (round-4-sync fix round F1):
    /// when `holdAccountState` is set, callers park here instead of
    /// returning — letting the test hold task 1 between `syncNow`'s
    /// guard and its claim while task 2 runs the guard. Call counting
    /// (`accountStateCalls`, `fetchCalls`) distinguishes one full
    /// push/pull from two (save counts cannot — the second push
    /// collapses via content-equality, which is exactly what made the
    /// first version of the test TOCTOU-blind).
    private(set) var accountStateCalls = 0
    private(set) var fetchCalls: [String: Int] = [:]
    var holdAccountState = false
    private var accountStateHolds: [CheckedContinuation<CloudAccountState, Never>] = []

    func accountState() async -> CloudAccountState {
        accountStateCalls += 1
        if holdAccountState {
            return await withCheckedContinuation { accountStateHolds.append($0) }
        }
        return account
    }

    func setHoldAccountState(_ hold: Bool) { holdAccountState = hold }

    func releaseAccountState() {
        holdAccountState = false
        let held = accountStateHolds
        accountStateHolds = []
        for continuation in held { continuation.resume(returning: account) }
    }

    func fetchRecord(recordName: String) async throws(CloudSyncError) -> CKRecord? {
        if let error = fetchErrors[recordName] { throw error }
        fetchCalls[recordName, default: 0] += 1
        return records[recordName]
    }

    func saveRecord(_ record: CKRecord) async throws(CloudSyncError) -> CKRecord {
        if let error = saveError { throw error }
        let name = record.recordID.recordName
        // Round-4-sync item 2: models CloudKit's serverRecordChanged —
        // saving a FRESH build over an existing record fails (the fresh
        // build carries no server change token); saving the FETCHED
        // instance (identity match — the token carrier) succeeds.
        // Identity, not field comparison: this is exactly what
        // distinguishes `update(fetchRecord(), ...)` from
        // `record(for:)` at the call site.
        if let existing = records[name], existing !== record {
            throw CloudSyncError.failed("server record changed: save the fetched record, not a fresh build")
        }
        records[name] = record
        savedRecords.append(record)
        return record
    }

    /// Page size for `turnPage` (round-6 item 4): `nil` (default) = one
    /// page, preserving every pre-existing test's shape; set to N to
    /// model a multi-page server.
    var turnPageSize: Int?
    /// Echoing cursor (round-7 item 5): when set, every page returns
    /// this same cursor forever — models a looping server so the test
    /// proves the walk terminates instead of spinning to OOM.
    var turnLoopCursor: Data?
    /// Walk snapshot (round-8 item 5): a nil cursor starts a new walk
    /// and snapshots the name list — server cursors are stable under
    /// mid-walk deletes, but naive index-into-live-dict pagination
    /// overshoots as rows vanish (the wipe deletes while walking).
    /// Snapshot-then-compactMap mirrors that stability.
    private var turnPageSnapshot: [String] = []
    private(set) var deletedRecordNames: [String] = []

    func turnPage(cursor: Data?) async throws(CloudSyncError) -> CloudTurnPage {
        if let error = queryError { throw error }
        // Opaque cursor, integer-indexed (see the protocol: Live
        // archives the real CKQueryCursor; both are just "next page
        // please" tokens to the engine's loop). Snapshot on walk
        // start; rows deleted mid-walk resolve to nil and drop out.
        if cursor == nil {
            turnPageSnapshot = records.values
                .filter { $0.recordType == CloudRecordType.coachTurn }
                .map(\.recordID.recordName)
                .sorted()
        }
        let names = turnPageSnapshot
        let pageSize = turnPageSize ?? names.count
        let index: Int
        if let cursor, let text = String(data: cursor, encoding: .utf8), let parsed = Int(text) {
            index = parsed
        } else {
            index = 0
        }
        let sliceNames = Array(names.dropFirst(index).prefix(pageSize))
        let slice = sliceNames.compactMap { records[$0] }
        if hostileFreshCursor {
            hostileCount += 1
            return CloudTurnPage(records: slice, nextCursor: "hostile-\(hostileCount)".data(using: .utf8))
        }
        if let loop = turnLoopCursor {
            return CloudTurnPage(records: slice, nextCursor: loop)
        }
        let next = index + sliceNames.count < names.count ? String(index + sliceNames.count).data(using: .utf8) : nil
        return CloudTurnPage(records: slice, nextCursor: next)
    }

    func deleteRecord(recordName: String) async throws(CloudSyncError) -> Void {
        records.removeValue(forKey: recordName)
        deletedRecordNames.append(recordName)
    }

    func saved(ofType recordType: String) -> [CKRecord] {
        savedRecords.filter { $0.recordType == recordType }
    }
}

// MARK: - Harness

@MainActor
struct CloudSyncHarness {
    let container: ModelContainer
    let db: StubCloudDatabase
    var now = Date(timeIntervalSince1970: 1_800_000_000)

    // The ephemeral holder rides in the harness (struct field keeps it
    // alive for the test's duration; deinit removes the domain after).
    // Round-4 item 4 audit, stated exactly: EVERY test below reads
    // defaults through `harness.` at-or-after its last use of the
    // holder (verified mechanically — no test projects a bare
    // `defaults` local past its last `harness.` touch), and `let
    // harness` lives through its last textual use, so the domain
    // cannot drop before the final assertion. The rule for future
    // edits: never read defaults past the last `harness.` touch —
    // that shape (not today's code) is what would go vacuous, and
    // `pullAssertionsAreWipeSensitive` proves the assertions would
    // catch it.
    let ephemeral: EphemeralDefaults
    var defaults: UserDefaults { ephemeral.defaults }

    static func make() throws -> CloudSyncHarness {
        let container = try CoreModel.makeContainer(inMemory: true)
        let ephemeral = try EphemeralDefaults(prefix: "cloudsync")
        return CloudSyncHarness(container: container, db: StubCloudDatabase(), ephemeral: ephemeral)
    }

    /// Fresh local store against a SHARED server (round-6 items 1+4):
    /// simulates a wiped device (or a second device) pulling the same
    /// private DB — local rows gone, server rows intact.
    static func makeFreshContainerHarness(db: StubCloudDatabase, now: Date) throws -> CloudSyncHarness {
        let container = try CoreModel.makeContainer(inMemory: true)
        let ephemeral = try EphemeralDefaults(prefix: "cloudsync")
        return CloudSyncHarness(container: container, db: db, now: now, ephemeral: ephemeral)
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

    // MARK: Lifetime + scan-infra proofs (round-4 items 1, 4, 12)

    @Test("holder death removes the domain (post-clean is real)")
    func holderDeathRemovesDomain() async throws {
        // Round-4 item 4: pins the POST-CLEAN behavior the whole
        // ephemeral scheme relies on — and the teeth behind the
        // non-vacuity proof below. (Proven by probe before committing:
        // the wipe shows through retained AND fresh instances alike,
        // so no stale cache can hide an early death.)
        let name: String
        do {
            let holder = try EphemeralDefaults(prefix: "lifetimes")
            name = holder.suiteName
            holder.defaults.set(true, forKey: "lifetimes.key")
            #expect(holder.defaults.bool(forKey: "lifetimes.key") == true)
        }
        #expect(UserDefaults(suiteName: name)?.bool(forKey: "lifetimes.key") == false)
    }

    @Test("named pull assertions are wipe-sensitive (non-vacuous)")
    func pullAssertionsAreWipeSensitive() async throws {
        // Round-4 item 4: the UNDERLYING reads behind
        // `serverNewerApplies`' / `newerSchemaSkipped`'s final
        // assertions, measured against a SIMULATED early-deinit wipe
        // (fresh-instance `removePersistentDomain` — exactly what
        // `EphemeralDefaults.deinit` does). Post-wipe they read
        // steps=true, weight=true, preferWatch=false: weight and
        // preferWatch CONTRADICT the real tests' expectations (both
        // would go red), while steps coincides (wipe-insensitive
        // alone — covered by the conjunction: all three must hold,
        // and a wipe breaks two). So the named tests test something:
        // a vacuous pass is impossible, not merely absent.
        let harness = try CloudSyncHarness.make()
        SyncPreferences(defaults: harness.defaults).setEnabled(false, for: .steps)
        SyncPreferences(defaults: harness.defaults).setEnabled(false, for: .weight)
        harness.defaults.set(true, forKey: "com.healthloom.settings.preferAppleWatchDuringWorkouts")
        // The feared shape, simulated: holder dies here.
        UserDefaults(suiteName: harness.ephemeral.suiteName)?
            .removePersistentDomain(forName: harness.ephemeral.suiteName)
        #expect(SyncPreferences(defaults: harness.defaults).isEnabled(.steps) == true)
        #expect(SyncPreferences(defaults: harness.defaults).isEnabled(.weight) == true)
        #expect(harness.defaults.bool(forKey: "com.healthloom.settings.preferAppleWatchDuringWorkouts") == false)
    }

    @Test("concurrent syncNow calls run exactly one full push/pull")
    func concurrentSyncNowRunsOnce() async throws {
        // Round-4-sync item 3 + fix-round F1: the test constructs the
        // ACTUAL guard→await→set interleaving — task 1 parks inside
        // the account gate (past the guard, before any claim) while
        // task 2 runs the guard — instead of keying on the new shape's
        // early `.syncing` claim (which the old shape never makes,
        // stranding task 2 until after the claim: serial, green,
        // blind). Call counts, not save counts: a duplicate push
        // collapses via content-equality (one save either way), but
        // the duplicate FETCH is observable. Against the old shape
        // (guard, await, claim) both tasks park in the gate and both
        // fetch → red; against the fix, task 2 turns away at the
        // guard → one fetch → green.
        let harness = try CloudSyncHarness.make()
        let engine = harness.engine()
        await harness.db.setHoldAccountState(true)
        let first = Task { await engine.syncNow() }
        let start = Date.now
        while await harness.db.accountStateCalls != 1 {
            await Task.yield()
            if Date.now.timeIntervalSince(start) > 5 {
                Issue.record("first sync never reached the account gate")
                break
            }
        }
        let second = Task { await engine.syncNow() }
        // Give task 2 every chance to reach the gate too (old shape)
        // or turn away (new shape): settle, then release.
        try await Task.sleep(for: .milliseconds(200))
        let parked = await harness.db.accountStateCalls
        await harness.db.releaseAccountState()
        await first.value
        await second.value
        #expect(parked == 1)
        // One full sync fetches the settings record TWICE (push
        // decision + pull read-back); a duplicate run would fetch
        // four times. (Against the old shape this reads 4 — verified
        // by temporary revert during development.)
        #expect(await harness.db.fetchCalls[CloudRecordType.settingsRecordName] == 2)
        #expect(await harness.db.saved(ofType: CloudRecordType.settings).count == 1)
        if case .synced(_, let pending) = engine.status {
            #expect(pending == 0)
        } else {
            Issue.record("expected synced status, got \(engine.status)")
        }
    }

    @Test("push decisions own their watermarks per singleton")
    func singletonPushDecisions() throws {
        // Round-4-sync item 12: the pure decisions for BOTH record
        // names — absent/malformed push, newer suppresses, equal
        // suppresses, differing pushes — plus the cross-talk
        // regression: a newer PREFS record must not suppress a
        // SETTINGS push (the old shared predicate hardcoded the
        // settings watermark while parameterized on the name).
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let seen = now.addingTimeInterval(-1000)
        // Absent server pushes, watermark untouched.
        var decision = CloudSyncEngine.settingsPushDecision(server: nil, snapshot: SyncSettingsSnapshot(disabledTypeRawValues: [], preferAppleWatch: false, updatedAt: now), previouslySeen: seen)
        #expect(decision == CloudSyncEngine.SingletonPushDecision(push: true, newSeen: seen))
        // Malformed server pushes (overwritten, never preserved).
        let malformed = CKRecord(recordType: CloudRecordType.settings, recordID: CKRecord.ID(recordName: CloudRecordType.settingsRecordName))
        decision = CloudSyncEngine.settingsPushDecision(server: malformed, snapshot: SyncSettingsSnapshot(disabledTypeRawValues: [], preferAppleWatch: false, updatedAt: now), previouslySeen: seen)
        #expect(decision.push == true)
        // Newer server suppresses and advances the watermark.
        let newerServer = try CloudRecordBuilder.record(for: SyncSettingsSnapshot(disabledTypeRawValues: [], preferAppleWatch: false, updatedAt: now))
        decision = CloudSyncEngine.settingsPushDecision(server: newerServer, snapshot: SyncSettingsSnapshot(disabledTypeRawValues: [], preferAppleWatch: false, updatedAt: now), previouslySeen: seen)
        #expect(decision == CloudSyncEngine.SingletonPushDecision(push: false, newSeen: now))
        // Equal content suppresses.
        decision = CloudSyncEngine.settingsPushDecision(server: newerServer, snapshot: SyncSettingsSnapshot(disabledTypeRawValues: [], preferAppleWatch: false, updatedAt: now), previouslySeen: now)
        #expect(decision.push == false)
        // Differing content pushes.
        decision = CloudSyncEngine.settingsPushDecision(server: newerServer, snapshot: SyncSettingsSnapshot(disabledTypeRawValues: [GoogleDataType.steps.rawValue], preferAppleWatch: false, updatedAt: now), previouslySeen: now)
        #expect(decision.push == true)
        // Prefs mirror: newer suppresses…
        let newerPrefs = try CloudRecordBuilder.record(for: InsightPrefsSnapshot(morningInsightsEnabled: true, lockScreenDetails: false, insightsViaCloud: false, lastRun: nil, updatedAt: now))
        var prefsDecision = CloudSyncEngine.prefsPushDecision(server: newerPrefs, snapshot: InsightPrefsSnapshot(morningInsightsEnabled: true, lockScreenDetails: false, insightsViaCloud: false, lastRun: nil, updatedAt: now), previouslySeen: seen)
        #expect(prefsDecision == CloudSyncEngine.SingletonPushDecision(push: false, newSeen: now))
        // …differing prefs push…
        prefsDecision = CloudSyncEngine.prefsPushDecision(server: newerPrefs, snapshot: InsightPrefsSnapshot(morningInsightsEnabled: false, lockScreenDetails: false, insightsViaCloud: false, lastRun: nil, updatedAt: now), previouslySeen: now)
        #expect(prefsDecision.push == true)
        // …and the cross-talk regression: that newer prefs record does
        // NOT suppress a differing settings push.
        decision = CloudSyncEngine.settingsPushDecision(server: newerServer, snapshot: SyncSettingsSnapshot(disabledTypeRawValues: [GoogleDataType.weight.rawValue], preferAppleWatch: true, updatedAt: now), previouslySeen: now)
        #expect(decision.push == true)
    }

    @Test("second push after a server record exists succeeds via mutate")
    func secondPushMutatesFetchedRecord() async throws {
        // Round-4-sync item 2: the full-stack proof — a local edit over
        // an EXISTING server record saves the fetched instance (identity
        // match in the stub = server change token), not a fresh build.
        // Pre-fix this threw serverRecordChanged → non-retryable → the
        // push never succeeded again.
        let harness = try CloudSyncHarness.make()
        let old = SyncSettingsSnapshot(
            disabledTypeRawValues: [],
            preferAppleWatch: false,
            updatedAt: harness.now.addingTimeInterval(-1000)
        )
        await harness.db.seedRecord(try CloudRecordBuilder.record(for: old))
        await harness.engine().syncNow() // primes the seen-watermark on the old server state
        SyncPreferences(defaults: harness.defaults).setEnabled(false, for: .steps)
        // Fresh engine per sync (the established pattern — each engine
        // loads its `SyncPreferences` mirror at init).
        let engine = harness.engine()
        await engine.syncNow()
        let saved = await harness.db.saved(ofType: CloudRecordType.settings)
        #expect(saved.count == 1)
        let snap = try CloudRecordDecoder.settings(from: saved[0])
        #expect(snap.disabledTypeRawValues == [GoogleDataType.steps.rawValue])
        if case .synced = engine.status {
        } else {
            Issue.record("expected synced status, got \(engine.status)")
        }
    }

    @Test("more than 500 turns push oldest-first with no pull duplicates")
    func overLimitTurnsPushOldestFirst() async throws {
        // Round-7 item 4 supersedes round-4-sync item 1's newest-first
        // window: 600 local turns — the first sync pushes the OLDEST
        // 500 (watermark covers a contiguous prefix), the second sync
        // pushes the rest and inserts ZERO duplicates.
        let harness = try CloudSyncHarness.make()
        let base = harness.now.addingTimeInterval(-10_000)
        let context = ModelContext(harness.container)
        for i in 0..<600 {
            context.insert(ChatTurn(role: "user", content: "turn \(i)", createdAt: base.addingTimeInterval(Double(i))))
        }
        try context.save()
        #expect(try harness.localTurnCount() == 600)
        await harness.engine().syncNow()
        let saved = await harness.db.saved(ofType: CloudRecordType.coachTurn)
        #expect(saved.count == 500)
        let pushedDates = try saved.map { try CloudRecordDecoder.turn(from: $0).createdAt }.sorted()
        #expect(pushedDates.first == base)
        #expect(pushedDates.last == base.addingTimeInterval(499))
        await harness.engine().syncNow()
        #expect(try harness.localTurnCount() == 600)
        #expect(await harness.db.saved(ofType: CloudRecordType.coachTurn).count == 600)
    }

    @Test("multi-page server turns are all pulled")
    func pagedServerTurnsAllPulled() async throws {
        // Round-6 item 4 + fix-round N1 (history stated exactly):
        // pre-fix there was NO paging at all — one single-shot fetch
        // whose cursor was discarded, so past CloudKit's page limit
        // only an arbitrary first fragment arrived. The stub models a
        // 2-per-page server; the engine must walk all 3 pages for the
        // 5 turns (a single fetch could return at most 2).
        let harness = try CloudSyncHarness.make()
        await harness.db.setTurnPageSize(2)
        let base = harness.now.addingTimeInterval(-5000)
        for i in 0..<5 {
            try harness.seedTurn(content: "server \(i)", at: base.addingTimeInterval(Double(i) * 60))
        }
        // Push them server-side first (clean slate locally after).
        await harness.engine().syncNow()
        #expect(await harness.db.saved(ofType: CloudRecordType.coachTurn).count == 5)
        // Fresh local store, same server: pull must recover all 5.
        let fresh = try CloudSyncHarness.makeFreshContainerHarness(db: harness.db, now: harness.now)
        await fresh.engine().syncNow()
        #expect(try fresh.localTurnCount() == 5)
    }

    @Test("second sync inserts zero duplicates past the push window")
    func pullDedupesAgainstFullLocalSet() async throws {
        // Round-6 item 5: 600 turns, sync (pushes newest 500), 600 more
        // arrive, sync again — the pull dedupe must cover ALL local
        // rows, not the newest 500, or the 500 older server turns
        // re-insert every run (600 → 1700 here, pre-fix).
        let harness = try CloudSyncHarness.make()
        let base = harness.now.addingTimeInterval(-100_000)
        let context = ModelContext(harness.container)
        for i in 0..<600 {
            context.insert(ChatTurn(role: "user", content: "first \(i)", createdAt: base.addingTimeInterval(Double(i))))
        }
        try context.save()
        await harness.engine().syncNow()
        let context2 = ModelContext(harness.container)
        for i in 0..<600 {
            context2.insert(ChatTurn(role: "user", content: "second \(i)", createdAt: base.addingTimeInterval(60_000 + Double(i))))
        }
        try context2.save()
        #expect(try harness.localTurnCount() == 1200)
        await harness.engine().syncNow()
        #expect(try harness.localTurnCount() == 1200)
    }

    @Test("toggle after launch is visible to the next push")
    func toggleThenSyncNowPushes() async throws {
        // Round-6 item 6: the engine's owner mirrors are built at init
        // but Settings writes through its own instances — the engine
        // must re-read live before pushing. Seed a server record
        // matching the stale (empty) state, toggle through a SEPARATE
        // instance (the Settings shape), sync with the SAME engine:
        // pre-fix the push never fires (stale mirror reads equal).
        let harness = try CloudSyncHarness.make()
        let old = SyncSettingsSnapshot(
            disabledTypeRawValues: [],
            preferAppleWatch: false,
            updatedAt: harness.now.addingTimeInterval(-1000)
        )
        await harness.db.seedRecord(try CloudRecordBuilder.record(for: old))
        let engine = harness.engine()
        await engine.syncNow() // primes watermarks; engine mirror still empty-disabled
        SyncPreferences(defaults: harness.defaults).setEnabled(false, for: .steps)
        await engine.syncNow()
        let saved = await harness.db.saved(ofType: CloudRecordType.settings)
        #expect(saved.count == 1)
        let snap = try CloudRecordDecoder.settings(from: saved[0])
        #expect(snap.disabledTypeRawValues == [GoogleDataType.steps.rawValue])
    }

    @Test("wipe deletes server records; post-wipe sync pulls nothing back")
    func wipeDeletesCloudData() async throws {
        // Round-6 item 1: the alert promises "cannot be undone" —
        // server records go, then watermarks, so the next sync finds
        // nothing to repull (pre-fix the wiped transcript came back).
        let harness = try CloudSyncHarness.make()
        try harness.seedTurn(content: "doomed", at: harness.now)
        await harness.engine().syncNow()
        #expect(await harness.db.saved(ofType: CloudRecordType.coachTurn).count == 1)
        let engine = harness.engine()
        let deleted = try await engine.deleteAllCloudData()
        #expect(deleted == 3) // settings + prefs + 1 turn
        #expect(await harness.db.records.isEmpty)
        // Post-wipe sync: nothing pulled back, local stays as wiped.
        await engine.syncNow()
        #expect(try harness.localTurnCount() == 1) // the local row itself is the store step's job
        // The surviving local row re-pushes (correct — the store step,
        // not the engine, deletes local rows); nothing is repulled.
        #expect(await harness.db.saved(ofType: CloudRecordType.coachTurn).count == 2)
    }

    @Test("900-turn offline accumulation uploads all, oldest first")
    func offlineAccumulationUploadsAll() async throws {
        // Round-7 item 4: 900 local turns, watermark nil — the old
        // newest-500 window pushed turns 400-899 and jumped the
        // watermark past 0-399 forever (silent loss under `.synced`).
        // Oldest-first pages upload everything: 500, then 400.
        let harness = try CloudSyncHarness.make()
        let base = harness.now.addingTimeInterval(-100_000)
        let context = ModelContext(harness.container)
        for i in 0..<900 {
            context.insert(ChatTurn(role: "user", content: "offline \(i)", createdAt: base.addingTimeInterval(Double(i))))
        }
        try context.save()
        await harness.engine().syncNow()
        var saved = await harness.db.saved(ofType: CloudRecordType.coachTurn)
        #expect(saved.count == 500)
        let firstDates = try saved.map { try CloudRecordDecoder.turn(from: $0).createdAt }.sorted()
        #expect(firstDates.first == base)
        #expect(firstDates.last == base.addingTimeInterval(499))
        await harness.engine().syncNow()
        saved = await harness.db.saved(ofType: CloudRecordType.coachTurn)
        #expect(saved.count == 900)
    }

    @Test("looping turn cursor terminates instead of spinning")
    func loopingCursorTerminates() async throws {
        // Round-7 item 5: an echoing cursor must hit the same-token
        // break (mirroring PagePipeline) — reachable from every scene
        // activation and mid-wipe, where a spin hangs with no timeout.
        let harness = try CloudSyncHarness.make()
        try harness.seedTurn(content: "looped", at: harness.now)
        await harness.db.setTurnLoopCursor(Data("loop".utf8))
        let engine = harness.engine()
        await engine.syncNow() // must return, not spin
        #expect(try harness.localTurnCount() == 1)
        if case .synced = engine.status {
        } else {
            Issue.record("expected synced status, got \(engine.status)")
        }
    }

    @Test("same-key pair in one pull inserts once")
    func sameKeyPairInsertsOnce() async throws {
        // Round-7 item 10: two server records sharing a dedupe key
        // (cross-device content collision — turnRecordName omits
        // content) must insert once. Pre-fix the pre-loop snapshot let
        // both through.
        let harness = try CloudSyncHarness.make()
        let at = harness.now.addingTimeInterval(-100)
        for turnID in ["aaa", "bbb"] {
            await harness.db.seedRecord(try CloudRecordBuilder.record(for: CoachTurnSnapshot(
                turnID: turnID,
                role: "user",
                content: "same words",
                createdAt: at
            )))
        }
        await harness.engine().syncNow()
        #expect(try harness.localTurnCount() == 1)
    }

    @Test("multi-page wipe deletes everything and reports honestly")
    func overCapWipeDeletesAll() async throws {
        // Round-8 item 5: 250 server turns over many pages must ALL
        // delete incrementally; the old walk truncated and reset
        // watermarks, letting survivors repull under a success
        // ledger. Round-9 item 3 reconciliation: 5/page (50 pages —
        // multi-page proof that stays under the 100-page bound);
        // past-100 hostile termination is pinned by the hostile test.
        let harness = try CloudSyncHarness.make()
        await harness.db.setTurnPageSize(5)
        let base = harness.now.addingTimeInterval(-100_000)
        for i in 0..<250 {
            let snap = CoachTurnSnapshot(
                turnID: "wipe-\(i)",
                role: "user",
                content: "wipe me \(i)",
                createdAt: base.addingTimeInterval(Double(i))
            )
            await harness.db.seedRecord(try CloudRecordBuilder.record(for: snap))
        }
        let engine = harness.engine()
        let deleted = try await engine.deleteAllCloudData()
        #expect(deleted == 252) // 250 turns + 2 singletons
        #expect(await harness.db.records.isEmpty)
        await engine.syncNow()
        #expect(try harness.localTurnCount() == 0)
    }

    /// Prime + mutate + sync, returning the second push's record
    /// (round-9 items 8+12): the settings and prefs seen-advance tests
    /// were line-for-line copies — one helper, one `saved[1]`, fixed
    /// once (no force-index after a non-fatal count check — the
    /// §5.1 #10 crash-the-suite smell).
    private func secondPush(
        recordType: String,
        mutate: (CloudSyncHarness) -> Void,
        assertSecond: (CKRecord) throws -> Void
    ) async throws {
        let harness = try CloudSyncHarness.make()
        await harness.engine().syncNow() // pushes initial state (empty server)
        #expect(await harness.db.saved(ofType: recordType).count == 1)
        mutate(harness)
        await harness.engine().syncNow()
        let saved = await harness.db.saved(ofType: recordType)
        guard saved.count == 2 else {
            Issue.record("expected a second push for \(recordType), got \(saved.count) saves")
            return
        }
        try assertSecond(saved[1])
    }

    @Test("push advances seen past its own write")
    func pushAdvancesSeenWatermark() async throws {
        // Round-8 item 6: without the advance, the next sync misreads
        // our own just-pushed record as foreign-newer (server date vs
        // epoch seen) and suppresses the user's intervening change one
        // sync late. Prime, toggle, sync: the toggle must push NOW.
        try await secondPush(recordType: CloudRecordType.settings, mutate: {
            SyncPreferences(defaults: $0.defaults).setEnabled(false, for: .steps)
        }, assertSecond: {
            let snap = try CloudRecordDecoder.settings(from: $0)
            #expect(snap.disabledTypeRawValues == [GoogleDataType.steps.rawValue])
        })
    }

    @Test("equal-createdAt pair straddling the batch cut both push")
    func equalCreatedAtPairBothPush() async throws {
        // Round-8 item 7: two turns sharing one timestamp at positions
        // 500/501 — strict `>` vs `max(batch)` excluded the second one
        // FOREVER (same-second pairs are routine: user+assistant). The
        // batch extends through the edge date: both push, no dupes.
        // Round-9 item 5: this test ALSO pins the single-context +
        // key dedupe — a naive single-context hoist WITHOUT key
        // dedupe (identity only) drops the in-page mate here and
        // strands it forever (watermark lands on its date while it
        // stays unpushed: 500 saved, never 501 — the livelock class).
        // A larger same-date flood is unconstructible by design: the
        // synthetic turnID is `time-role` (third-party N1), so same-
        // stamp same-role turns collapse server-side by save-if-absent
        // (500 seeded → 1 saved, proven) — the pair is the maximal
        // realistic edge group, and this straddle is its hardest shape.
        let harness = try CloudSyncHarness.make()
        let base = harness.now.addingTimeInterval(-100_000)
        let context = ModelContext(harness.container)
        for i in 0..<499 {
            context.insert(ChatTurn(role: "user", content: "filler \(i)", createdAt: base.addingTimeInterval(Double(i))))
        }
        let edge = base.addingTimeInterval(10_000)
        context.insert(ChatTurn(role: "user", content: "edge-a", createdAt: edge))
        context.insert(ChatTurn(role: "assistant", content: "edge-b", createdAt: edge))
        try context.save()
        #expect(try harness.localTurnCount() == 501)
        await harness.engine().syncNow()
        // The batch extends through the edge date: 499 fillers + BOTH
        // pair members in ONE sync (pre-fix: 500, with the second
        // member excluded forever after).
        #expect(await harness.db.saved(ofType: CloudRecordType.coachTurn).count == 501)
        await harness.engine().syncNow()
        #expect(await harness.db.saved(ofType: CloudRecordType.coachTurn).count == 501)
        #expect(try harness.localTurnCount() == 501)
    }

    @Test("wipe while a sync runs fails loud, deletes nothing")
    func wipeVsSyncMutualExclusion() async throws {
        // Round-8 item 8: a wipe racing an in-flight syncNow must take
        // the SAME exclusion claim (throw here) instead of deleting
        // around the uploader and reporting cleared while iCloud
        // repopulates. Park the sync in the account gate, then wipe.
        // (Reverse leg — sync arriving mid-wipe sees `.syncing` and
        // returns — rides the same claim, pinned by the concurrent-
        // sync test.)
        let harness = try CloudSyncHarness.make()
        try harness.seedTurn(content: "keep me", at: harness.now)
        let engine = harness.engine()
        await harness.db.setHoldAccountState(true)
        let syncing = Task { await engine.syncNow() }
        let start = Date.now
        while await harness.db.accountStateCalls != 1 {
            await Task.yield()
            if Date.now.timeIntervalSince(start) > 5 {
                Issue.record("sync never reached the account gate")
                break
            }
        }
        await #expect(throws: CloudSyncError.wipeBlockedBySync) {
            try await engine.deleteAllCloudData()
        }
        await harness.db.releaseAccountState()
        await syncing.value
        #expect(await harness.db.saved(ofType: CloudRecordType.coachTurn).count == 1)
        if case .synced = engine.status {
        } else {
            Issue.record("expected synced status, got \(engine.status)")
        }
    }

    @Test("corrupt turn cursor fails loud, never restarts the walk")
    func corruptCursorThrows() {
        // Round-8 item 4: garbage bytes must THROW (fail loud), not
        // fall through to a fresh page-1 query (which re-fetched page
        // 1 up to 100× while later pages — and, under wipe, turns past
        // 200 — never resolved).
        #expect(throws: CloudSyncError.self) {
            try CloudTurnCursorCodec.decode(Data("not-a-cursor".utf8))
        }
        #expect(throws: CloudSyncError.self) {
            try CloudTurnCursorCodec.decode(Data())
        }
    }

    @Test("prefs push advances seen past its own write")
    func prefsPushAdvancesSeenWatermark() async throws {
        // Round-8 fix N2: the prefs mirror of pushAdvancesSeenWatermark
        // — without the advance, the next sync misreads our own write
        // as foreign-newer and suppresses the change one sync late.
        // Shares `secondPush` (round-9 item 12) — no second copy of
        // the prime/mutate/sync/index shape.
        try await secondPush(recordType: CloudRecordType.insightPrefs, mutate: {
            InsightPreferences(defaults: $0.defaults).insightsViaCloud = true
        }, assertSecond: {
            let snap = try CloudRecordDecoder.prefs(from: $0)
            #expect(snap.insightsViaCloud == true)
        })
    }

    @Test("hostile fresh cursor terminates the wipe loudly")
    func hostileCursorTerminatesWipe() async throws {
        // Round-9 item 3: a server returning a fresh-but-unequal cursor
        // per page (records already deleted → empty pages, zero
        // progress) spins the old uncapped walk FOREVER — this test
        // hangs pre-fix (no exit exists), so red is by inspection:
        // the uncapped `while true` breaks only on nil-or-equal, and
        // the hostile stub yields neither. Post-fix the cap throws
        // loudly with watermarks intact (no silent truncation, retry
        // resumes) — pinned here by the exact error.
        let harness = try CloudSyncHarness.make()
        try harness.seedTurn(content: "hostile one", at: harness.now)
        try harness.seedTurn(content: "hostile two", at: harness.now)
        await harness.engine().syncNow() // push both server-side first
        await harness.db.setHostileFreshCursor(true)
        await #expect(
            throws: CloudSyncError.failed("turn delete cursor never settled")
        ) {
            _ = try await harness.engine().deleteAllCloudData()
        }
    }

    @Test("missing scan root fails loudly, not green")
    func missingScanRootThrows() throws {
        // Round-4 item 1: a renamed root must FAIL, never pass over
        // zero files. (The enumerator-alone returns non-nil-empty for
        // a missing dir — the existence pre-check restores fail-loud.)
        #expect(throws: SourceScanError.missingDirectory("HealthLoomApp/NoSuchDir-round4")) {
            try scanSources(in: "HealthLoomApp/NoSuchDir-round4")
        }
    }

    @Test("scan reports paths relative to the root")
    func scanReportsRelativePaths() throws {
        // Round-4 item 12: the nested fixture must report as
        // `Nested/Probe.swift` — relative, so subdir hits stay
        // distinguishable — never the bare `Probe.swift`.
        let files = try scanSources(in: "HealthLoomTests/__ScanFixture__").map(\.file)
        #expect(files == [ScanFixtureProbe.relativePath])
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
        try assertNoHealthKitSymbols(in: "HealthLoomApp/iCloud")
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

