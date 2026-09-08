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
    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "TodayMetricPreferencesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func freshDefaultsShowTheMockupsDefaultFour() throws {
        let preferences = TodayMetricPreferences(defaults: try makeDefaults())
        #expect(preferences.visibleKinds == [.heart, .steps, .sleep, .bloodOxygen])
        #expect(preferences.hiddenKinds == [.weight, .distance, .activeEnergy])
    }


    @Test func hideAndShowPersistAndAppendAtTheEnd() throws {
        let defaults = try makeDefaults()
        let preferences = TodayMetricPreferences(defaults: defaults)

        preferences.hide(.sleep)
        preferences.show(.weight)

        #expect(preferences.visibleKinds == [.heart, .steps, .bloodOxygen, .weight])
        #expect(preferences.hiddenKinds.contains(.sleep))

        let reloaded = TodayMetricPreferences(defaults: defaults)
        #expect(reloaded.visibleKinds == [.heart, .steps, .bloodOxygen, .weight])
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
        let defaults = try makeDefaults()
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
