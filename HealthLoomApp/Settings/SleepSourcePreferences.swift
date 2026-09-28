// SleepSourcePreferences.swift
//
// WP-60: the Settings side of `SleepSourcePreference` (SyncKit/Conflict/
// SleepSource.swift) -- which device's sleep wins a night both recorded.
// Same shape as `WatchPriorityPreferences`: the key and the default live
// with the rule in SyncKit, so this picker and every sleep reader share
// one definition. Device-local: iCloud's settings record doesn't carry it.

import Foundation
import Observation
import SwiftUI
import SyncKit

@MainActor
@Observable
final class SleepSourcePreferences {
    private let defaults: UserDefaults
    private(set) var source: SleepSourcePreference

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.source = SleepSourcePreference.current(defaults: defaults)
    }

    func setSource(_ source: SleepSourcePreference) {
        defaults.set(source.rawValue, forKey: SleepSourcePreference.defaultsKey)
        self.source = source
    }

    /// Picker label for each source.
    static func label(for source: SleepSourcePreference) -> String {
        switch source {
        case .fitbit: "Fitbit"
        case .appleWatch: "Apple Watch"
        }
    }
}

/// The Settings row: label plus a Fitbit / Apple Watch segmented picker,
/// side by side when they fit and stacked at large text sizes.
struct SleepSourceRow: View {
    @Binding var source: SleepSourcePreference

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                label
                Spacer(minLength: 8)
                picker
            }
            VStack(alignment: .leading, spacing: 8) {
                label
                picker
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private var label: some View {
        Text("Sleep source")
            .font(Theme.font(Theme.Step.body, .medium, relativeTo: .subheadline))
            .foregroundStyle(Theme.ink)
    }

    private var picker: some View {
        ThemedSegmentedControl(
            options: SleepSourcePreference.allCases.map { ($0, SleepSourcePreferences.label(for: $0)) },
            selection: $source,
            accessibilityIdentifier: "settings.sleepSource.picker"
        )
        .accessibilityLabel("Sleep source")
    }
}
