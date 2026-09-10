// InsightPreferences.swift
//
// WP-34 (implementation-plan.md): UserDefaults-backed morning-insight
// preferences. Mirrors `SyncPreferences`' shape exactly — stored,
// `@Observable`-published state mirrored to `UserDefaults` (NOT computed
// properties reading defaults directly: nothing publishes a computed
// setter backed by external storage, so taps would write defaults while
// the Toggle visibly springs back). DI'd defaults (ephemeral suite in
// tests).
//
// Three independent switches, each load-bearing:
// - `morningInsightsEnabled` (default OFF): unattended generation only
//   ever runs opt-in — and enabling it is the in-context moment the
//   notification-permission request hangs off (never at launch).
// - `lockScreenDetails` (default OFF): full headline + suggestions on the
//   lock screen. OFF posts the redacted headline only.
// - `insightsViaCloud` (default OFF): the plan's separate PCC opt-in.
//   Useless without the PCC tier enabled — the router still requires
//   `catalog.isEnabled(.privateCloudCompute)` — so it can never widen
//   anything on its own.
// `lastRun` stamps the last generated morning (once-daily guard).

import Foundation
import Observation

@MainActor
@Observable
final class InsightPreferences {
    private static let enabledKey = "com.healthloom.settings.morningInsightsEnabled"
    private static let detailsKey = "com.healthloom.settings.morningInsightsLockScreenDetails"
    private static let viaCloudKey = "com.healthloom.settings.morningInsightsViaCloud"
    private static let lastRunKey = "com.healthloom.settings.morningInsightsLastRun"

    private let defaults: UserDefaults

    // Stored (not computed): `@Observable` publishes stored-property
    // mutation, so taps re-render; `didSet` mirrors to defaults.
    //
    // Init suppression (found via iCloud-sync testing): `didSet` DOES
    // fire during `init` on this toolchain despite the language rule
    // saying otherwise (the `@Observable` expansion routes init
    // assignments through the observing setter). Without the guard,
    // assigning `morningInsightsEnabled` persisted the still-default
    // `lockScreenDetails`/`insightsViaCloud`/`lastRun` OVER the stored
    // values before they were loaded — every launch silently reset all
    // three whenever insights were enabled. Proven: direct
    // `defaults.bool` true vs init-read false on the same object.
    private var suppressPersist = true
    var morningInsightsEnabled = false { didSet { persist() } }
    var lockScreenDetails = false { didSet { persist() } }
    var insightsViaCloud = false { didSet { persist() } }
    var lastRun: Date? { didSet { persist() } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.morningInsightsEnabled = defaults.bool(forKey: Self.enabledKey)
        self.lockScreenDetails = defaults.bool(forKey: Self.detailsKey)
        self.insightsViaCloud = defaults.bool(forKey: Self.viaCloudKey)
        let interval = defaults.double(forKey: Self.lastRunKey)
        self.lastRun = interval > 0 ? Date(timeIntervalSince1970: interval) : nil
        suppressPersist = false
    }

    private func persist() {
        guard !suppressPersist else { return }
        defaults.set(morningInsightsEnabled, forKey: Self.enabledKey)
        defaults.set(lockScreenDetails, forKey: Self.detailsKey)
        defaults.set(insightsViaCloud, forKey: Self.viaCloudKey)
        defaults.set(lastRun?.timeIntervalSince1970 ?? 0, forKey: Self.lastRunKey)
    }

    /// Re-reads every field from defaults. Called at the top of
    /// `MorningInsightRunner.runIfDue` (F1): Settings owns a *different*
    /// instance than the runner, and the runner's copy lives for days —
    /// without this, an enable-toggle would read as `.disabled` until
    /// force-quit. Defaults stay the single source; instances are views.
    /// Round-6 item 2: `suppressPersist` guards the whole read — the
    /// same toolchain hazard `init` documents. Without it, assigning
    /// `morningInsightsEnabled` fires `didSet→persist()`, writing the
    /// STALE in-memory details/viaCloud/lastRun OVER the stored values
    /// before they are read back (only `morningInsightsEnabled` ever
    /// actually reloaded — concretely broke lock-screen redaction and
    /// duped insights after cloud pulls).
    func reload() {
        suppressPersist = true
        defer { suppressPersist = false }
        morningInsightsEnabled = defaults.bool(forKey: Self.enabledKey)
        lockScreenDetails = defaults.bool(forKey: Self.detailsKey)
        insightsViaCloud = defaults.bool(forKey: Self.viaCloudKey)
        let interval = defaults.double(forKey: Self.lastRunKey)
        lastRun = interval > 0 ? Date(timeIntervalSince1970: interval) : nil
    }

}
