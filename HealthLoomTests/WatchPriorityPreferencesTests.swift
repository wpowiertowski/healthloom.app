// WatchPriorityPreferencesTests.swift
//
// WP-12b (implementation-plan.md) step 4 / architecture.md D13.5: the
// "Prefer Apple Watch during workouts" preference -- default ON when never
// set, round-trips through `UserDefaults`, and stays in lockstep with the
// SyncKit-side reader (`UserDefaultsWatchPriorityPreference`) the sync
// pipelines' resolver consults, since both sides use the same key by
// construction. Bound `EphemeralDefaults` holder per test (round-2 item
// 14, uniform with every other suite site) -- never touches `.standard`.

import Foundation
import SyncKit
import Testing
@testable import HealthLoom

@Suite("WatchPriorityPreferences")
struct WatchPriorityPreferencesTests {
    private func makeDefaults() throws -> EphemeralDefaults {
        try EphemeralDefaults(prefix: "watchpriority")
    }

    @Test func defaultsToOnWhenNeverSet() async throws {
        let ephemeral1 = try makeDefaults()
        let defaults = ephemeral1.defaults

        #expect(WatchPriorityPreferences(defaults: defaults).isEnabled)
        #expect(UserDefaultsWatchPriorityPreference(defaults: defaults).isWatchPriorityEnabled())
    }

    @Test func turningOffPersistsAndIsSeenByTheSyncKitReader() async throws {
        let ephemeral2 = try makeDefaults()
        let defaults = ephemeral2.defaults
        let preferences = WatchPriorityPreferences(defaults: defaults)

        preferences.setEnabled(false)

        #expect(!preferences.isEnabled)
        // The exact reader the sync pipelines' WatchConflictResolver
        // consults at the start of every run (D13.5's OFF = identity).
        #expect(!UserDefaultsWatchPriorityPreference(defaults: defaults).isWatchPriorityEnabled())
        // A fresh UI-side instance re-reads the stored value.
        #expect(!WatchPriorityPreferences(defaults: defaults).isEnabled)
    }

    @Test func turningBackOnPersists() async throws {
        let ephemeral3 = try makeDefaults()
        let defaults = ephemeral3.defaults
        let preferences = WatchPriorityPreferences(defaults: defaults)

        preferences.setEnabled(false)
        preferences.setEnabled(true)

        #expect(preferences.isEnabled)
        #expect(UserDefaultsWatchPriorityPreference(defaults: defaults).isWatchPriorityEnabled())
    }
}
