// WatchPriorityPreferences.swift
//
// WP-12b (implementation-plan.md) step 4 / architecture.md D13.5: the
// UI-facing side of the "Prefer Apple Watch during workouts" toggle.
// Mirrors `SyncPreferences`' shape exactly (UserDefaults-backed,
// `@Observable`/`@MainActor`, DI'd defaults for tests) -- see that file's
// header for the conventions this follows.
//
// The stored key is `UserDefaultsWatchPriorityPreference.defaultsKey`
// (SyncKit/Conflict/WatchPriorityPreference.swift) -- the exact key the sync
// pipelines' `WatchConflictResolver` reads at the start of every run, so
// this toggle and the resolver can never drift onto different keys. Reads
// route through that same SyncKit conformer too, so "unset means ON"
// (D13.5's default) is decided in exactly one place.

import Foundation
import Observation
import SyncKit

@MainActor
@Observable
final class WatchPriorityPreferences {
    private let defaults: UserDefaults
    private(set) var isEnabled: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = UserDefaultsWatchPriorityPreference(defaults: defaults).isWatchPriorityEnabled()
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: UserDefaultsWatchPriorityPreference.defaultsKey)
        isEnabled = enabled
    }

    /// Re-reads the toggle from defaults (round-6 item 10): the cloud
    /// pull applies server state through the ENGINE's owner instances —
    /// without this, this screen's instance stays stale after a pull
    /// and its next write-back clobbers the pulled value. Called from
    /// the `.cloudSyncDidApply` handler alongside the other reloads.
    func reload() {
        isEnabled = UserDefaultsWatchPriorityPreference(defaults: defaults).isWatchPriorityEnabled()
    }
}
