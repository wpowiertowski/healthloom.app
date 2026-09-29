// SettingsSnapshotTests.swift
//
// WP-60/66/79: the either/or settings rows must keep its label and both segments
// legible from XS through the largest accessibility size (it stacks when
// the segmented picker no longer fits beside the label).

import SwiftUI
import SyncKit
import Testing
@testable import HealthLoom

@Suite("Settings snapshots")
struct SettingsSnapshotTests {
    @Test("sleep source row across appearance and content size")
    func sleepSourceRow() {
        let sizes: [(String, ContentSizeCategory)] = [
            ("XS", .extraSmall),
            ("AXXXL", .accessibilityExtraExtraExtraLarge),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (label, size) in sizes {
                SnapshotAssert.assert(
                    ThemedSegmentedRow(
                        title: "Sleep source", options: SleepSourcePreferences.options,
                        selection: .constant(SleepSourcePreference.fitbit), accessibilityIdentifier: "snapshot"
                    ),
                    named: "sleepSourceRow-\(scheme == .light ? "light" : "dark")-\(label)",
                    colorScheme: scheme,
                    sizeCategory: size
                )
            }
        }
    }

    // WP-66: the workout-source row, same component, its own labels -- they
    // must fit beside the title at XS and stack legibly at AXXXL.
    @Test("workout source row across appearance and content size")
    func workoutSourceRow() {
        let sizes: [(String, ContentSizeCategory)] = [
            ("XS", .extraSmall),
            ("AXXXL", .accessibilityExtraExtraExtraLarge),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (label, size) in sizes {
                SnapshotAssert.assert(
                    ThemedSegmentedRow(
                        title: "Workout source", options: WatchPriorityPreferences.options,
                        selection: .constant(true), accessibilityIdentifier: "snapshot"
                    ),
                    named: "workoutSourceRow-\(scheme == .light ? "light" : "dark")-\(label)",
                    colorScheme: scheme,
                    sizeCategory: size
                )
            }
        }
    }

    // WP-79: the Units panel -- five rows, each fitting its label beside
    // the choice at XS and stacking at AXXXL.
    @Test("units panel across appearance and content size")
    @MainActor
    func unitsPanel() {
        guard let defaults = UserDefaults(suiteName: "snapshot-units") else {
            Issue.record("no defaults suite")
            return
        }
        defaults.removePersistentDomain(forName: "snapshot-units")
        let settings = UnitSettings(defaults: defaults, locale: Locale(identifier: "de_DE"))
        settings.set(\.distance, to: .miles)
        let sizes: [(String, ContentSizeCategory)] = [
            ("XS", .extraSmall),
            ("AXXXL", .accessibilityExtraExtraExtraLarge),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (label, size) in sizes {
                SnapshotAssert.assert(
                    UnitSettingsPanel(settings: settings).padding().background(Theme.canvas),
                    named: "unitsPanel-\(scheme == .light ? "light" : "dark")-\(label)",
                    colorScheme: scheme,
                    sizeCategory: size
                )
            }
        }
        defaults.removePersistentDomain(forName: "snapshot-units")
    }
}
