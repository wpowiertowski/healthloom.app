// CloudSyncEngine.swift
//
// iCloud sync, CloudKit PRIVATE database only (owner scope lock): the
// user's own iCloud; no app server ever sees this data. Syncs app-owned
// data ONLY — settings, insight preferences, coach history. HealthKit-
// sourced values never cross (see CloudSyncPayload.swift's invariant).
//
// Conflict model: last-sync-wins with a seen-watermark. Each singleton
// tracks the newest server `updatedAt` it has ever observed; a push goes
// out only when the server is NOT newer than last seen, and a pull
// applies only server state newer than last applied. Rationale:
// single-user private database; concurrent multi-device edits are rare;
// convergence (no oscillation, no server-data destruction) beats CRDT
// machinery for preferences. Documented tradeoff, pinned by test: a
// device that stayed offline while another wrote newer state defers to
// the server, discarding its own stale edit. Coach turns are append-only
// and never updated, so they need no resolution at all (save-if-absent).
// Every loss direction is tested: server-newer overwrites local,
// local-newer overwrites server, equal content skips the write,
// newer-schema/malformed records are skipped without touching local.
//
// Offline: a persisted outbox (UserDefaults JSON) holds push intent when
// the account is undetermined or the network fails; it flushes on the
// next successful sync. Local state is always the source of truth, so a
// failed sync loses nothing — the status surface says so honestly.
//
// Account mapping: no account / restricted → `.localOnly`, SILENT (the
// user did nothing wrong); undetermined (transient daemon state) →
// queue silently and retry later; anything else that fails → surfaced
// `.failed` message + outbox (retryable) or surface-only (structural).

import CloudKit
import CoreModel
import SyncKit
import Foundation
import Observation
import SwiftData

/// Container this feature uses. Must ALSO be ticked on the App ID in the
/// portal (human step) — without it every call fails closed to local-only.
nonisolated enum CloudSyncContainer {
    static let identifier = "iCloud.app.healthloom"
}

nonisolated enum CloudAccountState: Sendable, Equatable {
    case available
    case noAccount
    case undetermined
}

/// Seam for tests: the engine never touches `CKContainer`/`CKDatabase`
/// directly. Typed throws keep CloudKit out of the engine's vocabulary —
/// the live adapter maps `CKError`, the stub throws `CloudSyncError`.
nonisolated protocol CloudDatabase: Sendable {
    nonisolated    func accountState() async -> CloudAccountState
    nonisolated    func fetchRecord(recordName: String) async throws(CloudSyncError) -> CKRecord?
    nonisolated    func saveRecord(_ record: CKRecord) async throws(CloudSyncError) -> CKRecord
    nonisolated    func allTurnRecords() async throws(CloudSyncError) -> [CKRecord]
}

nonisolated struct LiveCloudDatabase: CloudDatabase {
    private var database: CKDatabase {
        CKContainer(identifier: CloudSyncContainer.identifier).privateCloudDatabase
    }

    func accountState() async -> CloudAccountState {
        let status: CKAccountStatus
        do {
            status = try await CKContainer(identifier: CloudSyncContainer.identifier).accountStatus()
        } catch {
            return .undetermined
        }
        switch status {
        case CKAccountStatus.available: return .available
        case CKAccountStatus.noAccount, CKAccountStatus.restricted: return .noAccount
        // Both transient: queue silently, retry on a later sync.
        case CKAccountStatus.couldNotDetermine, CKAccountStatus.temporarilyUnavailable: return .undetermined
        @unknown default: return .undetermined
        }
    }

    func fetchRecord(recordName: String) async throws(CloudSyncError) -> CKRecord? {
        do {
            return try await database.record(for: CKRecord.ID(recordName: recordName))
        } catch {
            if (error as? CKError)?.code == .unknownItem {
                return nil
            }
            throw mapError(error)
        }
    }

    func saveRecord(_ record: CKRecord) async throws(CloudSyncError) -> CKRecord {
        do {
            return try await database.save(record)
        } catch {
            throw mapError(error)
        }
    }

    func allTurnRecords() async throws(CloudSyncError) -> [CKRecord] {
        let query = CKQuery(recordType: CloudRecordType.coachTurn, predicate: NSPredicate(value: true))
        let matches: [(CKRecord.ID, Result<CKRecord, Error>)]
        do {
            (matches, _) = try await database.records(matching: query)
        } catch {
            throw mapError(error)
        }
        // Strict, not compactMap: a silently dropped turn is data loss by
        // another name — surface it instead. A `for` loop, not
        // `matches.map`, because legacy `rethrows` erases the closure's
        // typed error to `any Error`.
        var records: [CKRecord] = []
        records.reserveCapacity(matches.count)
        for (_, result) in matches {
            switch result {
            case .success(let record): records.append(record)
            case .failure(let error): throw mapError(error)
            }
        }
        return records
    }

    private func mapError(_ error: Error) -> CloudSyncError {
        guard let ck = error as? CKError else {
            return .failed(error.localizedDescription)
        }
        switch ck.code {
        case .notAuthenticated, .permissionFailure:
            // Includes the portal-tick-missing case (container unknown to
            // the account): local-only, with a message naming the cause.
            return .failed("iCloud account or container unavailable (\(ck.code.rawValue)).")
        case .networkFailure, .networkUnavailable, .serviceUnavailable,
             .requestRateLimited, .zoneBusy, .operationCancelled:
            return .retryable(ck.localizedDescription)
        default:
            return .failed(ck.localizedDescription)
        }
    }
}

/// What Settings shows. `pending` counts queued outbox ops; `failed`
/// carries the surfaced message. Local data is never at risk in any of
/// these states — the outbox (or the local store itself) holds everything.
nonisolated enum CloudSyncStatus: Equatable, Sendable {
    case localOnly
    case syncing
    case synced(at: Date?, pending: Int)
    case failed(message: String)
}

/// Persisted push intent. `pushSingletons` always covers settings + prefs
/// together (both are one small record; no reason to version them
/// separately). `pushTurns` replays "everything since the watermark".
nonisolated enum CloudOutboxOp: String, Codable, Sendable {
    case pushSingletons
    case pushTurns
}

extension Notification.Name {
    /// Posted (main actor) after a pull applies server state to local
    /// defaults — SettingsView's instances reload from the same keys.
    static let cloudSyncDidApply = Notification.Name("com.healthloom.cloudsync.didApply")
}

@MainActor
@Observable
final class CloudSyncEngine {
    private static let lastSyncKey = "com.healthloom.cloudsync.lastSync"
    private static let outboxKey = "com.healthloom.cloudsync.outbox"
    private static let appliedSettingsKey = "com.healthloom.cloudsync.appliedSettingsAt"
    private static let appliedPrefsKey = "com.healthloom.cloudsync.appliedPrefsAt"
    private static let seenSettingsKey = "com.healthloom.cloudsync.seenSettingsAt"
    private static let seenPrefsKey = "com.healthloom.cloudsync.seenPrefsAt"
    private static let pushedTurnsKey = "com.healthloom.cloudsync.pushedTurnsThrough"

    private let container: ModelContainer
    private let defaults: UserDefaults
    private let database: any CloudDatabase
    private let now: () -> Date

    /// Owner instances on the SHARED defaults — reads compose snapshots,
    /// pull-applies write through these same instances (so `didSet`
    /// persistence runs), and SettingsView's own instances reload from
    /// the keys on `.cloudSyncDidApply`.
    private let syncPreferences: SyncPreferences
    private let insightPrefs: InsightPreferences

    var status: CloudSyncStatus = .synced(at: nil, pending: 0)

    init(
        container: ModelContainer,
        defaults: UserDefaults = .standard,
        database: any CloudDatabase,
        now: @escaping () -> Date = Date.init
    ) {
        self.container = container
        self.defaults = defaults
        self.database = database
        self.now = now
        self.syncPreferences = SyncPreferences(defaults: defaults)
        self.insightPrefs = InsightPreferences(defaults: defaults)
        let pending = outbox.count
        if pending > 0 {
            self.status = .synced(at: lastSync, pending: pending)
        } else if let last = lastSync {
            self.status = .synced(at: last, pending: 0)
        }
    }

    /// Full push + pull. Safe to call whenever (launch, Sync Now): the
    /// account gate runs first, and re-entrancy is a no-op.
    func syncNow() async {
        guard status != .syncing else { return }
        switch await database.accountState() {
        case .noAccount:
            status = .localOnly
            return
        case .undetermined:
            enqueue(.pushSingletons)
            enqueue(.pushTurns)
            refreshStatus()
            return
        case .available:
            break
        }
        status = .syncing
        do {
            try await pushSingletons()
            try await pushNewTurns()
            try await pullSingletons()
            try await pullMissingTurns()
            clearOutbox()
            lastSync = now()
            status = .synced(at: lastSync, pending: 0)
        } catch {
            // Every callee throws CloudSyncError, so `error` already is
            // one — no cast (the compiler proves it).
            handle(error)
        }
    }

    // MARK: - Push

    private func pushSingletons() async throws(CloudSyncError) {
        let settings = readSettings()
        if try await shouldPush(snapshot: settings, recordName: CloudRecordType.settingsRecordName) {
            _ = try await database.saveRecord(try CloudRecordBuilder.record(for: settings))
        }
        if try await shouldPushPrefs() {
            _ = try await database.saveRecord(try CloudRecordBuilder.record(for: readPrefs()))
        }
    }

    /// Push unless the server holds state newer than we have ever seen
    /// (the pull phase owns that direction) or EQUAL content (saves a
    /// write on every clean sync; makes "no redundant saves" testable).
    /// Malformed server records are overwritten, never preserved.
    private func shouldPush(snapshot: SyncSettingsSnapshot, recordName: String) async throws(CloudSyncError) -> Bool {
        guard let server = try await database.fetchRecord(recordName: recordName) else {
            return true
        }
        guard let serverSnap = try? CloudRecordDecoder.settings(from: server) else {
            return true
        }
        let previouslySeen = seenSettingsAt
        seenSettingsAt = max(previouslySeen, serverSnap.updatedAt)
        if serverSnap.updatedAt > previouslySeen {
            return false
        }
        return serverSnap.disabledTypeRawValues != snapshot.disabledTypeRawValues
            || serverSnap.preferAppleWatch != snapshot.preferAppleWatch
    }

    private func shouldPushPrefs() async throws(CloudSyncError) -> Bool {
        guard let server = try await database.fetchRecord(recordName: CloudRecordType.insightPrefsRecordName) else {
            return true
        }
        guard let serverSnap = try? CloudRecordDecoder.prefs(from: server) else {
            return true
        }
        let previouslySeen = seenPrefsAt
        seenPrefsAt = max(previouslySeen, serverSnap.updatedAt)
        if serverSnap.updatedAt > previouslySeen {
            return false
        }
        let current = readPrefs()
        return serverSnap.morningInsightsEnabled != current.morningInsightsEnabled
            || serverSnap.lockScreenDetails != current.lockScreenDetails
            || serverSnap.insightsViaCloud != current.insightsViaCloud
            || serverSnap.lastRun != current.lastRun
    }

    private func pushNewTurns() async throws(CloudSyncError) {
        let watermark = pushedTurnsThrough
        let turns = try localTurns().filter { watermark == nil || $0.createdAt > watermark! }
        var latest = watermark
        for turn in turns {
            let recordName = CloudRecordType.turnRecordName(for: turn.turnID)
            if try await database.fetchRecord(recordName: recordName) == nil {
                _ = try await database.saveRecord(try CloudRecordBuilder.record(for: turn))
            }
            latest = max(latest ?? .distantPast, turn.createdAt)
        }
        if let latest {
            pushedTurnsThrough = latest
        }
    }

    // MARK: - Pull (last-write-wins)

    private func pullSingletons() async throws(CloudSyncError) {
        if let server = try await database.fetchRecord(recordName: CloudRecordType.settingsRecordName),
           let snap = try? CloudRecordDecoder.settings(from: server),
           snap.updatedAt > appliedSettingsAt
        {
            // Content-equal (e.g. our own just-pushed write read back):
            // advance the watermark silently, no redundant apply.
            let current = readSettings()
            if snap.disabledTypeRawValues != current.disabledTypeRawValues
                || snap.preferAppleWatch != current.preferAppleWatch
            {
                applySettings(snap)
            }
            appliedSettingsAt = snap.updatedAt
        }
        if let server = try await database.fetchRecord(recordName: CloudRecordType.insightPrefsRecordName),
           let snap = try? CloudRecordDecoder.prefs(from: server),
           snap.updatedAt > appliedPrefsAt
        {
            let current = readPrefs()
            if snap.morningInsightsEnabled != current.morningInsightsEnabled
                || snap.lockScreenDetails != current.lockScreenDetails
                || snap.insightsViaCloud != current.insightsViaCloud
                || snap.lastRun != current.lastRun
            {
                applyPrefs(snap)
            }
            appliedPrefsAt = snap.updatedAt
        }
    }

    private func pullMissingTurns() async throws(CloudSyncError) {
        let serverTurns = try await database.allTurnRecords()
        let local = Set(try localTurns().map { "\($0.role)|\($0.content)|\($0.createdAt.timeIntervalSince1970)" })
        let context = ModelContext(container)
        var inserted = false
        for record in serverTurns {
            guard let snap = try? CloudRecordDecoder.turn(from: record) else {
                continue // malformed turn: skip, never crash the sync
            }
            let key = "\(snap.role)|\(snap.content)|\(snap.createdAt.timeIntervalSince1970)"
            guard !local.contains(key) else { continue }
            context.insert(ChatTurn(role: snap.role, content: snap.content, createdAt: snap.createdAt))
            inserted = true
        }
        if inserted {
            do {
                try context.save()
            } catch {
                throw CloudSyncError.failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Local reads/writes (app-owned types only)

    private func readSettings() -> SyncSettingsSnapshot {
        SyncSettingsSnapshot(
            disabledTypeRawValues: syncPreferences.snapshotRawValues(),
            preferAppleWatch: defaults.bool(forKey: UserDefaultsWatchPriorityPreference.defaultsKey),
            updatedAt: now()
        )
    }

    private func readPrefs() -> InsightPrefsSnapshot {
        InsightPrefsSnapshot(
            morningInsightsEnabled: insightPrefs.morningInsightsEnabled,
            lockScreenDetails: insightPrefs.lockScreenDetails,
            insightsViaCloud: insightPrefs.insightsViaCloud,
            lastRun: insightPrefs.lastRun,
            updatedAt: now()
        )
    }

    private func applySettings(_ snap: SyncSettingsSnapshot) {
        syncPreferences.replaceDisabledTypes(with: snap.disabledTypeRawValues)
        defaults.set(snap.preferAppleWatch, forKey: UserDefaultsWatchPriorityPreference.defaultsKey)
        NotificationCenter.default.post(name: .cloudSyncDidApply, object: nil)
    }

    private func applyPrefs(_ snap: InsightPrefsSnapshot) {
        insightPrefs.morningInsightsEnabled = snap.morningInsightsEnabled
        insightPrefs.lockScreenDetails = snap.lockScreenDetails
        insightPrefs.insightsViaCloud = snap.insightsViaCloud
        insightPrefs.lastRun = snap.lastRun
        NotificationCenter.default.post(name: .cloudSyncDidApply, object: nil)
    }

    private func localTurns() throws(CloudSyncError) -> [CoachTurnSnapshot] {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<ChatTurn>(sortBy: [SortDescriptor(\.createdAt)])
        // Cap the replay window: history sync is a convenience, not an
        // archive migration — 500 most recent turns bound the upload.
        descriptor.fetchLimit = 500
        let rows: [ChatTurn]
        do {
            rows = try context.fetch(descriptor)
        } catch {
            throw CloudSyncError.failed(error.localizedDescription)
        }
        return rows.map {
            CoachTurnSnapshot(
                turnID: "\($0.createdAt.timeIntervalSince1970)-\($0.role)",
                role: $0.role,
                content: $0.content,
                createdAt: $0.createdAt
            )
        }
    }

    // MARK: - Outbox + persisted state

    private var outbox: [CloudOutboxOp] {
        get {
            guard let data = defaults.data(forKey: Self.outboxKey),
                  let ops = try? JSONDecoder().decode([CloudOutboxOp].self, from: data)
            else {
                return []
            }
            return ops
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.outboxKey)
        }
    }

    private func enqueue(_ op: CloudOutboxOp) {
        var ops = outbox
        if !ops.contains(op) {
            ops.append(op)
            outbox = ops
        }
    }

    private func clearOutbox() {
        outbox = []
    }

    private var lastSync: Date? {
        get {
            let interval = defaults.double(forKey: Self.lastSyncKey)
            return interval > 0 ? Date(timeIntervalSince1970: interval) : nil
        }
        set {
            defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Self.lastSyncKey)
        }
    }

    private var seenSettingsAt: Date {
        get { Date(timeIntervalSince1970: defaults.double(forKey: Self.seenSettingsKey)) }
        set { defaults.set(newValue.timeIntervalSince1970, forKey: Self.seenSettingsKey) }
    }

    private var seenPrefsAt: Date {
        get { Date(timeIntervalSince1970: defaults.double(forKey: Self.seenPrefsKey)) }
        set { defaults.set(newValue.timeIntervalSince1970, forKey: Self.seenPrefsKey) }
    }

    private var appliedSettingsAt: Date {
        get { Date(timeIntervalSince1970: defaults.double(forKey: Self.appliedSettingsKey)) }
        set { defaults.set(newValue.timeIntervalSince1970, forKey: Self.appliedSettingsKey) }
    }

    private var appliedPrefsAt: Date {
        get { Date(timeIntervalSince1970: defaults.double(forKey: Self.appliedPrefsKey)) }
        set { defaults.set(newValue.timeIntervalSince1970, forKey: Self.appliedPrefsKey) }
    }

    private var pushedTurnsThrough: Date? {
        get {
            let interval = defaults.double(forKey: Self.pushedTurnsKey)
            return interval > 0 ? Date(timeIntervalSince1970: interval) : nil
        }
        set {
            defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Self.pushedTurnsKey)
        }
    }

    private func refreshStatus() {
        status = .synced(at: lastSync, pending: outbox.count)
    }

    private func handle(_ error: CloudSyncError) {
        switch error {
        case .noAccount:
            status = .localOnly
        case .retryable(let message):
            enqueue(.pushSingletons)
            enqueue(.pushTurns)
            status = .failed(message: "iCloud unreachable — will retry. \(message)")
        case .failed(let message):
            status = .failed(message: message)
        case .rejectedFields, .unknownRecordType, .newerSchema, .missingField:
            // Structural: retrying cannot help, and the local store is
            // untouched — surface, don't queue.
            status = .failed(message: "iCloud sync encountered unexpected data. Local data is unaffected.")
        }
    }
}
