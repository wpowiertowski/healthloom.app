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
    // mutation, so taps re-render; `didSet` mirrors to defaults. Property
    // observers do not fire during `init`, so loading here never writes.
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
    }

    private func persist() {
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
    func reload() {
        morningInsightsEnabled = defaults.bool(forKey: Self.enabledKey)
        lockScreenDetails = defaults.bool(forKey: Self.detailsKey)
        insightsViaCloud = defaults.bool(forKey: Self.viaCloudKey)
        let interval = defaults.double(forKey: Self.lastRunKey)
        lastRun = interval > 0 ? Date(timeIntervalSince1970: interval) : nil
    }

}
