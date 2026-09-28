// SyncLogEntry.swift
//
// WP-18 (implementation-plan.md): the ring-buffer log's one record shape --
// "timestamps, GoogleDataType, item counts, status, error strings." Every
// field here is either a structurally-safe type (`GoogleDataType`/
// `SyncStatus` enums, `Int`, `Date` -- none of which can carry a health
// value or a secret, since none of them is free-text derived from external
// input) or the one free-text field, `errorMessage`, which is *never*
// stored un-redacted -- see `SyncLogRedactor.swift` for why a denylist-
// pattern filter (not an allowlist) is this file's chosen defense for that
// one field, and `SyncRunRecording.swift` for the one call site that
// constructs entries in production, which always redacts before this
// initializer ever sees the message.
//
// architecture.md §4 D11: "Logs / analytics / crash reports carry counts,
// types, and timestamps -- never health values, never tokens." This type is
// the on-disk/in-memory shape that promise is checked against.

import CoreModel
import Foundation

/// One completed `SyncEngine.sync(type:)` run, as recorded by
/// `SyncRunRecording.swift`'s `SyncEngineLogRecorder`. `nonisolated` and
/// `Codable`/`Sendable`/`Equatable`, matching every other pure value type in
/// this package (`SyncOutcome`, `BackfillTypeStatus`, ...).
nonisolated public struct SyncLogEntry: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var dataType: GoogleDataType
    public var status: SyncStatus
    /// Same counting rule as `SyncOutcome.itemCount`/`SyncEngine`'s own doc
    /// comment (SyncEngine.swift) -- a count of Google data points
    /// processed, never a health value itself.
    public var itemCount: Int
    /// WP-12b: data points this run deferred to data already in Apple
    /// Health -- an Apple Watch, or since WP-55 another app's workout
    /// (`SyncOutcome.suppressedCount` -- architecture.md D13, test-plan.md
    /// §2.3's "suppressed counts appear in the sync log"). Optional, `nil`
    /// when the run suppressed nothing, **and** so pre-WP-12b `SyncLog.json`
    /// files (which lack the key entirely) still decode -- a count, never a
    /// health value, same as `itemCount`.
    public var suppressedCount: Int?
    /// WP-64: points the run skipped as implausible or incomplete
    /// (`SyncOutcome.skippedCount`). Optional for the same reasons as
    /// `suppressedCount`: `nil` when nothing was skipped, and older log
    /// files without the key still decode.
    public var skippedCount: Int?
    /// Already redacted (never the raw error text) by the time an entry
    /// reaches this initializer in production -- see this file's header and
    /// `SyncLogRedactor.swift`.
    public var errorMessage: String?

    /// "‹n› deferred to Apple Health", or `nil` when nothing was deferred:
    /// THE wording for both the Sync Log screen and its text export. "Apple
    /// Health", not "Apple Watch": since WP-55 a Hydrow row or any other
    /// app's workout can win the session too.
    public var deferredText: String? {
        guard let suppressedCount, suppressedCount > 0 else { return nil }
        return "\(suppressedCount) deferred to Apple Health"
    }

    /// "‹n› skipped", or `nil` when nothing was: the wording for the Sync
    /// Log screen and its export (WP-64).
    public var skippedText: String? {
        guard let skippedCount, skippedCount > 0 else { return nil }
        return "\(skippedCount) skipped"
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        dataType: GoogleDataType,
        status: SyncStatus,
        itemCount: Int,
        suppressedCount: Int? = nil,
        skippedCount: Int? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.dataType = dataType
        self.status = status
        self.itemCount = itemCount
        self.suppressedCount = suppressedCount
        self.skippedCount = skippedCount
        self.errorMessage = errorMessage
    }
}
