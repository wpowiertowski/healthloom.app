// DiagnosticsLog.swift
//
// WP-18 (implementation-plan.md): "Add os.Logger categories mirroring the
// same redaction rule (never log health values or secrets) -- one category
// per subsystem (sync, backfill, background, auth) is reasonable."
//
// **Consistency check performed before adding these (per the brief's own
// instruction to check for and not duplicate WP-16's existing usage):**
// `HealthLoomApp.swift`'s `HealthLoomBackgroundSync` enum already declares
// `Logger(subsystem: "app.healthloom", category: "BackgroundSync")` --
// that file is fenced off (WP-16's territory) and its `logger` constant is
// `private`, so it can't literally be shared/imported from this package
// (different module entirely; SyncKit is compiled and linked independently
// of the app target). `.background` below reuses the *exact same subsystem
// string and category name* so log output from both call sites groups
// together under one category in Console.app/`log show`, rather than
// fragmenting into two near-identical categories -- the closest thing to
// "reuse, don't duplicate" achievable across a package/app-target boundary.
// This WP does not add a call site for `.background` itself (background-
// sync logging is already covered by WP-16's own lines); it's declared here
// only so any future SyncKit code that needs to log a background-sync-
// adjacent event has the identically-named category ready, rather than
// inventing a third variant spelling later.
//
// `.backfill` and `.auth` are declared for the same forward-consistency
// reason but, per this WP's scope fence (`Backfill/` read-only,
// `GoogleHealthClient` read-only), have no call site added in this
// session -- see progress.md's WP-18 entry for why backfill-chunk logging
// specifically was not wired in here.
//
// Every category shares one subsystem, `"app.healthloom"` -- the app's
// own bundle ID (matching WP-16's exact string), not a SyncKit-specific
// identifier, so every log line from this app (regardless of which module
// emitted it) groups under one subsystem in Console.app.
import Foundation
import os

/// Namespace for this app's `os.Logger` categories (WP-18). Every logger
/// here is intended to be used only with `.public`-privacy interpolations of
/// already-safe or already-redacted values -- see `SyncRunRecording.swift`'s
/// `emit(_:)` for the one real call site this WP adds, and architecture.md
/// §4 D11 for the posture every one of these must honor: counts, types, and
/// timestamps, never health values, never tokens.
nonisolated public enum DiagnosticsLog {
    /// Per-type incremental sync run completions (`SyncEngine.sync(type:)`
    /// via `SyncEngineLogRecorder`, this WP's own hook).
    public static let sync = Logger(subsystem: "app.healthloom", category: "Sync")
    /// Reserved for historical-backfill chunk events (WP-15's
    /// `BackfillCoordinator`) -- no call site in this WP; see this file's
    /// header.
    public static let backfill = Logger(subsystem: "app.healthloom", category: "Backfill")
    /// Matches `HealthLoomApp.swift`'s existing `BackgroundSync` category name
    /// exactly (see this file's header) -- reserved here for any future
    /// SyncKit-side background-sync logging; WP-16's own app-target logger
    /// remains the active emitter for that category today.
    public static let background = Logger(subsystem: "app.healthloom", category: "BackgroundSync")
    /// Reserved for `GoogleAuthManager`/consent-flow events
    /// (GoogleHealthClient) -- no call site added in this WP (that package
    /// is read-only per this WP's scope fence); declared for the same
    /// forward-consistency reason as `.backfill`.
    public static let auth = Logger(subsystem: "app.healthloom", category: "Auth")
}
