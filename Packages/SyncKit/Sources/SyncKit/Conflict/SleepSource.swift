// SleepSource.swift
//
// WP-60: which device's sleep counts when more than one recorded the same
// night. HealthLoom writes the Fitbit's nights into Apple Health and an
// Apple Watch writes its own, so a night both recorded has two sets of
// stages -- merging them (the WP-57 union) counted one device's awake
// stretch as sleep whenever the other called it asleep. Now one source
// wins each night, like Health.app's source priority: the preferred device
// when it recorded the night, else the other device, else any other app.
// Nights only one source recorded are unaffected.
//
// Read side only. The sync still writes every Fitbit night to Apple
// Health; this decides what Today, readiness, the Data tab and the coach
// read back. The preference key lives here, beside the rule, so the app's
// Settings picker and every reader share one definition.

import Foundation
#if canImport(HealthKit)
import HealthKit
#endif

/// The device whose sleep wins a night both recorded. Fitbit by default:
/// the wear model this app is built around has the Fitbit on at night.
nonisolated public enum SleepSourcePreference: String, CaseIterable, Sendable {
    case fitbit
    case appleWatch

    public static let defaultsKey = "com.healthloom.settings.sleepSource"
    public static let defaultValue = SleepSourcePreference.fitbit

    /// The stored preference; unset or unreadable is `defaultValue`.
    public static func current(defaults: UserDefaults = .standard) -> SleepSourcePreference {
        defaults.string(forKey: defaultsKey).flatMap(SleepSourcePreference.init(rawValue:)) ?? defaultValue
    }

    /// Sources in the order they win a night.
    public var priority: [SleepOrigin] {
        switch self {
        case .fitbit: [.fitbit, .appleWatch, .otherApp]
        case .appleWatch: [.appleWatch, .fitbit, .otherApp]
        }
    }
}

/// Where a sleep sample came from.
nonisolated public enum SleepOrigin: Sendable, Hashable {
    /// Imported by HealthLoom from the Google (Fitbit) feed.
    case fitbit
    case appleWatch
    /// Any other app that saves sleep (a ring, a bed sensor, a sleep app).
    case otherApp
}

nonisolated public enum SleepSourceSelection {
    /// The night a sleep sample belongs to: the calendar day it starts in,
    /// shifted 12 h back, so 11 pm and 2 am land on the same night.
    public static func night(of start: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: start.addingTimeInterval(-12 * 3600))
    }

    /// One night's samples from the highest-priority source that recorded
    /// any asleep time that night; every other source's samples are
    /// dropped. A source with only in-bed or awake samples doesn't win.
    public static func winningSource<Sample>(
        of night: [Sample],
        preference: SleepSourcePreference,
        origin: (Sample) -> SleepOrigin,
        isAsleep: (Sample) -> Bool
    ) -> [Sample] {
        guard let winner = preference.priority.first(where: { candidate in
            night.contains { origin($0) == candidate && isAsleep($0) }
        }) else { return [] }
        return night.filter { origin($0) == winner }
    }

    /// `winningSource` applied night by night across a longer range.
    public static func winningSources<Sample>(
        of samples: [Sample],
        preference: SleepSourcePreference,
        calendar: Calendar,
        start: (Sample) -> Date,
        origin: (Sample) -> SleepOrigin,
        isAsleep: (Sample) -> Bool
    ) -> [Sample] {
        let nights = Dictionary(grouping: samples) { night(of: start($0), calendar: calendar) }
        return nights.keys.sorted().flatMap { key in
            winningSource(of: nights[key] ?? [], preference: preference, origin: origin, isAsleep: isAsleep)
        }
    }

    #if canImport(HealthKit)
    /// A HealthKit sample's origin: HealthLoom's own imports carry its
    /// external-ID stamp; otherwise the watch rule the conflict resolver
    /// uses decides.
    public static func origin(of sample: HKSample) -> SleepOrigin {
        if sample.metadata?[MappedMetadata.externalIDKey] != nil { return .fitbit }
        return ProductTypeWorkoutSourceClassifier.isAppleWatch(sample) ? .appleWatch : .otherApp
    }
    #endif
}
