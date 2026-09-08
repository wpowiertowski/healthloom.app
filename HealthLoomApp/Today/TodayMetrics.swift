// TodayMetrics.swift
//
// WP-33 (implementation-plan.md) steps 1-2: the Today view's metric
// vocabulary -- which metrics exist, how their raw HealthKit readings
// format into the instrument panel's value/sub strings, and the
// user-editable order/visibility (persisted in `UserDefaults`, per WP-33
// step 2 / architecture.md D12's "order persists in UserDefaults").
// Everything in this file is pure and HealthKit-free so
// `TodayMetricPreferencesTests`/`TodayMetricFormattingTests`
// (HealthLoomTests) can drive it directly; `TodayMetricsProvider.swift` is
// the one HealthKit-touching piece that produces the raw readings.

import CoreModel
import Foundation
import Observation
// SwiftUI (not Foundation) exports `MutableCollection.move(fromOffsets:
// toOffset:)`, which `TodayMetricPreferences.move` forwards to.
import SwiftUI

/// The full metric list the user can add/remove from the Today panel
/// (WP-33 step 2: "add/remove metrics from the full synced-type list" --
/// this is the subset of synced types that has a meaningful *today* reading
/// and a HealthKit query the app can run; `LocalSample`-only types render
/// on the Data tab instead).
/// Shorthand for the reorderable-content difference over Today kinds.
typealias TodayReorderDestination = ReorderDifference<
    TodayMetricKind, ReorderableSingleCollectionIdentifier
>.Destination.Position

/// `Sendable`: the kind serves as `TodayMetricDisplay.id`, and iOS 27's
/// `reorderContainer` requires `Item.ID: Sendable`.
enum TodayMetricKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case heart
    case steps
    case sleep
    case bloodOxygen
    case weight
    case distance
    case activeEnergy

    var id: String { rawValue }

    /// The mockup's default four rows, in its order (heart / steps / sleep /
    /// blood oxygen).
    static let defaultVisible: [TodayMetricKind] = [.heart, .steps, .sleep, .bloodOxygen]

    var displayName: String {
        switch self {
        case .heart: return "Heart"
        case .steps: return "Steps"
        case .sleep: return "Sleep"
        case .bloodOxygen: return "Blood oxygen"
        case .weight: return "Weight"
        case .distance: return "Distance"
        case .activeEnergy: return "Active energy"
        }
    }

    /// The mockup marks Heart with the rust priority bar; kept as a fixed
    /// per-kind attribute (the design shows exactly one priority row).
    var isPriority: Bool { self == .heart }
}

/// One raw reading from HealthKit -- value in the kind's canonical unit
/// (bpm, count, seconds asleep, fraction 0-1, kg, meters, kcal) plus the
/// reading's own timestamp where meaningful.
struct TodayMetricReading: Equatable {
    var value: Double
    var date: Date?
}

/// One rendered instrument-panel row (the mockup's `Metric` model, bound to
/// real data instead of sample literals). `value == nil` renders the
/// "No data yet" empty row (WP-33 step 4's pre-first-sync state).
struct TodayMetricDisplay: Identifiable, Equatable {
    let kind: TodayMetricKind
    let sub: String
    let value: String?
    let unit: String?
    let progress: Double?

    var id: TodayMetricKind { kind }
    var name: String { kind.displayName }
    var isPriority: Bool { kind.isPriority }

    /// VoiceOver line for the whole row (D12 deviation (c): "all rows get
    /// VoiceOver labels" -- e.g. "Heart, 62 beats per minute, latest
    /// reading").
    var accessibilityText: String {
        guard let value else { return "\(name), no data yet" }
        let spokenUnit: String
        switch kind {
        case .heart: spokenUnit = "beats per minute"
        case .bloodOxygen: spokenUnit = "percent"
        case .weight: spokenUnit = "kilograms"
        case .distance: spokenUnit = "kilometers"
        case .activeEnergy: spokenUnit = "kilocalories"
        case .steps, .sleep: spokenUnit = ""
        }
        let unitPart = spokenUnit.isEmpty ? "" : " \(spokenUnit)"
        return "\(name), \(value)\(unitPart), \(sub)"
    }
}

// MARK: - Formatting (pure -- unit-tested)

enum TodayMetricFormatter {
    /// Default daily step goal for the progress bar + "% of goal" sub line.
    /// No goal-setting UI exists yet (a later WP's job); this constant is
    /// the one place to wire one in.
    static let defaultStepGoal = 10_000.0

    /// Grouped integer -- "8,240" (in the user's locale; tests inject a
    /// fixed one for deterministic assertions). Delegates to CoreModel's
    /// shared `MetricFormatting` (same helper CoachKit uses) so fixes land
    /// once; the negative-input clamp below arrived through that path.
    static func groupedCount(_ value: Double, locale: Locale = .current) -> String {
        MetricFormatting.groupedCount(value, locale: locale)
    }

    /// "7h 12m" from seconds; sub-hour durations render "42m".
    static func duration(seconds: Double) -> String {
        MetricFormatting.duration(seconds: seconds)
    }

    /// Build the display row for one kind from its (optional) raw reading.
    static func display(kind: TodayMetricKind, reading: TodayMetricReading?, locale: Locale = .current) -> TodayMetricDisplay {
        guard let reading else {
            return TodayMetricDisplay(kind: kind, sub: "No data yet", value: nil, unit: nil, progress: nil)
        }
        switch kind {
        case .heart:
            return TodayMetricDisplay(
                kind: kind,
                sub: timestampSub(reading.date, prefix: "Latest"),
                value: groupedCount(reading.value, locale: locale),
                unit: "bpm",
                progress: nil
            )
        case .steps:
            let fraction = min(reading.value / defaultStepGoal, 1)
            let percent = Int((reading.value / defaultStepGoal * 100).rounded())
            return TodayMetricDisplay(
                kind: kind,
                sub: "\(percent)% of \(groupedCount(defaultStepGoal, locale: locale)) goal",
                value: groupedCount(reading.value, locale: locale),
                unit: nil,
                progress: fraction
            )
        case .sleep:
            return TodayMetricDisplay(
                kind: kind,
                sub: "Last night",
                value: duration(seconds: reading.value),
                unit: nil,
                progress: nil
            )
        case .bloodOxygen:
            // Canonical reading is HealthKit's 0...1 fraction.
            return TodayMetricDisplay(
                kind: kind,
                sub: timestampSub(reading.date, prefix: "Latest"),
                value: "\(Int((reading.value * 100).rounded()))",
                unit: "%",
                progress: nil
            )
        case .weight:
            return TodayMetricDisplay(
                kind: kind,
                sub: timestampSub(reading.date, prefix: "Latest"),
                value: String(format: "%.1f", reading.value),
                unit: "kg",
                progress: nil
            )
        case .distance:
            return TodayMetricDisplay(
                kind: kind,
                sub: "Since midnight",
                value: String(format: "%.1f", reading.value / 1000),
                unit: "km",
                progress: nil
            )
        case .activeEnergy:
            return TodayMetricDisplay(
                kind: kind,
                sub: "Since midnight",
                value: groupedCount(reading.value, locale: locale),
                unit: "kcal",
                progress: nil
            )
        }
    }

    private static func timestampSub(_ date: Date?, prefix: String) -> String {
        guard let date else { return "\(prefix) reading" }
        return "\(prefix) \u{00B7} \(date.formatted(date: .omitted, time: .shortened))"
    }
}

// MARK: - Order/visibility preferences (WP-33 step 2)

/// UserDefaults-backed metric order + visibility, mirroring
/// `SyncPreferences`/`WatchPriorityPreferences`' conventions (DI'd
/// defaults, `@Observable`, pure static functions carrying the actual
/// logic so tests never need `UserDefaults`).
///
/// Storage shape: one string array of the *visible* kinds' raw values, in
/// display order -- order and visibility are the same fact, so they can't
/// drift apart. Absent key = the mockup's default four. Unknown raw values
/// (a future kind removed in an update) are dropped on load.
@MainActor
@Observable
final class TodayMetricPreferences {
    private static let defaultsKey = "com.healthloom.settings.todayMetricOrder"

    private let defaults: UserDefaults
    private(set) var visibleKinds: [TodayMetricKind]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.visibleKinds = Self.load(from: defaults)
    }

    var hiddenKinds: [TodayMetricKind] {
        Self.hidden(givenVisible: visibleKinds)
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        visibleKinds.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    /// iOS 27 reorderable-content path (WP-33 step 2, as planned): applies
    /// the container's difference to the stored order. The `IndexSet` move
    /// above stays for the pure-logic unit tests; both persist identically.
    func reorder(_ difference: ReorderDifference<TodayMetricKind, ReorderableSingleCollectionIdentifier>) {
        reorder(sources: difference.sources, destination: difference.destination.position)
    }

    /// Testable half of `reorder(_:)`: the difference struct has no
    /// accessible initializer outside SwiftUI, so the container closure
    /// maps onto sources + position and both paths share this.
    func reorder(sources: [TodayMetricKind], destination: TodayReorderDestination) {
        visibleKinds = Self.applying(sources: sources, destination: destination, to: visibleKinds)
        persist()
    }

    func hide(_ kind: TodayMetricKind) {
        visibleKinds = Self.removing(kind, from: visibleKinds)
        persist()
    }

    /// Appends at the end of the current order (the design's panel is a
    /// short instrument list; a freshly added metric joining at the bottom
    /// is the least surprising placement).
    func show(_ kind: TodayMetricKind) {
        visibleKinds = Self.adding(kind, to: visibleKinds)
        persist()
    }

    // MARK: Pure logic (unit-tested directly)

    static func hidden(givenVisible visible: [TodayMetricKind]) -> [TodayMetricKind] {
        TodayMetricKind.allCases.filter { !visible.contains($0) }
    }

    static func removing(_ kind: TodayMetricKind, from visible: [TodayMetricKind]) -> [TodayMetricKind] {
        visible.filter { $0 != kind }
    }

    static func adding(_ kind: TodayMetricKind, to visible: [TodayMetricKind]) -> [TodayMetricKind] {
        visible.contains(kind) ? visible : visible + [kind]
    }

    /// Applies an iOS 27 reorder difference (WP-33 step 2's
    /// reorderable-content path) to a visible order: lifted-out sources
    /// re-insert before the destination anchor, appended on `.end` (or when
    /// the anchor itself moved away — it can't be found post-removal).
    /// Takes sources + position rather than the `ReorderDifference` itself
    /// because that struct has no accessible initializer outside SwiftUI;
    /// the container closure maps its difference onto these two. Pure so
    /// `TodayMetricPreferencesTests` pins it without gestures.
    static func applying(
        sources: [TodayMetricKind],
        destination: TodayReorderDestination,
        to visible: [TodayMetricKind]
    ) -> [TodayMetricKind] {
        let moving = visible.filter { sources.contains($0) }
        guard !moving.isEmpty else { return visible }
        var result = visible.filter { !sources.contains($0) }
        switch destination {
        case .before(let anchor):
            if let index = result.firstIndex(of: anchor) {
                result.insert(contentsOf: moving, at: index)
            } else {
                result.append(contentsOf: moving)
            }
        case .end:
            result.append(contentsOf: moving)
        }
        return result
    }

    static func decode(_ rawValues: [String]?) -> [TodayMetricKind] {
        guard let rawValues else { return TodayMetricKind.defaultVisible }
        let decoded = rawValues.compactMap(TodayMetricKind.init(rawValue:))
        // An explicitly-emptied panel is a valid saved state; only a fully
        // absent key falls back to the default four.
        return decoded
    }

    // MARK: Persistence

    /// UI-test hook: clears the stored order so a `-UITestResetTodayMetrics`
    /// launch (LaunchConfiguration.swift) starts from the default four
    /// regardless of what a previous test run on the same simulator
    /// persisted -- keeps `TodayUITests` idempotent across runs while its
    /// relaunch leg still exercises real persistence.
    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    private func persist() {
        defaults.set(visibleKinds.map(\.rawValue), forKey: Self.defaultsKey)
    }

    private static func load(from defaults: UserDefaults) -> [TodayMetricKind] {
        decode(defaults.stringArray(forKey: defaultsKey))
    }
}
