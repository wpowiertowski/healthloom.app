// SleepSourcePreferences.swift
//
// WP-60: the Settings side of `SleepSourcePreference` (SyncKit/Conflict/
// SleepSource.swift) -- which device's sleep wins a night both recorded.
// Same shape as `WatchPriorityPreferences`: the key and the default live
// with the rule in SyncKit, so this picker and every sleep reader share
// one definition. Device-local: iCloud's settings record doesn't carry it.

import Foundation
import Observation
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

    /// The Settings row's options (`ThemedSegmentedRow`).
    static let options: [(value: SleepSourcePreference, title: String)] = SleepSourcePreference.allCases.map { source in
        switch source {
        case .fitbit: (source, "Fitbit")
        case .appleWatch: (source, "Apple Watch")
        }
    }
}

