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
// Offline: a persisted retry flag holds push intent when the account
// is undetermined or the network fails; it clears on the next
// successful sync. There is deliberately NO op queue (round-10 item
// 10): `syncNow` always runs the full push+pull, so queued ops could
// never gate work — the old `[CloudOutboxOp]` list was count theater
// (always 0-or-2) around a Bool. Local state is always the source of
// truth, so a failed sync loses nothing — the status surface says so
// honestly.
//
// Account mapping: no account / restricted → `.localOnly`, SILENT (the
// user did nothing wrong); undetermined (transient daemon state) →
// flag silently and retry later; anything else that fails → surfaced
// `.failed` message + retry flag (retryable) or surface-only
// (structural).

import CloudKit
import CoreModel
import SyncKit
import Foundation
import Observation
import SwiftData

/// Container this feature uses. Must ALSO be ticked on the App ID in the
/// portal (human step) — without the tick the account can still report
/// `.available` while every call fails, surfacing a container-unavailable
/// error (NOT silent local-only: silent is reserved for no-account, where
/// the user did nothing wrong).
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
/// One page of turn records: materialized records plus the opaque
/// cursor for the next page (`nil` = exhausted). `Sendable` so the
/// engine's cursor loop can hold it across awaits.
nonisolated struct CloudTurnPage: Sendable {
    var records: [CKRecord]
    var nextCursor: Data?
}

nonisolated protocol CloudDatabase: Sendable {
    nonisolated    func accountState() async -> CloudAccountState
    nonisolated    func fetchRecord(recordName: String) async throws(CloudSyncError) -> CKRecord?
    nonisolated    func saveRecord(_ record: CKRecord) async throws(CloudSyncError) -> CKRecord
    /// One page of turn records (round-6 item 4): the engine follows
    /// `nextCursor` until nil. `cursor` is an opaque token minted by a
    /// previous page (`nil` = first page) — Live archives the real
    /// `CKQueryCursor` (`NSSecureCoding`) into it; the stub uses page
    /// indexes. Never persisted: a token is valid only within the walk
    /// that minted it.
    nonisolated    func turnPage(cursor: Data?) async throws(CloudSyncError) -> CloudTurnPage
    /// Deletes one record by name; missing is success (idempotent —
    /// the wipe deletes by enumerated names, and a concurrent device
    /// may have removed one first).
    nonisolated    func deleteRecord(recordName: String) async throws(CloudSyncError)
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

    func turnPage(cursor: Data?) async throws(CloudSyncError) -> CloudTurnPage {
        // Page size bounds one round trip, not the walk: the engine
        // follows `nextCursor` until nil (round-6 item 4), so any
        // finite size is correct — 200 keeps single pages small
        // without chattering on large transcripts.
        let pageSize = 200
        let matches: [(CKRecord.ID, Result<CKRecord, Error>)]
        let queryCursor: CKQueryOperation.Cursor?
        do {
            if let cursor {
                // Round-8 item 4: a nil-unarchive FAILS LOUDLY (see
                // `CloudTurnCursorCodec`) — the old fall-through
                // restarted from a fresh query, fetching page 1 up to
                // 100× (20k duplicate work) while pages 2..n were never
                // reached; under `deleteAllCloudData` turns past 200
                // were never deleted while the ledger reported success.
                let resumed = try CloudTurnCursorCodec.decode(cursor)
                (matches, queryCursor) = try await database.records(continuingMatchFrom: resumed, resultsLimit: pageSize)
            } else {
                let query = CKQuery(recordType: CloudRecordType.coachTurn, predicate: NSPredicate(value: true))
                (matches, queryCursor) = try await database.records(matching: query, resultsLimit: pageSize)
            }
        } catch let syncError as CloudSyncError {
            throw syncError // our own loud failures keep their message
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
        let nextCursor: Data?
        do {
            nextCursor = try queryCursor.map(CloudTurnCursorCodec.encode)
        } catch {
            // A cursor that cannot round-trip must fail LOUDLY, never
            // restart the walk from scratch (which would re-pull and
            // re-process every page already consumed — and, worse, look
            // exactly like success).
            throw CloudSyncError.failed("turn pagination cursor could not be encoded")
        }
        return CloudTurnPage(records: records, nextCursor: nextCursor)
    }

    func deleteRecord(recordName: String) async throws(CloudSyncError) {
        do {
            try await database.deleteRecord(withID: CKRecord.ID(recordName: recordName))
        } catch {
            // Missing is success (idempotent wipe — see the protocol).
            if (error as? CKError)?.code == .unknownItem { return }
            throw mapError(error)
        }
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

/// What Settings shows. `pending` is 0 or 1 (a retry is owed, not
/// an op count — see the retry-flag note above); `failed` carries the
/// surfaced message. Local data is never at risk in any of these states
/// — the local store itself holds everything.
nonisolated enum CloudSyncStatus: Equatable, Sendable {
    case localOnly
    case syncing
    case synced(at: Date?, pending: Int)
    case failed(message: String)
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

    /// Retry intent, for tests (structural failures must NOT flag;
    /// retryable ones must). 0 or 1 — the old op count is gone with the
    /// op queue (round-10 item 10). Status already surfaces it to users.
    var pendingOutboxCount: Int { retryPending ? 1 : 0 }

    /// Quiesce probe (round-10 item 1): when a wipe has latched, EVERY
    /// trigger no-ops until relaunch (writes would resurrect cleared
    /// records/markers or go through the unlinked store handle).
    /// Injected (production reads `WipeQuiesce.isLatched`) so tests
    /// script it without touching the process-wide latch.
    private let isQuiesced: () -> Bool

    init(
        container: ModelContainer,
        defaults: UserDefaults = .standard,
        database: any CloudDatabase,
        now: @escaping () -> Date = Date.init,
        isQuiesced: @escaping () -> Bool = { false }
    ) {
        self.container = container
        self.defaults = defaults
        self.database = database
        self.now = now
        self.syncPreferences = SyncPreferences(defaults: defaults)
        self.insightPrefs = InsightPreferences(defaults: defaults)
        self.isQuiesced = isQuiesced
        let pending = retryPending ? 1 : 0
        if pending > 0 {
            self.status = .synced(at: lastSync, pending: pending)
        } else if let last = lastSync {
            self.status = .synced(at: last, pending: 0)
        }
    }

    /// Full push + pull. Safe to call whenever (launch, Sync Now): the
    /// account gate runs first, and re-entrancy is a no-op.
    func syncNow() async {
        // Round-10 item 1: quiesced (wipe latched, relaunch pending) —
        // return before even claiming. A post-wipe sync would re-push
        // empty state, rewrite cleared markers, and read through the
        // unlinked store handle; the UI asks for relaunch instead.
        guard !isQuiesced() else { return }
        // Round-4-sync item 3: claim BEFORE the first await — guard and
        // claim are suspension-free on this actor, so no second caller
        // can slip between them. The old shape guarded, then awaited
        // `accountState`, then claimed: concurrent callers both passed
        // the guard and ran full duplicate push/pulls (AGENTS.md §2's
        // named TOCTOU shape).
        guard status != .syncing else { return }
        status = .syncing
        switch await database.accountState() {
        case .noAccount:
            status = .localOnly
            return
        case .undetermined:
            retryPending = true
            refreshStatus()
            return
        case .available:
            break
        }
        // Round-6 item 6: the owner instances are built once in `init`
        // but Settings writes through its OWN instances — re-read live
        // before every sync or post-launch toggles stay invisible to
        // push until cold launch (and lose LWW races against a second
        // device that did push). Defaults stay the single source;
        // instances are views (same F1 posture as the insight runner).
        syncPreferences.reload()
        insightPrefs.reload()
        do {
            try await pushSingletons()
            try await pushNewTurns()
            try await pullSingletons()
            try await pullMissingTurns()
            retryPending = false
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
        let serverSettings = try await database.fetchRecord(recordName: CloudRecordType.settingsRecordName)
        let settingsDecision = Self.settingsPushDecision(server: serverSettings, snapshot: settings, previouslySeen: seenSettingsAt, serverOrderDate: serverSettings?.modificationDate)
        seenSettingsAt = settingsDecision.newSeen
        if settingsDecision.push {
            let saved: CKRecord
            if let server = serverSettings {
                // Round-4-sync item 2: mutate the FETCHED record — it
                // carries the server change token. A fresh tagless build
                // saved over an existing record fails
                // serverRecordChanged, which the classifier treats as
                // non-retryable: every post-first push would fail
                // forever and settings/prefs would never sync again.
                try CloudRecordBuilder.update(server, with: settings)
                saved = try await database.saveRecord(server)
            } else {
                saved = try await database.saveRecord(try CloudRecordBuilder.record(for: settings))
            }
            // Round-8 item 6 (third-party r9: server-truth ordering): advance past
            // OUR OWN write — without this the next sync misreads our just-pushed
            // record as foreign-newer (server date vs epoch seen) and suppresses
            // the user's intervening local change one sync late (an
            // LWW race a second device always wins). The watermark takes the
            // SAVED record's server `modificationDate` when CloudKit provides one
            // (Live always does) and falls back to our own `updatedAt` only for
            // fabricated/stub records that carry no server metadata — so a
            // fast-clock device can never poison the watermark with a future-dated
            // local `now()` (third-party r9 clock-skew fix).
            seenSettingsAt = max(seenSettingsAt, saved.modificationDate ?? settings.updatedAt)
        }
        let prefs = readPrefs()
        let serverPrefs = try await database.fetchRecord(recordName: CloudRecordType.insightPrefsRecordName)
        let prefsDecision = Self.prefsPushDecision(server: serverPrefs, snapshot: prefs, previouslySeen: seenPrefsAt, serverOrderDate: serverPrefs?.modificationDate)
        seenPrefsAt = prefsDecision.newSeen
        if prefsDecision.push {
            let saved: CKRecord
            if let server = serverPrefs {
                try CloudRecordBuilder.update(server, with: prefs)
                saved = try await database.saveRecord(server)
            } else {
                saved = try await database.saveRecord(try CloudRecordBuilder.record(for: prefs))
            }
            seenPrefsAt = max(seenPrefsAt, saved.modificationDate ?? prefs.updatedAt)
        }
    }

    /// Push unless the server holds state newer than we have ever seen
    /// (the pull phase owns that direction) or EQUAL content (saves a
    /// write on every clean sync; makes "no redundant saves" testable).
    /// Malformed server records are overwritten, never preserved.
    /// Pure decisions (round-4-sync item 12): each singleton owns its
    /// fetch + watermark — the old shared `recordName`-parameterized
    /// predicate hardcoded the SETTINGS watermark, so calling it with
    /// the prefs name would have suppressed settings pushes. There is
    /// no shared predicate left to miscall. Neither mutates state: they
    /// return the decision AND the advanced watermark; the caller
    /// assigns (a predicate with side effects is untestable).
    struct SingletonPushDecision: Equatable {
        var push: Bool
        var newSeen: Date
    }

    /// Server ordering date for LWW (third-party r9 clock-skew fix): CloudKit's
    /// server-stamped `modificationDate` when available (Live records always carry
    /// it), else the explicit test override, else the client-written `updatedAt`
    /// field. Ordering on client clocks alone lets a fast-clock device poison the
    /// seen watermark with a future `now()` and suppress every genuinely newer
    /// record from the other device; ordering on server truth is skew-immune.
    /// Tests drive the skew dimension through `serverOrderDate` (a fabricated
    /// `CKRecord` carries no server metadata, so the date must be injectable).
    nonisolated static func settingsPushDecision(server: CKRecord?, snapshot: SyncSettingsSnapshot, previouslySeen: Date, serverOrderDate: Date? = nil) -> SingletonPushDecision {
        guard let server else {
            return SingletonPushDecision(push: true, newSeen: previouslySeen)
        }
        do {
            let serverSnap = try CloudRecordDecoder.settings(from: server)
            let orderDate = serverOrderDate ?? server.modificationDate ?? serverSnap.updatedAt
            let newSeen = max(previouslySeen, orderDate)
            if orderDate > previouslySeen {
                return SingletonPushDecision(push: false, newSeen: newSeen)
            }
            let differs = serverSnap.disabledTypeRawValues != snapshot.disabledTypeRawValues
                || serverSnap.preferAppleWatch != snapshot.preferAppleWatch
            return SingletonPushDecision(push: differs, newSeen: newSeen)
        } catch CloudSyncError.newerSchema {
            // Third-party r9 forward-safety: an older app must NEVER overwrite a
            // newer schema's record (the old `try?` collapsed this into the
            // "malformed → push:true" arm and destroyed v2 state). Skip the push;
            // advance the watermark only on server truth (never blindly), so the
            // record is not re-contended every sync yet never clobbered.
            // Catches: v1 device observing a v2 record must not push.
            if let orderDate = serverOrderDate ?? server.modificationDate {
                return SingletonPushDecision(push: false, newSeen: max(previouslySeen, orderDate))
            }
            return SingletonPushDecision(push: false, newSeen: previouslySeen)
        } catch {
            // Genuinely corrupt (missing field, unknown type): overwrite, never preserve.
            return SingletonPushDecision(push: true, newSeen: previouslySeen)
        }
    }

    nonisolated static func prefsPushDecision(server: CKRecord?, snapshot: InsightPrefsSnapshot, previouslySeen: Date, serverOrderDate: Date? = nil) -> SingletonPushDecision {
        guard let server else {
            return SingletonPushDecision(push: true, newSeen: previouslySeen)
        }
        do {
            let serverSnap = try CloudRecordDecoder.prefs(from: server)
            let orderDate = serverOrderDate ?? server.modificationDate ?? serverSnap.updatedAt
            let newSeen = max(previouslySeen, orderDate)
            if orderDate > previouslySeen {
                return SingletonPushDecision(push: false, newSeen: newSeen)
            }
            let differs = serverSnap.morningInsightsEnabled != snapshot.morningInsightsEnabled
                || serverSnap.lockScreenDetails != snapshot.lockScreenDetails
                || serverSnap.insightsViaCloud != snapshot.insightsViaCloud
                || serverSnap.lastRun != snapshot.lastRun
            return SingletonPushDecision(push: differs, newSeen: newSeen)
        } catch CloudSyncError.newerSchema {
            if let orderDate = serverOrderDate ?? server.modificationDate {
                return SingletonPushDecision(push: false, newSeen: max(previouslySeen, orderDate))
            }
            return SingletonPushDecision(push: false, newSeen: previouslySeen)
        } catch {
            return SingletonPushDecision(push: true, newSeen: previouslySeen)
        }
    }

    /// Oldest 500 UNPUSHED turns (round-7 item 4): the watermark goes
    /// INTO the query predicate (not a post-fetch filter), so the batch
    /// is always the oldest unpushed prefix — the watermark covers a
    /// CONTIGUOUS pushed range by construction. The old newest-500
    /// window filtered post-fetch: a 900-turn offline accumulation
    /// pushed the newest 500, jumped the watermark past the oldest
    /// 400, and never pushed them — silent unrecoverable loss under a
    /// `.synced` status. Pacing preserved (500/sync); the remainder is
    /// strictly NEWER and goes next sync — delayed, never lost.
    ///
    /// Equal timestamps never split across batches (round-8 item 7):
    /// the scheme already assumes createdAt collisions (synthetic
    /// turnIDs collide for same-second same-role pairs), and a strict
    /// `>` vs `max(batch)` permanently excludes whichever equal-dated
    /// row falls on the wrong side of the 500-cut. The batch extends
    /// through the edge date (tiny groups — user/assistant pairs
    /// sharing a second), so the watermark always lands PAST every
    /// pushed row, never inside an equal-dated group.
    /// Oldest unpushed rows, capped (round-7 item 4: watermark in the
    /// predicate, oldest-first). May split an equal-dated group at the
    /// cap — callers extend through the edge date (see above). Takes
    /// the caller's context (round-9 item 5): identity-based dedupe
    /// across two contexts is inert, so the context must be shared.
    private func oldestUnpushedRows(limit: Int, in context: ModelContext) throws(CloudSyncError) -> [ChatTurn] {
        var descriptor: FetchDescriptor<ChatTurn>
        if let watermark = pushedTurnsThrough {
            descriptor = FetchDescriptor<ChatTurn>(
                predicate: #Predicate { $0.createdAt > watermark },
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]
            )
        } else {
            descriptor = FetchDescriptor<ChatTurn>(
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]
            )
        }
        descriptor.fetchLimit = limit
        do {
            return try context.fetch(descriptor)
        } catch {
            throw CloudSyncError.failed(error.localizedDescription)
        }
    }

    private func unpushedTurnBatch(limit: Int) throws(CloudSyncError) -> [CoachTurnSnapshot] {
        // Round-9 item 5: ONE shared context for both fetches — the
        // old two-context shape made the identity dedupe below inert
        // (different instances per context, nothing ever filtered).
        // Hoisting alone would have DROPPED the whole edge group
        // (livelock, watermark never advances — the round-8-item-7
        // loss class), so the dedupe is key-based too: value identity
        // that survives any context split.
        let context = ModelContext(container)
        let first = try oldestUnpushedRows(limit: limit, in: context)
        guard let edge = first.last?.createdAt else { return [] }
        let edgeDescriptor = FetchDescriptor<ChatTurn>(
            predicate: #Predicate { $0.createdAt == edge },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let edgeRows: [ChatTurn]
        do {
            edgeRows = try context.fetch(edgeDescriptor)
        } catch {
            throw CloudSyncError.failed(error.localizedDescription)
        }
        // Round-10 item 8, amended third-party r9: a pathological edge group (bigger
        // than a full page) defers WHOLE — pushing part of it would strand the rest
        // past the watermark (the loss the atomic-group rule exists to prevent).
        // The watermark then lands on the last pre-edge row, so the group retries
        // whole next sync — never split, never stranded. AMENDMENT: when NOTHING
        // predates the group (the filter below yields `[]`), deferral is a permanent
        // stall — no turn pushes, the watermark never advances, every newer turn
        // blocks behind it under `.synced`. In exactly that case the group pushes
        // whole this sync (as its distinct turnIDs only — same-date same-role rows
        // share a name, so the batch stays small; pacing yields once to progress).
        // Unreachable in practice (distinct server records need distinct
        // `time-role` turnIDs, capping real groups at one pair — the
        // pair test pins that path); pure defense against clock games.
        var seen = Set(first.map { Self.turnDedupeKey(role: $0.role, content: $0.content, createdAt: $0.createdAt) })
        var rows = first
        if edgeRows.count <= limit {
            rows += edgeRows.filter {
                seen.insert(Self.turnDedupeKey(role: $0.role, content: $0.content, createdAt: $0.createdAt)).inserted
            }
        } else {
            // Pathological-group deferral (see above): drop the whole
            // edge group from this batch (it was never added — `rows`
            // is exactly the first page), then strip any partial group
            // tail so the watermark lands strictly before the group.
            rows = rows.filter { $0.createdAt < edge }
            // Third-party r9: when NOTHING predates the edge group (every row in
            // the first page shares one `createdAt` — clock reset, bulk import,
            // stalled device clock), the filter above yields `[]`: no turn pushes,
            // `latest` stays nil, the watermark never advances, and every later
            // turn behind it stalls forever under a `.synced` status. In exactly
            // this case push the whole edge group this sync (pacing yields once to
            // progress — the group retries whole, never split, never stranded).
            // Catches: 601 same-dated rows oldest-first must still advance.
            if rows.isEmpty {
                rows = edgeRows
            }
        }
        return rows.map {
            // Synthetic turnID, kept deliberately (third-party N1): a
            // content hash would survive clock changes, but renaming
            // the scheme later orphans already-pushed records
            // (save-if-absent keys on the name — orphans re-push as
            // server-side duplicates). Fractional-second timestamps
            // make collisions negligible, and readable names are
            // debuggable in the CloudKit dashboard. Revisit only with
            // a tombstone pass.
            CoachTurnSnapshot(
                turnID: "\($0.createdAt.timeIntervalSince1970)-\($0.role)",
                role: $0.role,
                content: $0.content,
                createdAt: $0.createdAt
            )
        }
    }

    private func pushNewTurns() async throws(CloudSyncError) {
        let turns = try unpushedTurnBatch(limit: 500)
        // Third-party r9: ONE paged existence walk instead of one `fetchRecord` per
        // turn (up to 500 sequential round trips per sync on every foreground
        // activation past the gate — minutes on a slow link, quota burn, and a
        // whole-batch retry on any single failure). The turn walk is already paged
        // (`turnPage`, same bound as the pull walk); materializing the existing
        // record-name set once up front mirrors how `pullMissingTurns` builds
        // `localTurnKeys()` before its loop. Catches: a 500-turn backlog must push
        // without 500 pre-save fetches.
        let existingNames: Set<String>
        if turns.isEmpty {
            existingNames = []
        } else {
            existingNames = Set(try await pullAllTurnRecords().map(\.recordID.recordName))
        }
        // In-batch save-if-absent: same-date same-role turns share a synthetic turnID
        // (round-9 proof — only date+role feed the name), so a pathological batch can
        // name one record dozens of times. A second save of the same name is a wasted
        // overwrite on Live and a `serverRecordChanged` throw against a token-checking
        // store — insert into the set as you go (same pattern as `pullMissingTurns`).
        var savedNames = existingNames
        var latest: Date?
        for turn in turns {
            let recordName = CloudRecordType.turnRecordName(for: turn.turnID)
            if !savedNames.contains(recordName) {
                _ = try await database.saveRecord(try CloudRecordBuilder.record(for: turn))
                savedNames.insert(recordName)
            }
            latest = max(latest ?? .distantPast, turn.createdAt)
        }
        if let latest {
            pushedTurnsThrough = latest
        }
    }

    // MARK: - Pull (last-write-wins)

    private func pullSingletons() async throws(CloudSyncError) {
        // Third-party r9: applied watermarks track the same server ordering date as
        // the seen watermarks (modificationDate-preferred, client-field fallback) —
        // a fast-clock peer's future-dated `updatedAt` field must not pin the applied
        // watermark in the future and suppress genuinely newer records. The pull
        // direction keeps `try?` decode-and-skip (newer-schema/malformed server
        // records are never applied) — forward-safety holds here; only the push
        // path needed distinct arms.
        if let server = try await database.fetchRecord(recordName: CloudRecordType.settingsRecordName),
           let snap = try? CloudRecordDecoder.settings(from: server)
        {
            let orderDate = server.modificationDate ?? snap.updatedAt
            if orderDate > appliedSettingsAt {
                // Content-equal (e.g. our own just-pushed write read back):
                // advance the watermark silently, no redundant apply.
                let current = readSettings()
                if snap.disabledTypeRawValues != current.disabledTypeRawValues
                    || snap.preferAppleWatch != current.preferAppleWatch
                {
                    applySettings(snap)
                }
                appliedSettingsAt = orderDate
            }
        }
        if let server = try await database.fetchRecord(recordName: CloudRecordType.insightPrefsRecordName),
           let snap = try? CloudRecordDecoder.prefs(from: server)
        {
            let orderDate = server.modificationDate ?? snap.updatedAt
            if orderDate > appliedPrefsAt {
                let current = readPrefs()
                if snap.morningInsightsEnabled != current.morningInsightsEnabled
                    || snap.lockScreenDetails != current.lockScreenDetails
                    || snap.insightsViaCloud != current.insightsViaCloud
                    || snap.lastRun != current.lastRun
                {
                    applyPrefs(snap)
                }
                appliedPrefsAt = orderDate
            }
        }
    }

    /// Page cap mirroring `PagePipeline.maxPages` (round-7 item 5 —
    /// SyncKit's type is internal, so the value is repeated here with
    /// the reference; drift intentionally impossible to miss).
    private static let turnPageCap = 100

    /// Every server turn, following the query cursor until nil
    /// (round-6 item 4): the old single-shot fetch pulled an arbitrary
    /// unordered fragment that varied run to run. Bounded (round-7
    /// item 5 + round-9 item 3): page cap + same-token break, mirroring
    /// PagePipeline — an echoing cursor otherwise spins to OOM,
    /// reachable from every scene activation. `deleteAllCloudData`
    /// carries the same bound on its own walk (it cannot share this
    /// one — it deletes while walking, so it needs its own counter).
    private func pullAllTurnRecords() async throws(CloudSyncError) -> [CKRecord] {
        var all: [CKRecord] = []
        var cursor: Data? = nil
        var pages = 0
        while true {
            guard pages < Self.turnPageCap else { break }
            let page = try await database.turnPage(cursor: cursor)
            all.append(contentsOf: page.records)
            pages += 1
            guard let next = page.nextCursor, next != cursor else { break }
            cursor = next
        }
        return all
    }

    /// Dedupe key shared by the pull set and the server side: role +
    /// content + fractional-second timestamp (same components as the
    /// synthetic turnID, minus readability).
    nonisolated static func turnDedupeKey(role: String, content: String, createdAt: Date) -> String {
        "\(role)|\(content)|\(createdAt.timeIntervalSince1970)"
    }

    private func pullMissingTurns() async throws(CloudSyncError) {
        let serverTurns = try await pullAllTurnRecords()
        // Round-6 item 5: dedupe against the FULL local key set, not
        // the push window's newest-500 — server turns older than the
        // window (a second device's history, or >500 arrivals between
        // syncs) re-inserted EVERY sync, growing the store without
        // bound. Cost, stated: one uncapped fetch of whole (small)
        // `ChatTurn` rows per sync — SwiftData offers no keys-only
        // fetch, so these are full rows, not projections — strictly
        // cheaper than the unbounded duplicate growth this replaces
        // (which also re-pushes later). The push window itself stays
        // capped (upload bound, unchanged).
        var seen = try localTurnKeys()
        let context = ModelContext(container)
        var inserted = false
        for record in serverTurns {
            guard let snap = try? CloudRecordDecoder.turn(from: record) else {
                continue // malformed turn: skip, never crash the sync
            }
            // Round-7 item 10: insert-into-set as you go — the pre-loop
            // snapshot alone let duplicate server records in ONE page
            // both insert (a second `ModelContext` can't catch what
            // the first hasn't saved; and turnRecordName omits content,
            // so cross-device key collisions are real).
            let key = Self.turnDedupeKey(role: snap.role, content: snap.content, createdAt: snap.createdAt)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
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

    /// Wipe step (round-6 item 1): deletes every app-owned server
    /// record, THEN resets local sync state. Order is load-bearing:
    /// server-first means a crash between leaves data deleted with
    /// stale watermarks (next sync re-pushes local state — fail-safe);
    /// watermarks-first would repull deleted data on relaunch,
    /// breaking the alert's "cannot be undone" promise.
    /// Returns the ATTEMPTED-record count for the wipe ledger
    /// (fix-round N2 — semantics stated exactly: a non-throwing
    /// delete is server-confirmed gone, and a missing record was
    /// already gone, so every counted name ends absent; but the
    /// function cannot distinguish "deleted" from "already
    /// missing", hence "cleared", not "deleted" — a throw fails
    /// the step loudly instead of short-counting).
    func deleteAllCloudData() async throws(CloudSyncError) -> Int {
        // Round-8 item 8: SAME exclusion claim as `syncNow` — a racing
        // scene-activation sync must not re-upload from the intact
        // local store mid-delete (the ledger would report cleared
        // while iCloud repopulates). Claim-or-throw: a busy engine
        // fails the wipe loudly (retry) instead of interleaving. The
        // reverse leg is `syncNow`'s own guard (a sync arriving
        // mid-wipe sees `.syncing` and returns — pinned by the
        // concurrent-sync test).
        guard status != .syncing else {
            throw CloudSyncError.wipeBlockedBySync
        }
        let priorStatus = status
        status = .syncing
        // Round-9 item 3 follow-up: restore-on-failure via `defer`,
        // not `catch { throw error }` — this toolchain types a bare
        // catch's `error` as `any Error`, which cannot rethrow through
        // the `throws(CloudSyncError)` boundary (and wrapping would
        // erase `wipeBlockedBySync` identity the parked-sync test
        // pins). Provably equivalent: restore runs iff the body
        // throws, before the original error propagates untouched.
        var succeeded = false
        defer { if !succeeded { status = priorStatus } }
        do {
            var deleted = 0
            for name in [
                CloudRecordType.settingsRecordName,
                CloudRecordType.insightPrefsRecordName,
            ] {
                try await database.deleteRecord(recordName: name)
                deleted += 1
            }
            // Round-8 item 5 + round-9 item 3: page-and-delete
            // incrementally (one page in memory, never accumulated —
            // the old shared capped walk truncated past 100 pages and
            // `resetSyncState` then resurrected the survivors
            // post-wipe). Bounded by the SAME cap as
            // `pullAllTurnRecords`: a fresh-but-unequal cursor per page
            // re-walks forever (wipe hangs, deleted-count grows), so a
            // cap-hit throws LOUDLY — never silent truncation (the
            // throw skips `resetSyncState`, watermarks intact, retry
            // resumes). Cancellation probe per page: the typed-throws
            // boundary can't surface `CancellationError`, so a cancel
            // maps to a loud retryable failure (same no-reset safety).
            var cursor: Data? = nil
            var pages = 0
            while true {
                guard !Task.isCancelled else {
                    throw CloudSyncError.failed("cloud wipe cancelled")
                }
                guard pages < Self.turnPageCap else {
                    throw CloudSyncError.failed("turn delete cursor never settled")
                }
                let page = try await database.turnPage(cursor: cursor)
                for record in page.records {
                    try await database.deleteRecord(recordName: record.recordID.recordName)
                    deleted += 1
                }
                pages += 1
                guard let next = page.nextCursor, next != cursor else { break }
                cursor = next
            }
            resetSyncState()
            succeeded = true
            return deleted
        }
    }

    /// Clears every persisted sync marker (watermarks, retry flag,
    /// last sync) after a wipe. Private to the wipe path — normal syncs
    /// advance these, never clear them.
    private func resetSyncState() {
        retryPending = false
        lastSync = nil
        seenSettingsAt = Date(timeIntervalSince1970: 0)
        seenPrefsAt = Date(timeIntervalSince1970: 0)
        appliedSettingsAt = Date(timeIntervalSince1970: 0)
        appliedPrefsAt = Date(timeIntervalSince1970: 0)
        pushedTurnsThrough = nil
        status = .synced(at: nil, pending: 0)
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

    /// Full local dedupe-key set for pull (round-6 item 5) — uncapped
    /// full-row fetch (fix-round N4: stated exactly — SwiftData offers
    /// no keys-only fetch, so these are whole `ChatTurn` rows, not
    /// projections; they are small (role/content/date) and the
    /// unbounded-duplicate growth this replaces is strictly worse).
    /// See `pullMissingTurns` for the cost reasoning.
    private func localTurnKeys() throws(CloudSyncError) -> Set<String> {
        Set(try localTurnRows(limit: nil).map {
            Self.turnDedupeKey(role: $0.role, content: $0.content, createdAt: $0.createdAt)
        })
    }

    /// Local rows, optionally capped, newest-first (`order:` spelled
    /// explicitly like every other site). Serves the pull key set —
    /// the push window moved to its own oldest-first query (round-7
    /// item 4).
    private func localTurnRows(limit: Int?) throws(CloudSyncError) -> [ChatTurn] {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<ChatTurn>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = limit
        do {
            return try context.fetch(descriptor)
        } catch {
            throw CloudSyncError.failed(error.localizedDescription)
        }
    }

    // MARK: - Retry flag + persisted state

    /// Whether a retry is owed (round-10 item 10: the `[CloudOutboxOp]`
    /// queue is gone — no op ever gated work, so the persisted shape is
    /// the honest Bool). Same defaults key (an unreadable legacy value
    /// reads back `false`, self-migrating; the flag only ever means
    /// "sync again soon").
    private var retryPending: Bool {
        get { defaults.bool(forKey: Self.outboxKey) }
        set { defaults.set(newValue, forKey: Self.outboxKey) }
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
        status = .synced(at: lastSync, pending: retryPending ? 1 : 0)
    }

    private func handle(_ error: CloudSyncError) {
        switch error {
        case .noAccount:
            status = .localOnly
        case .retryable(let message):
            retryPending = true
            status = .failed(message: "iCloud unreachable — will retry. \(message)")
        case .failed(let message):
            status = .failed(message: message)
        case .rejectedFields, .unknownRecordType, .newerSchema, .missingField:
            // Structural: retrying cannot help, and the local store is
            // untouched — surface, don't queue.
            status = .failed(message: "iCloud sync encountered unexpected data. Local data is unaffected.")
        case .wipeBlockedBySync:
            // Unreachable through `syncNow` (only the wipe throws it,
            // and the wipe surfaces it via its own ledger) — defensive
            // arm so the switch stays exhaustive without a default.
            status = .failed(message: "Wipe collided with an in-flight sync — run the wipe again.")
        }
    }
}
