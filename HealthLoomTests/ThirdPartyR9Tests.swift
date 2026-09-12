// ThirdPartyR9Tests.swift
//
// Third-party findings round 9: one regression test per testable finding.
// Each test names the production bug it catches; findings verified by
// inspection plus a green suite (fetch-failure arms that in-memory SwiftData
// cannot throw) say so explicitly instead of faking coverage.

import CloudKit
import CoreModel
import Foundation
import SwiftData
import SyncKit
import Testing
@testable import HealthLoom

// MARK: - F1: wipe quiesce awaits the backfill stop

@Suite("ThirdPartyR9 wipe quiesce")
struct ThirdPartyR9WipeQuiesceTests {
    @Test("run awaits quiesce before revoke")
    func runAwaitsQuiesceBeforeRevoke() async {
        // Catches: the old fire-and-forget `Task { await stop() }` let `run()` proceed
        // through revoke → keychain → HealthKit delete while the backfill chunk was
        // still draining and rewriting samples mid-wipe. Here quiesce suspends until
        // released; revoke must observe quiesce DONE (under fire-and-forget it would
        // run first — and the old `() -> Void` type would not even compile this double).
        let gate = AsyncGate()
        var revokeSawQuiesceDone = false
        var quiesceDone = false
        let coordinator = WipeCoordinator(
            deps: WipeCoordinator.Dependencies(
                quiesceWriters: {
                    await gate.enter()
                    quiesceDone = true
                },
                revokeGoogle: {
                    revokeSawQuiesceDone = quiesceDone
                    return .revoked
                },
                deleteAllKeys: {},
                deleteHealthKit: { [:] },
                deleteCloudKit: { 0 },
                deleteStore: { [] },
                resetDefaults: {}
            ),
            includeHealthKit: true
        )
        let task = Task { await coordinator.run() }
        await gate.waitUntilEntered()
        await gate.open()
        await task.value
        #expect(quiesceDone)
        #expect(revokeSawQuiesceDone)
        #expect(coordinator.failedSteps.isEmpty)
    }
}

/// Minimal rendezvous: `enter()` parks until `open()`; `waitUntilEntered()` fires
/// once `enter()` has been reached.
actor AsyncGate {
    private var entered = false
    private var opened = false
    private var enterWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        entered = true
        for c in enterWaiters { c.resume() }
        enterWaiters = []
        if opened { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            openWaiters.append(c)
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            enterWaiters.append(c)
        }
    }

    func open() {
        opened = true
        for c in openWaiters { c.resume() }
        openWaiters = []
    }
}

// MARK: - F6: unknown disabled-type values round-trip verbatim

@Suite("ThirdPartyR9 disabled-type forward safety")
struct ThirdPartyR9DisabledTypesTests {
    private func makeDefaults() throws -> EphemeralDefaults {
        try EphemeralDefaults(prefix: "thirdpartyr9-disabled")
    }

    @Test("replace preserves unknown raw values and snapshots them back")
    func unknownValuesPreserved() throws {
        // Catches: device A (newer) disables a type this build never heard of; the old
        // `compactMap` dropped it on pull and the next push wrote the narrowed set
        // back — silently re-enabling sync for a privacy-relevant opt-out.
        let ephemeral = try makeDefaults()
        let prefs = SyncPreferences(defaults: ephemeral.defaults)
        prefs.replaceDisabledTypes(with: ["steps", "bodyTemperatureV2"])
        #expect(prefs.disabledTypes == [.steps])
        #expect(prefs.unknownDisabledRawValues == ["bodyTemperatureV2"])
        #expect(prefs.snapshotRawValues() == ["bodyTemperatureV2", "steps"])
        // Reload (fresh instance, same defaults) preserves both halves.
        let reloaded = SyncPreferences(defaults: ephemeral.defaults)
        #expect(reloaded.disabledTypes == [.steps])
        #expect(reloaded.unknownDisabledRawValues == ["bodyTemperatureV2"])
        #expect(reloaded.snapshotRawValues() == ["bodyTemperatureV2", "steps"])
    }

    @Test("known-only snapshots are unchanged")
    func knownOnlyUnchanged() throws {
        // Pin: no unknown values → exactly the old shape (no behavior drift).
        let ephemeral = try makeDefaults()
        let prefs = SyncPreferences(defaults: ephemeral.defaults)
        prefs.replaceDisabledTypes(with: ["steps"])
        #expect(prefs.unknownDisabledRawValues.isEmpty)
        #expect(prefs.snapshotRawValues() == ["steps"])
    }
}

// MARK: - F10: export sweep enumeration failure is loud

@Suite("ThirdPartyR9 export sweep")
struct ThirdPartyR9ExportSweepTests {
    @Test("missing directory throws instead of reporting success")
    func missingDirectoryThrows() throws {
        // Catches: the old `try? ?? []` reported success with zero files removed when
        // the tmp listing failed — a complete export JSON surviving a "cannot be
        // undone" wipe while the ledger claimed success.
        let missing = FileManager.default.temporaryDirectory.appending(path: "thirdpartyr9-\(UUID().uuidString)", directoryHint: .isDirectory)
        #expect(throws: (any Error).self) {
            try StoreDeleter.deleteExportFiles(in: missing)
        }
    }

    @Test("staged exports are removed from the scoped directory")
    func stagedExportsRemoved() throws {
        // Pin: the success path still sweeps prefix-scoped JSON and nothing else.
        let dir = FileManager.default.temporaryDirectory.appending(path: "thirdpartyr9-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let staged = dir.appending(path: "healthloom-export-2026-01-01.json")
        let keeper = dir.appending(path: "unrelated.txt")
        try Data("export".utf8).write(to: staged)
        try Data("keep".utf8).write(to: keeper)
        let removed = try StoreDeleter.deleteExportFiles(in: dir)
        #expect(removed.map(\.lastPathComponent) == ["healthloom-export-2026-01-01.json"])
        #expect(FileManager.default.fileExists(atPath: keeper.path))
    }
}

// MARK: - Cloud findings (F3/F5/F12/F13)

@Suite("ThirdPartyR9 cloud sync", .serialized)
@MainActor
struct ThirdPartyR9CloudSyncTests {
    @Test("equal-dated group bigger than the page still advances")
    func pathologicalEqualDatedGroupAdvances() async throws {
        // Catches (F3): 510 turns sharing one `createdAt` as the oldest unpushed rows —
        // the old `rows.filter { $0.createdAt < edge }` yielded `[]`, the watermark never
        // advanced, and every later turn stalled forever under `.synced`. Same-date
        // same-role turns share a turnID (round-9 proof), so the group pushes as its
        // distinct IDs only (2 saves — in-batch save-if-absent) and the watermark
        // advances past the group; the next sync is stable.
        let harness = try CloudSyncHarness.make()
        let edge = harness.now.addingTimeInterval(-5000)
        let context = ModelContext(harness.container)
        for i in 0..<510 {
            context.insert(ChatTurn(
                role: i.isMultiple(of: 2) ? "user" : "assistant",
                content: "same-date turn \(i)",
                createdAt: edge
            ))
        }
        try context.save()
        await harness.engine().syncNow()
        let saved = await harness.db.saved(ofType: CloudRecordType.coachTurn)
        #expect(saved.count == 2)
        // And the next sync has nothing left to do (watermark advanced past the group).
        await harness.engine().syncNow()
        #expect(await harness.db.saved(ofType: CloudRecordType.coachTurn).count == 2)
        #expect(try harness.localTurnCount() == 510)
    }

    @Test("newer-schema server records are never overwritten")
    func newerSchemaNeverOverwritten() throws {
        // Catches (F5): the old `try?` collapsed `.newerSchema` into the "malformed →
        // push:true" arm, so a v1 device saved its v1 field set over a v2 record and
        // destroyed v2-only state. Both singletons must skip the push.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let seen = now.addingTimeInterval(-1000)
        let v2Settings = try CloudRecordBuilder.record(for: SyncSettingsSnapshot(
            disabledTypeRawValues: [], preferAppleWatch: false, updatedAt: now))
        v2Settings["v"] = 2 as CKRecordValue
        let settingsDecision = CloudSyncEngine.settingsPushDecision(
            server: v2Settings,
            snapshot: SyncSettingsSnapshot(disabledTypeRawValues: ["steps"], preferAppleWatch: true, updatedAt: now),
            previouslySeen: seen)
        #expect(settingsDecision.push == false)
        let v2Prefs = try CloudRecordBuilder.record(for: InsightPrefsSnapshot(
            morningInsightsEnabled: true, lockScreenDetails: false, insightsViaCloud: false, lastRun: nil, updatedAt: now))
        v2Prefs["v"] = 2 as CKRecordValue
        let prefsDecision = CloudSyncEngine.prefsPushDecision(
            server: v2Prefs,
            snapshot: InsightPrefsSnapshot(morningInsightsEnabled: false, lockScreenDetails: false, insightsViaCloud: false, lastRun: nil, updatedAt: now),
            previouslySeen: seen)
        #expect(prefsDecision.push == false)
        // Pin: genuinely malformed records still push (overwritten, never preserved).
        let malformed = CKRecord(recordType: CloudRecordType.settings, recordID: CKRecord.ID(recordName: CloudRecordType.settingsRecordName))
        let malformedDecision = CloudSyncEngine.settingsPushDecision(
            server: malformed,
            snapshot: SyncSettingsSnapshot(disabledTypeRawValues: [], preferAppleWatch: false, updatedAt: now),
            previouslySeen: seen)
        #expect(malformedDecision.push == true)
    }

    @Test("push ordering follows server truth, not a skewed client field")
    func pushOrderingUsesServerTruth() throws {
        // Catches (F12): LWW keyed entirely on client clocks — a future-dated `updatedAt`
        // field (fast-clock peer) suppressed every genuinely newer record. With an
        // honest server order date at-or-before the watermark, a differing local state
        // still pushes even though the stored field claims the future.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let seen = now
        let futureField = now.addingTimeInterval(1800)
        let server = try CloudRecordBuilder.record(for: SyncSettingsSnapshot(
            disabledTypeRawValues: [], preferAppleWatch: false, updatedAt: futureField))
        let decision = CloudSyncEngine.settingsPushDecision(
            server: server,
            snapshot: SyncSettingsSnapshot(disabledTypeRawValues: ["steps"], preferAppleWatch: false, updatedAt: now),
            previouslySeen: seen,
            serverOrderDate: now)
        #expect(decision.push == true)
        #expect(decision.newSeen == now)
    }

    @Test("turn push issues no per-turn fetches")
    func turnPushBatchesExistence() async throws {
        // Catches (F13): one `fetchRecord` round trip per turn (up to 500 sequential
        // fetches per sync). The push now materializes the existing set with one paged
        // walk; individual turn names must never hit `fetchRecord`.
        let harness = try CloudSyncHarness.make()
        for i in 0..<3 {
            try harness.seedTurn(content: "batched \(i)", at: harness.now.addingTimeInterval(Double(i)))
        }
        await harness.engine().syncNow()
        #expect(await harness.db.saved(ofType: CloudRecordType.coachTurn).count == 3)
        let turnFetches = await harness.db.fetchCalls.keys.filter { $0.hasPrefix("turn-") }
        #expect(turnFetches.isEmpty)
    }
}
