// SyncRunRecording.swift
//
// WP-18 (implementation-plan.md): the protocol seam for the one hook this WP
// adds to `SyncEngine.swift` -- see that file's own doc comment on the
// `runRecorder` parameter for the "why here, why optional, why this shape"
// writeup. This file defines the protocol itself plus the one production
// conformer, `SyncEngineLogRecorder`, which turns a `SyncOutcome`
// (SyncEngine/SyncEngineTypes.swift, WP-09 -- already carries exactly
// `dataType`/`status`/`itemCount`/`errorMessage`, nothing more, nothing
// health-shaped) into a redacted `SyncLogEntry` and appends it to a
// `SyncLogStore`.
//
// `nonisolated`, mirroring every other protocol seam in this package
// (`GoogleReconcileClient`, `ConflictFiltering`, `BackfillBusyProbe`) so a
// conformer's own actor affinity never blocks satisfying the requirement.
import Foundation

/// Notified once per completed `SyncEngine.sync(type:)` run (success *or*
/// failure) with that run's `SyncOutcome`. `SyncEngine`'s own `runRecorder`
/// property (SyncEngine.swift) is `(any SyncRunRecording)?`, defaulting to
/// `nil` -- every existing/test call site that doesn't pass one sees no
/// behavior change at all.
nonisolated public protocol SyncRunRecording: Sendable {
    nonisolated func record(_ outcome: SyncOutcome) async
}

/// Production conformer: builds one `SyncLogEntry` per outcome (timestamp
/// from an injected `SyncClock`, exactly like `SyncEngine`'s own window math
/// -- never a direct `Date()` call, so this stays testable against a
/// virtual clock too) and appends it to `store`. `errorMessage` is passed
/// through `SyncLogRedactor.redact(_:)` before it ever reaches
/// `SyncLogEntry`'s initializer -- see that file's header for the
/// denylist-vs-allowlist rationale.
nonisolated public struct SyncEngineLogRecorder: SyncRunRecording {
    private let store: SyncLogStore
    private let clock: any SyncClock

    public init(store: SyncLogStore, clock: any SyncClock = SystemSyncClock()) {
        self.store = store
        self.clock = clock
    }

    public func record(_ outcome: SyncOutcome) async {
        let entry = SyncLogEntry(
            timestamp: clock.now(),
            dataType: outcome.dataType,
            status: outcome.status,
            itemCount: outcome.itemCount,
            // WP-12b: nil (key absent) when nothing was deferred, so
            // pre-existing entries and runs without watch conflicts render
            // identically to before.
            suppressedCount: outcome.suppressedCount > 0 ? outcome.suppressedCount : nil,
            errorMessage: outcome.errorMessage.map(SyncLogRedactor.redact)
        )
        await store.append(entry)
        Self.emit(entry)
    }

    /// Mirrors the entry into `os.Logger` (WP-18's other required
    /// deliverable -- "Add os.Logger categories with the same redaction
    /// rule"). `entry` is already fully redacted by the time this runs (the
    /// line above), so every interpolated field here is `.public` -- none of
    /// them can carry a health value or a secret (architecture.md D11):
    /// `dataType`/`status` are enum raw values, `itemCount` is a count, and
    /// `errorMessage` has already been through `SyncLogRedactor`.
    private static func emit(_ entry: SyncLogEntry) {
        let logger = DiagnosticsLog.sync
        switch entry.status {
        case .ok:
            logger.log(
                "Sync ok for \(entry.dataType.rawValue, privacy: .public): \(entry.itemCount, privacy: .public) item(s)"
            )
        case .error:
            logger.error(
                "Sync error for \(entry.dataType.rawValue, privacy: .public): \(entry.errorMessage ?? "unknown", privacy: .public)"
            )
        case .cancelled:
            // A stop, not a failure: default level, never `.error` (which
            // would page/flag in log triage for the system winding us down).
            logger.log(
                "Sync cancelled for \(entry.dataType.rawValue, privacy: .public): will retry next run"
            )
        }
    }
}
