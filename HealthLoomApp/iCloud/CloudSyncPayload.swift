// CloudSyncPayload.swift
//
// iCloud sync (private DB only): app-owned snapshots + the allowlisted
// record encoder. Scope lock (owner directive): settings, insight
// preferences, coach history. NEVER HealthKit-sourced values.
//
// PRIVACY INVARIANT (structural, not conventional): every snapshot below
// is a struct of String/Bool/Int/Double/Date — there is no field, and no
// initializer parameter, typed (or keyed) for HealthKit, HealthKitUI,
// CoreModel sample, or Google-data-point values. A HealthKit payload
// cannot be constructed here; it does not compile. The runtime backstop
// is `validatedFields`: the encoder rejects any field outside the per-
// record allowlist, so even a future caller smuggling an `hk*` key fails
// loudly instead of syncing. Both halves are pinned in CloudSyncTests
// (allowlist rejection + a source grep-test over this directory).

import CloudKit
import Foundation

/// Schema version stamped on every record (`v`). Bump when a record's
/// field set changes; the decoder ignores records from a newer schema it
/// does not understand (forward-safety across app versions).
nonisolated enum CloudSchema {
    static let version = 1
}

/// Single record in the private default zone holding sync-settings state.
nonisolated struct SyncSettingsSnapshot: Sendable, Equatable {
    /// Raw `GoogleDataType` values the user disabled. Raw strings, not
    /// `GoogleDataType` cases: the snapshot must decode even if a future
    /// app version renames a case (unknown values are preserved
    /// verbatim, never dropped).
    var disabledTypeRawValues: [String]
    var preferAppleWatch: Bool
    var updatedAt: Date
}

/// Single record holding morning-insight preference state.
nonisolated struct InsightPrefsSnapshot: Sendable, Equatable {
    var morningInsightsEnabled: Bool
    var lockScreenDetails: Bool
    var insightsViaCloud: Bool
    var lastRun: Date?
    var updatedAt: Date
}

/// One record per coach turn. Turns are append-only and immutable — once
/// written, a turn record is never updated, so turns need no conflict
/// resolution by construction (the engine saves-if-absent and skips
/// existing records).
nonisolated struct CoachTurnSnapshot: Sendable, Equatable {
    var turnID: String
    var role: String
    var content: String
    var createdAt: Date
}

/// Record-type names in the private database's default zone. A custom zone
/// is deliberately NOT used: zones must be created before first use (an
/// extra failure mode), and nothing here needs atomic multi-record saves.
nonisolated enum CloudRecordType {
    static let settings = "SyncSettings"
    static let insightPrefs = "InsightPrefs"
    static let coachTurn = "CoachTurn"

    /// Well-known record names for the two singletons.
    static let settingsRecordName = "app-settings"
    static let insightPrefsRecordName = "app-insight-prefs"

    static func turnRecordName(for turnID: String) -> String {
        "turn-\(turnID)"
    }
}

/// Per-record field allowlists. The encoder writes ONLY these keys; the
/// decoder (and `validatedFields`) rejects anything else.
nonisolated enum CloudRecordFields {
    static let settings: Set<String> = ["v", "disabledTypes", "preferWatch", "updatedAt"]
    static let insightPrefs: Set<String> = ["v", "enabled", "lockDetails", "viaCloud", "lastRun", "updatedAt"]
    static let coachTurn: Set<String> = ["v", "turnID", "role", "content", "createdAt"]

    static func allowlist(for recordType: String) -> Set<String>? {
        switch recordType {
        case CloudRecordType.settings: settings
        case CloudRecordType.insightPrefs: insightPrefs
        case CloudRecordType.coachTurn: coachTurn
        default: nil
        }
    }

    /// Throws on any field outside the record type's allowlist — the
    /// runtime half of the privacy invariant (a HealthKit-shaped key can
    /// never be encoded, even by a future caller).
    static func validatedFields(_ fields: [String: CKRecordValue], for recordType: String) throws(CloudSyncError) {
        guard let allowed = allowlist(for: recordType) else {
            throw CloudSyncError.unknownRecordType(recordType)
        }
        let unknown = Set(fields.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw CloudSyncError.rejectedFields(recordType: recordType, keys: unknown.sorted())
        }
    }
}

/// Engine-facing errors. `CKError` never escapes the live database
/// adapter: it maps into this enum so the engine (and its tests) reason
/// about retryability without CloudKit.
nonisolated enum CloudSyncError: Error, Equatable, Sendable {
    /// No iCloud account / parental restriction — local-only, SILENT (no
    /// error UI; the user did nothing wrong).
    case noAccount
    /// Transient (offline, throttled, service wobble) — queue in the
    /// outbox, retry later. Surfaced as "will retry", never as failure.
    case retryable(String)
    /// Anything else — surfaced in Settings with the message.
    case failed(String)
    /// Encoder/decoder structure violations (never user-facing as-is).
    case rejectedFields(recordType: String, keys: [String])
    case unknownRecordType(String)
    case newerSchema(version: Int)
    case missingField(String)
}

/// Builds `CKRecord`s from app-owned snapshots and back. Bools travel as
/// `Int64` (0/1): `CKRecordValue` has no Bool, and `NSNumber(boolean:)`
/// vs `numberWithLongLong` round-trip ambiguity has bitten before.
nonisolated enum CloudRecordBuilder {
    static func record(for settings: SyncSettingsSnapshot) throws(CloudSyncError) -> CKRecord {
        let id = CKRecord.ID(recordName: CloudRecordType.settingsRecordName)
        let record = CKRecord(recordType: CloudRecordType.settings, recordID: id)
        let fields: [String: CKRecordValue] = [
            "v": CloudSchema.version as CKRecordValue,
            "disabledTypes": settings.disabledTypeRawValues as CKRecordValue,
            "preferWatch": (settings.preferAppleWatch ? 1 : 0) as CKRecordValue,
            "updatedAt": settings.updatedAt as CKRecordValue,
        ]
        try CloudRecordFields.validatedFields(fields, for: CloudRecordType.settings)
        for (key, value) in fields { record[key] = value }
        return record
    }

    static func record(for prefs: InsightPrefsSnapshot) throws(CloudSyncError) -> CKRecord {
        let id = CKRecord.ID(recordName: CloudRecordType.insightPrefsRecordName)
        let record = CKRecord(recordType: CloudRecordType.insightPrefs, recordID: id)
        var fields: [String: CKRecordValue] = [
            "v": CloudSchema.version as CKRecordValue,
            "enabled": (prefs.morningInsightsEnabled ? 1 : 0) as CKRecordValue,
            "lockDetails": (prefs.lockScreenDetails ? 1 : 0) as CKRecordValue,
            "viaCloud": (prefs.insightsViaCloud ? 1 : 0) as CKRecordValue,
            "updatedAt": prefs.updatedAt as CKRecordValue,
        ]
        if let lastRun = prefs.lastRun {
            fields["lastRun"] = lastRun as CKRecordValue
        }
        try CloudRecordFields.validatedFields(fields, for: CloudRecordType.insightPrefs)
        for (key, value) in fields { record[key] = value }
        return record
    }

    static func record(for turn: CoachTurnSnapshot) throws(CloudSyncError) -> CKRecord {
        let id = CKRecord.ID(recordName: CloudRecordType.turnRecordName(for: turn.turnID))
        let record = CKRecord(recordType: CloudRecordType.coachTurn, recordID: id)
        let fields: [String: CKRecordValue] = [
            "v": CloudSchema.version as CKRecordValue,
            "turnID": turn.turnID as CKRecordValue,
            "role": turn.role as CKRecordValue,
            "content": turn.content as CKRecordValue,
            "createdAt": turn.createdAt as CKRecordValue,
        ]
        try CloudRecordFields.validatedFields(fields, for: CloudRecordType.coachTurn)
        for (key, value) in fields { record[key] = value }
        return record
    }
}

/// Decodes records back into snapshots. Newer-schema records throw
/// (skipped by the engine, never applied); missing fields throw (a
/// partially-written record must not silently zero preferences).
nonisolated enum CloudRecordDecoder {
    static func settings(from record: CKRecord) throws -> SyncSettingsSnapshot {
        try checkVersion(record)
        return SyncSettingsSnapshot(
            disabledTypeRawValues: try strings(record, key: "disabledTypes"),
            preferAppleWatch: try flag(record, key: "preferWatch"),
            updatedAt: try date(record, key: "updatedAt")
        )
    }

    static func prefs(from record: CKRecord) throws -> InsightPrefsSnapshot {
        try checkVersion(record)
        return InsightPrefsSnapshot(
            morningInsightsEnabled: try flag(record, key: "enabled"),
            lockScreenDetails: try flag(record, key: "lockDetails"),
            insightsViaCloud: try flag(record, key: "viaCloud"),
            lastRun: record["lastRun"] as? Date,
            updatedAt: try date(record, key: "updatedAt")
        )
    }

    static func turn(from record: CKRecord) throws -> CoachTurnSnapshot {
        try checkVersion(record)
        guard let turnID = record["turnID"] as? String,
              let role = record["role"] as? String,
              let content = record["content"] as? String,
              let createdAt = record["createdAt"] as? Date
        else {
            throw CloudSyncError.missingField("turnID/role/content/createdAt")
        }
        return CoachTurnSnapshot(turnID: turnID, role: role, content: content, createdAt: createdAt)
    }

    private static func checkVersion(_ record: CKRecord) throws {
        let version = (record["v"] as? NSNumber)?.intValue ?? 0
        if version > CloudSchema.version {
            throw CloudSyncError.newerSchema(version: version)
        }
    }

    private static func strings(_ record: CKRecord, key: String) throws -> [String] {
        guard let value = record[key] as? [String] else {
            throw CloudSyncError.missingField(key)
        }
        return value
    }

    private static func flag(_ record: CKRecord, key: String) throws -> Bool {
        guard let value = record[key] as? NSNumber else {
            throw CloudSyncError.missingField(key)
        }
        return value.intValue != 0
    }

    private static func date(_ record: CKRecord, key: String) throws -> Date {
        guard let value = record[key] as? Date else {
            throw CloudSyncError.missingField(key)
        }
        return value
    }
}
