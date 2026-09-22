// TodayMetricsTests.swift
//
// WP-33 (implementation-plan.md) "Tests:" line: "reorder persistence unit
// test" plus coverage for the pure formatting that turns raw HealthKit
// readings into the instrument panel's strings (`TodayMetrics.swift`) and
// the header's sync-status/greeting logic (`TodayHeaderModel.swift`).
// Snapshot tests (light/dark x Dynamic Type) are deferred -- see
// progress.md's WP-33 entry (the swift-snapshot-testing dependency can't
// be resolved from this authoring environment).

import CoreModel
import Foundation
import SwiftUI
import Testing
@testable import HealthLoom

// MARK: - Order/visibility preferences (WP-33 step 2)

@Suite("TodayMetricPreferences")
struct TodayMetricPreferencesTests {
    private func makeDefaults() throws -> EphemeralDefaults {
        try EphemeralDefaults(prefix: "todaymetrics")
    }

    @Test func freshDefaultsShowTheDefaultRows() throws {
        let ephemeral1 = try makeDefaults()
        let preferences = TodayMetricPreferences(defaults: ephemeral1.defaults)
        // HRV joined the defaults beside Heart; it is dropped at render
        // time for anyone without the data, not omitted from the order.
        #expect(preferences.visibleKinds == [.heart, .hrv, .steps, .sleep, .bloodOxygen])
        #expect(preferences.hiddenKinds == [.weight, .distance, .activeEnergy])
    }


    @Test func hideAndShowPersistAndAppendAtTheEnd() throws {
        let ephemeral2 = try makeDefaults()
        let defaults = ephemeral2.defaults
        let preferences = TodayMetricPreferences(defaults: defaults)

        preferences.hide(.sleep)
        preferences.show(.weight)

        #expect(preferences.visibleKinds == [.heart, .hrv, .steps, .bloodOxygen, .weight])
        #expect(preferences.hiddenKinds.contains(.sleep))

        let reloaded = TodayMetricPreferences(defaults: defaults)
        #expect(reloaded.visibleKinds == [.heart, .hrv, .steps, .bloodOxygen, .weight])
    }

    @Test func showingAnAlreadyVisibleKindDoesNotDuplicate() {
        let result = TodayMetricPreferences.adding(.heart, to: [.heart, .steps])
        #expect(result == [.heart, .steps])
    }

    @Test func decodeDropsUnknownRawValuesAndKeepsOrder() {
        // A future kind removed in an update must not crash or reorder the
        // survivors.
        let decoded = TodayMetricPreferences.decode(["steps", "someFutureMetric", "heart"])
        #expect(decoded == [.steps, .heart])
    }

    @Test func decodeDistinguishesAbsentKeyFromExplicitlyEmptyPanel() {
        #expect(TodayMetricPreferences.decode(nil) == TodayMetricKind.defaultVisible)
        #expect(TodayMetricPreferences.decode([]) == [])
    }

    @Test func reorderDifferenceBeforeAnchor() {
        let visible: [TodayMetricKind] = [.heart, .steps, .sleep, .bloodOxygen]
        let result = TodayMetricPreferences.applying(
            sources: [.sleep], destination: .before(.heart), to: visible
        )
        #expect(result == [.sleep, .heart, .steps, .bloodOxygen])
    }

    @Test func reorderDifferenceEndAppends() {
        let visible: [TodayMetricKind] = [.heart, .steps, .sleep, .bloodOxygen]
        let result = TodayMetricPreferences.applying(
            sources: [.heart], destination: .end, to: visible
        )
        #expect(result == [.steps, .sleep, .bloodOxygen, .heart])
    }

    @Test func reorderDifferenceKeepsMultiSourceOrder() {
        let visible: [TodayMetricKind] = [.heart, .steps, .sleep, .bloodOxygen]
        let result = TodayMetricPreferences.applying(
            sources: [.bloodOxygen, .heart], destination: .before(.sleep), to: visible
        )
        // Moving items keep their current relative order at the anchor.
        #expect(result == [.steps, .heart, .bloodOxygen, .sleep])
    }

    @Test func reorderDifferenceWithMovedAnchorFallsBackToEnd() {
        let visible: [TodayMetricKind] = [.heart, .steps, .sleep]
        let result = TodayMetricPreferences.applying(
            sources: [.heart, .steps], destination: .before(.heart), to: visible
        )
        #expect(result == [.sleep, .heart, .steps])
    }

    @Test func reorderDifferencePersists() throws {
        // WP-33's "reorder persistence" requirement, via the live path:
        // a fresh instance reads the reordered order back.
        let ephemeral3 = try makeDefaults()
        let defaults = ephemeral3.defaults
        let preferences = TodayMetricPreferences(defaults: defaults)
        preferences.reorder(sources: [.bloodOxygen], destination: .before(.heart))
        #expect(preferences.visibleKinds.first == .bloodOxygen)
        let reloaded = TodayMetricPreferences(defaults: defaults)
        #expect(reloaded.visibleKinds.first == .bloodOxygen)
    }
}

// MARK: - Formatting

@Suite("TodayMetricFormatter")
struct TodayMetricFormatterTests {
    static let enUS = Locale(identifier: "en_US")
    static let deDE = Locale(identifier: "de_DE")

    @Test func groupedCountUsesThousandsSeparators() {
        #expect(TodayMetricFormatter.groupedCount(8240, locale: Self.enUS) == "8,240")
        #expect(TodayMetricFormatter.groupedCount(982, locale: Self.enUS) == "982")
    }

    @Test func durationFormatsHoursAndMinutes() {
        #expect(TodayMetricFormatter.duration(seconds: 7 * 3600 + 12 * 60) == "7h 12m")
        #expect(TodayMetricFormatter.duration(seconds: 42 * 60) == "42m")
        #expect(TodayMetricFormatter.duration(seconds: 0) == "0m")
        // Clock-skewed sample (end < start): clamps instead of rendering
        // "-1h -5m" through truncating division.
        #expect(TodayMetricFormatter.duration(seconds: -3900) == "0m")
    }

    @Test func missingReadingRendersTheEmptyRow() {
        let display = TodayMetricFormatter.display(kind: .heart, reading: nil, locale: Self.enUS, unitSystem: .imperial)
        #expect(display.value == nil)
        #expect(display.sub == "No data yet")
        #expect(display.accessibilityText == "Heart, no data yet")
    }

    // WP-38 degradation matrix, HK-denied leg (third-party F8): a denied
    // authorization surfaces as nil readings at the formatter boundary
    // (TodayMetricsProvider yields nothing per kind), so every kind must
    // degrade to its empty row — no value, no progress, no crash.
    @Test func deniedAuthorizationEmptiesEveryKind() {
        for kind in TodayMetricKind.allCases {
            let display = TodayMetricFormatter.display(kind: kind, reading: nil, locale: Self.enUS, unitSystem: .imperial)
            #expect(display.value == nil, "\(kind) leaks a value without a reading")
            #expect(display.sub == "No data yet")
            #expect(display.progress == nil)
        }
    }

    @Test func stepsRowCarriesGoalPercentAndCappedProgress() {
        let display = TodayMetricFormatter.display(
            kind: .steps,
            reading: TodayMetricReading(value: 8240, date: nil),
            locale: Self.enUS,
            unitSystem: .imperial
        )
        #expect(display.value == "8,240")
        #expect(display.sub == "82% of 10,000 goal")
        #expect(display.progress != nil)
        #expect(abs((display.progress ?? 0) - 0.824) < 0.0001)

        // Over-goal days cap the bar at 1.0 but report the honest percent.
        let over = TodayMetricFormatter.display(
            kind: .steps,
            reading: TodayMetricReading(value: 13_000, date: nil),
            locale: Self.enUS,
            unitSystem: .imperial
        )
        #expect(over.progress == 1.0)
        #expect(over.sub == "130% of 10,000 goal")
    }

    @Test func bloodOxygenConvertsHealthKitFractionToPercent() {
        let display = TodayMetricFormatter.display(
            kind: .bloodOxygen,
            reading: TodayMetricReading(value: 0.97, date: nil),
            locale: Self.enUS,
            unitSystem: .imperial
        )
        #expect(display.value == "97")
        #expect(display.unit == "%")
    }

    @Test func sleepDistanceAndEnergyFormatTheirUnits() {
        let sleep = TodayMetricFormatter.display(
            kind: .sleep, reading: TodayMetricReading(value: 7 * 3600 + 12 * 60, date: nil), locale: Self.enUS,
            unitSystem: .imperial
        )
        #expect(sleep.value == "7h 12m")
        #expect(sleep.sub == "Last night")

        // en_US renders imperial miles…
        let distance = TodayMetricFormatter.display(
            kind: .distance, reading: TodayMetricReading(value: 5230, date: nil), locale: Self.enUS,
            unitSystem: .imperial
        )
        #expect(distance.value == "3.2")
        #expect(distance.unit == "mi")
        #expect(distance.accessibilityText.contains("miles"))
        // …while de_DE renders metric kilometers from the same canonical meters.
        let metricDistance = TodayMetricFormatter.display(
            kind: .distance, reading: TodayMetricReading(value: 5230, date: nil), locale: Self.deDE,
            unitSystem: .metric
        )
        #expect(metricDistance.value == "5,2")
        #expect(metricDistance.unit == "km")
        #expect(metricDistance.accessibilityText.contains("kilometers"))

        let energy = TodayMetricFormatter.display(
            kind: .activeEnergy, reading: TodayMetricReading(value: 1421, date: nil), locale: Self.enUS,
            unitSystem: .imperial
        )
        #expect(energy.value == "1,421")
        #expect(energy.unit == "kcal")
    }

    @Test func weightFollowsLocaleUnitSystem() {
        // 78 kg canonical: en_US reads pounds, de_DE reads kilograms.
        let imperial = TodayMetricFormatter.display(
            kind: .weight, reading: TodayMetricReading(value: 78, date: nil), locale: Self.enUS,
            unitSystem: .imperial
        )
        #expect(imperial.value == "172.0")
        #expect(imperial.unit == "lb")
        #expect(imperial.accessibilityText.contains("pounds"))
        let metric = TodayMetricFormatter.display(
            kind: .weight, reading: TodayMetricReading(value: 78, date: nil), locale: Self.deDE,
            unitSystem: .metric
        )
        #expect(metric.value == "78,0")
        #expect(metric.unit == "kg")
        #expect(metric.accessibilityText.contains("kilograms"))
    }
}

// MARK: - Header model (sync status + greeting)

@Suite("TodayHeaderModel")
struct TodayHeaderModelTests {
    static let now = Date(timeIntervalSince1970: 1_780_000_000)

    @Test func freshSyncRendersLiveStatusWithDeviceLabel() {
        let status = TodaySyncStatus.make(
            lastSyncedAt: Self.now.addingTimeInterval(-9 * 60),
            deviceLabel: "Fitbit Air",
            now: Self.now
        )
        #expect(status.freshness == .fresh)
        #expect(status.text == "Fitbit Air \u{00B7} synced 9m ago")
    }

    @Test func staleAfterTwentyFourHours() {
        // WP-33 step 4's "stale data (>24 h)" state -- boundary exclusive:
        // exactly 24 h is still fresh, a second past is stale.
        let exactly = TodaySyncStatus.make(
            lastSyncedAt: Self.now.addingTimeInterval(-24 * 3600), deviceLabel: nil, now: Self.now
        )
        #expect(exactly.freshness == .fresh)

        let past = TodaySyncStatus.make(
            lastSyncedAt: Self.now.addingTimeInterval(-2 * 24 * 3600), deviceLabel: nil, now: Self.now
        )
        #expect(past.freshness == .stale)
        #expect(past.text == "last synced 2d ago")
    }

    @Test func neverSyncedRendersTheEmptyState() {
        let status = TodaySyncStatus.make(lastSyncedAt: nil, deviceLabel: "Fitbit Air", now: Self.now)
        #expect(status.freshness == .never)
        #expect(status.text == "Not synced yet")
    }

    @Test func relativeAgeIsTerse() {
        #expect(TodaySyncStatus.relativeAge(30) == "moments")
        #expect(TodaySyncStatus.relativeAge(9 * 60) == "9m")
        #expect(TodaySyncStatus.relativeAge(3 * 3600 + 120) == "3h")
        #expect(TodaySyncStatus.relativeAge(49 * 3600) == "2d")
    }

    @Test func greetingFollowsTheHour() {
        #expect(TodayGreeting.text(hour: 7) == "Good morning")
        #expect(TodayGreeting.text(hour: 13) == "Good afternoon")
        #expect(TodayGreeting.text(hour: 20) == "Good evening")
        #expect(TodayGreeting.text(hour: 2) == "Good evening")
    }
}

@Suite("TodayMetricsProvider recency")
struct TodayRecencyTests {
    @Test func ancientSampleIsStale() {
        // Round-10 item 4: a months-old sample must not render as a
        // fresh "Latest" reading — the provider yields nothing (the
        // row's "No data yet" empty state), never a stale number.
        let now = Date()
        func reading(daysAgo: Double) -> TodayMetricReading {
            TodayMetricReading(value: 72, date: now.addingTimeInterval(-daysAgo * 24 * 3600))
        }
        #expect(TodayMetricsProvider.isFresh(reading(daysAgo: 1), now: now))
        #expect(TodayMetricsProvider.isFresh(reading(daysAgo: 7), now: now))
        #expect(!TodayMetricsProvider.isFresh(reading(daysAgo: 8), now: now))
        #expect(!TodayMetricsProvider.isFresh(reading(daysAgo: 90), now: now))
        #expect(!TodayMetricsProvider.isFresh(TodayMetricReading(value: 72, date: nil), now: now))
    }
}

@Suite("Today HRV row")
struct TodayHRVRowTests {
    private let unitSystem = UnitSystem.metric

    @Test("renders whole milliseconds with its own unit")
    // catches: HRV borrowing another kind's formatting — a bpm unit, or
    // HealthKit's raw decimals widening the value column for precision the
    // measurement does not have.
    func formatsMilliseconds() {
        let display = TodayMetricFormatter.display(
            kind: .hrv,
            reading: TodayMetricReading(value: 42.37, date: nil),
            locale: Locale(identifier: "en_US"),
            unitSystem: unitSystem
        )
        #expect(display.value == "42")
        #expect(display.unit == "ms")
        #expect(display.name == "HRV")
    }

    @Test("speaks milliseconds, not the neighbouring heart row's bpm")
    // catches: WP-37's rule that spoken units match displayed ones, broken
    // by HRV falling into the `.heart` branch it sits beside.
    func speaksItsOwnUnit() {
        let display = TodayMetricFormatter.display(
            kind: .hrv,
            reading: TodayMetricReading(value: 42, date: nil),
            locale: Locale(identifier: "en_US"),
            unitSystem: unitSystem
        )
        #expect(display.accessibilityText.contains("milliseconds"))
        #expect(!display.accessibilityText.contains("beats per minute"))
    }

    @Test("a kind with no data in the window loses its row entirely")
    // catches: HRV rendering a permanently empty "No data yet" row on a
    // device that never records it — the row can never fill, so it is
    // furniture.
    func unavailableKindIsDropped() {
        let visible = TodayMetricKind.defaultVisible
        #expect(visible.contains(.hrv))
        let rows = TodayMetricKind.rows(visible: visible, unavailable: [.hrv])
        #expect(!rows.contains(.hrv))
        // Nothing else moves or disappears with it.
        #expect(rows == visible.filter { $0 != .hrv })
    }

    @Test("only the hiding kinds can be dropped")
    // catches: the filter generalising, so a quiet week would silently
    // remove Steps or Sleep instead of showing their empty state.
    func nonHidingKindsSurviveUnavailability() {
        let rows = TodayMetricKind.rows(
            visible: TodayMetricKind.defaultVisible,
            unavailable: [.steps, .sleep, .bloodOxygen]
        )
        #expect(rows == TodayMetricKind.defaultVisible)
    }

    @Test("an order saved before HRV existed gains it once, next to Heart")
    @MainActor
    // catches: existing users never seeing the new row, because a stored
    // order bypasses `defaultVisible` entirely.
    func migrationInsertsAfterHeart() {
        #expect(
            TodayMetricPreferences.offeringHRV(to: [.heart, .steps, .sleep])
            == [.heart, .hrv, .steps, .sleep]
        )
        // Heart hidden: HRV still has to land somewhere sensible.
        #expect(TodayMetricPreferences.offeringHRV(to: [.steps, .sleep]) == [.hrv, .steps, .sleep])
        // Already present: untouched, so the offer cannot duplicate it.
        #expect(
            TodayMetricPreferences.offeringHRV(to: [.steps, .hrv]) == [.steps, .hrv]
        )
    }

    @Test("the offer happens once, so hiding HRV sticks")
    // catches: the migration re-adding HRV on every launch and overriding a
    // deliberate hide — the reason it needs a marker rather than a
    // contains-check.
    @MainActor
    func migrationDoesNotUndoADeliberateHide() {
        let suite = "hrv-offer-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("could not create a defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        // An order stored before HRV existed.
        defaults.set(["heart", "steps"], forKey: "com.healthloom.settings.todayMetricOrder")
        #expect(TodayMetricPreferences(defaults: defaults).visibleKinds == [.heart, .hrv, .steps])

        // The user hides it; a later launch must respect that.
        let prefs = TodayMetricPreferences(defaults: defaults)
        prefs.hide(.hrv)
        #expect(TodayMetricPreferences(defaults: defaults).visibleKinds == [.heart, .steps])
    }
}
