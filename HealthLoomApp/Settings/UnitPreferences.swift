// UnitPreferences.swift
//
// WP-79: the units HealthLoom shows each kind of measurement in, chosen one
// by one in Settings (kg or lb, km or mi, ...). Every stored value stays in
// its canonical unit (kilograms, metres, kilocalories, centimetres); these
// types only convert and label at display. A unit the user never picked
// follows the region (`regionDefault`), so it tracks a region change until
// the user chooses. Device-local, like the other display settings.

import Foundation
import Observation
import SwiftUI

nonisolated enum WeightUnit: String, CaseIterable, Sendable {
    case kilograms
    case pounds

    var symbol: String { self == .kilograms ? "kg" : "lb" }
    var spokenName: String { self == .kilograms ? "kilograms" : "pounds" }

    func value(kilograms: Double) -> Double {
        self == .kilograms ? kilograms : kilograms / 0.453_592_37
    }
}

nonisolated enum DistanceUnit: String, CaseIterable, Sendable {
    case kilometers
    case miles

    /// Metres in one unit.
    var meters: Double { self == .kilometers ? 1000 : 1609.344 }
    var symbol: String { self == .kilometers ? "km" : "mi" }
    var spokenName: String { self == .kilometers ? "kilometers" : "miles" }
    var speedSymbol: String { self == .kilometers ? "km/h" : "mph" }
}

/// Pool lengths: swims count metres or yards, whatever the road unit.
nonisolated enum PoolDistanceUnit: String, CaseIterable, Sendable {
    case meters
    case yards

    /// Metres in one unit.
    var meters: Double { self == .meters ? 1 : 0.9144 }
    var symbol: String { self == .meters ? "m" : "yd" }
}

nonisolated enum EnergyUnit: String, CaseIterable, Sendable {
    case kilocalories
    case kilojoules

    var symbol: String { self == .kilocalories ? "kcal" : "kJ" }
    var spokenName: String { self == .kilocalories ? "kilocalories" : "kilojoules" }

    func value(kilocalories: Double) -> Double {
        self == .kilocalories ? kilocalories : kilocalories * 4.184
    }
}

/// Running form's short lengths: stride in metres or feet, vertical
/// oscillation in centimetres or inches -- one choice for both.
nonisolated enum BodyLengthUnit: String, CaseIterable, Sendable {
    case metric
    case imperial

    var strideSymbol: String { self == .metric ? "m" : "ft" }
    var oscillationSymbol: String { self == .metric ? "cm" : "in" }

    func stride(meters: Double) -> Double { self == .metric ? meters : meters / 0.3048 }
    func oscillation(centimeters: Double) -> Double { self == .metric ? centimeters : centimeters / 2.54 }
}

/// One unit per kind of measurement.
nonisolated struct UnitPreferences: Equatable, Sendable {
    var weight: WeightUnit
    var distance: DistanceUnit
    var pool: PoolDistanceUnit
    var energy: EnergyUnit
    var bodyLength: BodyLengthUnit

    static let metric = UnitPreferences(weight: .kilograms, distance: .kilometers, pool: .meters, energy: .kilocalories, bodyLength: .metric)
    static let imperial = UnitPreferences(weight: .pounds, distance: .miles, pool: .yards, energy: .kilocalories, bodyLength: .imperial)

    /// What the region measures in: US customary, the UK's miles on
    /// metric everything else, or metric.
    static func regionDefault(for locale: Locale) -> UnitPreferences {
        switch locale.measurementSystem {
        case .us: return .imperial
        case .uk: return UnitPreferences(weight: .kilograms, distance: .miles, pool: .meters, energy: .kilocalories, bodyLength: .metric)
        default: return .metric
        }
    }
}

/// The chosen units, shared by every screen (and the coach's workout
/// answers) so a change shows everywhere at once.
@MainActor
@Observable
final class UnitSettings {
    private let defaults: UserDefaults
    private let locale: Locale
    private(set) var preferences: UnitPreferences

    init(defaults: UserDefaults = .standard, locale: Locale = .autoupdatingCurrent) {
        self.defaults = defaults
        self.locale = locale
        self.preferences = Self.load(defaults: defaults, locale: locale)
    }

    /// Chooses one kind's unit; the others keep theirs.
    func set<Unit: RawRepresentable<String>>(_ keyPath: WritableKeyPath<UnitPreferences, Unit>, to unit: Unit) {
        guard let key = Self.keys[keyPath] else { return }
        defaults.set(unit.rawValue, forKey: key)
        preferences[keyPath: keyPath] = unit
    }

    static let keys: [PartialKeyPath<UnitPreferences>: String] = [
        \UnitPreferences.weight: "units.weight",
        \UnitPreferences.distance: "units.distance",
        \UnitPreferences.pool: "units.pool",
        \UnitPreferences.energy: "units.energy",
        \UnitPreferences.bodyLength: "units.bodyLength",
    ]

    private static func load(defaults: UserDefaults, locale: Locale) -> UnitPreferences {
        let region = UnitPreferences.regionDefault(for: locale)
        func stored<Unit: RawRepresentable<String>>(_ keyPath: KeyPath<UnitPreferences, Unit>) -> Unit {
            guard let key = keys[keyPath], let raw = defaults.string(forKey: key), let unit = Unit(rawValue: raw) else {
                return region[keyPath: keyPath]
            }
            return unit
        }
        return UnitPreferences(
            weight: stored(\.weight),
            distance: stored(\.distance),
            pool: stored(\.pool),
            energy: stored(\.energy),
            bodyLength: stored(\.bodyLength)
        )
    }

    // MARK: - Settings rows (`ThemedSegmentedRow`)

    static let weightOptions: [(value: WeightUnit, title: String)] = WeightUnit.allCases.map { ($0, $0.symbol) }
    static let distanceOptions: [(value: DistanceUnit, title: String)] = DistanceUnit.allCases.map { ($0, $0.symbol) }
    static let poolOptions: [(value: PoolDistanceUnit, title: String)] = PoolDistanceUnit.allCases.map { ($0, $0.symbol) }
    static let energyOptions: [(value: EnergyUnit, title: String)] = EnergyUnit.allCases.map { ($0, $0.symbol) }
    static let bodyLengthOptions: [(value: BodyLengthUnit, title: String)] = BodyLengthUnit.allCases.map {
        ($0, "\($0.strideSymbol), \($0.oscillationSymbol)")
    }
}

extension EnvironmentValues {
    /// The chosen units, set once at the app root from `UnitSettings`;
    /// views read this rather than the store, so previews and snapshots
    /// can pin their own.
    @Entry var unitPreferences: UnitPreferences = .regionDefault(for: .current)
}
