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
    case hrv
    case steps
    case sleep
    case bloodOxygen
    case weight
    case distance
    case activeEnergy

    var id: String { rawValue }

    /// The default rows, in order. HRV sits beside Heart — they read the
    /// same organ — and is the readiness hero's heaviest signal, so a user
    /// who has it wants it on the panel. A user who does *not* record HRV
    /// never sees the row at all (`hidesWhenUnavailable`).
    static let defaultVisible: [TodayMetricKind] = [.heart, .hrv, .steps, .sleep, .bloodOxygen]

    /// Kinds that disappear entirely when the data is simply absent,
    /// instead of rendering a permanently empty row.
    ///
    /// Every other metric has a plausible path to data for anyone: a phone
    /// counts steps, a scale reports weight. HRV is different — plenty of
    /// devices never record it, so "No data yet" would not be a *yet*, it
    /// would be forever, and a row that can never fill is furniture.
    static let hidesWhenUnavailable: Set<TodayMetricKind> = [.hrv]

    /// How far back to look before deciding such a kind has no data.
    ///
    /// Deliberately much longer than `TodayMetricsProvider.latestSampleRecency`
    /// (7 days), which governs whether a reading is fresh enough to *show*.
    /// The two answer different questions: "is this number current?" versus
    /// "does this person record this at all?". A month of silence is the
    /// second.
    static let availabilityWindowDays = 30

    /// Drops the kinds that hide themselves when unavailable. Pure, so the
    /// rule is pinned without HealthKit.
    static func rows(
        visible: [TodayMetricKind],
        unavailable: Set<TodayMetricKind>
    ) -> [TodayMetricKind] {
        visible.filter { !(hidesWhenUnavailable.contains($0) && unavailable.contains($0)) }
    }

    var displayName: String {
        switch self {
        case .heart: return "Heart"
        case .hrv: return "HRV"
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
    /// Unit system the value/unit were formatted in (WP-37: spoken units
    /// must match displayed units — "pounds" never describes kilograms).
    let unitSystem: UnitSystem

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
        case .hrv: spokenUnit = "milliseconds"
        case .bloodOxygen: spokenUnit = "percent"
        case .weight: spokenUnit = unitSystem == .metric ? "kilograms" : "pounds"
        case .distance: spokenUnit = unitSystem == .metric ? "kilometers" : "miles"
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
    /// Canonical readings (kg, meters) render in the locale's unit system
    /// (WP-37 / test plan §6: en_US → lb/mi, de_DE → kg/km) — HealthKit
    /// keeps canonical units; only the display converts.
    static func display(
        kind: TodayMetricKind,
        reading: TodayMetricReading?,
        locale: Locale = .current,
        unitSystem: UnitSystem
    ) -> TodayMetricDisplay {
        guard let reading else {
            return TodayMetricDisplay(
                kind: kind, sub: "No data yet", value: nil, unit: nil, progress: nil,
                unitSystem: unitSystem
            )
        }
        switch kind {
        case .heart:
            return TodayMetricDisplay(
                kind: kind,
                sub: timestampSub(reading.date, prefix: "Latest"),
                value: groupedCount(reading.value, locale: locale),
                unit: "bpm",
                progress: nil,
                unitSystem: unitSystem
            )
        case .hrv:
            // Canonical reading is milliseconds (SDNN), the same unit the
            // readiness engine baselines against. Whole milliseconds: the
            // decimals HealthKit carries are below the noise floor of the
            // measurement and only add width.
            return TodayMetricDisplay(
                kind: kind,
                sub: timestampSub(reading.date, prefix: "Latest"),
                value: groupedCount(reading.value.rounded(), locale: locale),
                unit: "ms",
                progress: nil,
                unitSystem: unitSystem
            )
        case .steps:
            let fraction = min(reading.value / defaultStepGoal, 1)
            let percent = Int((reading.value / defaultStepGoal * 100).rounded())
            return TodayMetricDisplay(
                kind: kind,
                sub: "\(percent)% of \(groupedCount(defaultStepGoal, locale: locale)) goal",
                value: groupedCount(reading.value, locale: locale),
                unit: nil,
                progress: fraction,
                unitSystem: unitSystem
            )
        case .sleep:
            return TodayMetricDisplay(
                kind: kind,
                sub: "Last night",
                value: duration(seconds: reading.value),
                unit: nil,
                progress: nil,
                unitSystem: unitSystem
            )
        case .bloodOxygen:
            // Canonical reading is HealthKit's 0...1 fraction.
            return TodayMetricDisplay(
                kind: kind,
                sub: timestampSub(reading.date, prefix: "Latest"),
                value: "\(Int((reading.value * 100).rounded()))",
                unit: "%",
                progress: nil,
                unitSystem: unitSystem
            )
        case .weight:
            // Canonical reading is kilograms; imperial renders pounds.
            let poundsPerKilogram = 2.20462
            let isMetric = unitSystem == .metric
            return TodayMetricDisplay(
                kind: kind,
                sub: timestampSub(reading.date, prefix: "Latest"),
                value: String(format: "%.1f", locale: locale, isMetric ? reading.value : reading.value * poundsPerKilogram),
                unit: isMetric ? "kg" : "lb",
                progress: nil,
                unitSystem: unitSystem
            )
        case .distance:
            // Canonical reading is meters; imperial renders miles.
            let metersPerMile = 1609.34
            let isMetric = unitSystem == .metric
            return TodayMetricDisplay(
                kind: kind,
                sub: "Since midnight",
                value: String(format: "%.1f", locale: locale, isMetric ? reading.value / 1000 : reading.value / metersPerMile),
                unit: isMetric ? "km" : "mi",
                progress: nil,
                unitSystem: unitSystem
            )
        case .activeEnergy:
            return TodayMetricDisplay(
                kind: kind,
                sub: "Since midnight",
                value: groupedCount(reading.value, locale: locale),
                unit: "kcal",
                progress: nil,
                unitSystem: unitSystem
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
    /// Marks that the stored order has been offered HRV once.
    ///
    /// Needed to tell two states apart that look identical in storage: an
    /// order saved *before* HRV existed, and one where the user has since
    /// hidden it. Without the marker a deliberate hide would be undone on
    /// every launch. Set the first time either way.
    private static let hrvOfferedKey = "com.healthloom.settings.todayMetricOrder.hrvOffered"

    private let defaults: UserDefaults
    private(set) var visibleKinds: [TodayMetricKind]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.visibleKinds = Self.load(from: defaults)
    }

    var hiddenKinds: [TodayMetricKind] {
        Self.hidden(givenVisible: visibleKinds)
    }

    /// iOS 27 reorderable-content path (WP-33 step 2, as planned): applies
    /// the container's difference to the stored order. (An earlier
    /// `IndexSet`-based `move` was deleted in review round 1 — no app
    /// caller remained once the List sheet went away, and production code
    /// justified only by its tests is the wrong way round. Its intent —
    /// moved order persists across instances — lives on in
    /// `reorderDifferencePersists`.)
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
        defaults.removeObject(forKey: hrvOfferedKey)
    }

    private func persist() {
        defaults.set(visibleKinds.map(\.rawValue), forKey: Self.defaultsKey)
    }

    private static func load(from defaults: UserDefaults) -> [TodayMetricKind] {
        let stored = defaults.stringArray(forKey: defaultsKey)
        let decoded = decode(stored)
        guard stored != nil, !defaults.bool(forKey: hrvOfferedKey) else { return decoded }
        // An order saved before HRV existed: insert it once, in its default
        // position, and record that we have. Safe to do unasked — the row
        // only ever renders for someone who actually records HRV.
        defaults.set(true, forKey: hrvOfferedKey)
        let migrated = offeringHRV(to: decoded)
        defaults.set(migrated.map(\.rawValue), forKey: defaultsKey)
        return migrated
    }

    /// Inserts HRV after Heart (its `defaultVisible` neighbour), or at the
    /// front when Heart itself is hidden. Pure.
    static func offeringHRV(to visible: [TodayMetricKind]) -> [TodayMetricKind] {
        guard !visible.contains(.hrv) else { return visible }
        var result = visible
        if let heart = result.firstIndex(of: .heart) {
            result.insert(.hrv, at: result.index(after: heart))
        } else {
            result.insert(.hrv, at: result.startIndex)
        }
        return result
    }
}
