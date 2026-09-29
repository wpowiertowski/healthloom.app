// CoachWorkoutTextTests.swift
//
// WP-77: what the coach's workout tools answer. Series come from the real
// `ActivitySeriesBuilder` (the detail screen's own pipeline), so these
// tests read the same shapes the tools do. Dates are asserted by what
// they are, never by formatted text (ICU spacing differs across OSes).

import CoreModel
import Foundation
import SyncKit
import Testing
@testable import HealthLoom

@MainActor
@Suite("Coach workout text")
struct CoachWorkoutTextTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()
    static let locale = Locale(identifier: "en_US")
    static let start = ISO8601DateFormatter().date(from: "2026-09-17T12:00:00Z") ?? .distantPast

    static func entry(
        _ id: String, _ title: String = "Run", start: Date = start, minutes: Double = 15,
        source: String = ActivitySource.appleWatch.label, distance: Double? = nil
    ) -> ActivityEntry {
        ActivityEntry(
            id: id, kind: .unlinkedFitbitSession, title: title, start: start,
            end: start.addingTimeInterval(minutes * 60), sourceLabel: source, supplement: nil,
            family: .onFoot, distanceMeters: distance
        )
    }

    /// A steady effort: `metric` every `step` seconds for `minutes`, at
    /// `value` per sample (canonical units: metres, bpm, ms...).
    static func samples(
        _ metric: ActivityMetric, value: Double, minutes: Double, step: Double = 30,
        origin: SleepOrigin = .appleWatch
    ) -> [ActivitySample] {
        stride(from: 0.0, to: minutes * 60, by: step).map { offset in
            let time = start.addingTimeInterval(offset)
            let end = metric.style == .cumulative ? time.addingTimeInterval(step) : time
            return ActivitySample(metric: metric, start: time, end: end, value: value, origin: origin)
        }
    }

    static func series(_ samples: [ActivitySample], minutes: Double) -> [ActivityMetricSeries] {
        ActivitySeriesBuilder.series(samples, from: start, to: start.addingTimeInterval(minutes * 60))
    }

    static func detail(_ entry: ActivityEntry, _ series: [ActivityMetricSeries], measurement: String? = nil, needsReadAccess: Bool = false) -> String {
        CoachWorkoutText.detail(
            entry, number: 1, series: series, measurement: measurement,
            needsReadAccess: needsReadAccess, calendar: calendar, locale: locale
        )
    }

    // catches: workouts outside the asked window listed, a number resolving
    // to the workout after (or before) the one listed, or lines missing the
    // figures and source the Activities tab shows.
    @Test func theListNumbersWorkoutsAsTheDetailToolResolvesThem() {
        let entries = [
            Self.entry("new", "Rowing", start: Self.start, source: ActivitySource.appleHealth.label(detail: "Hydrow")),
            Self.entry("mid", start: Self.start.addingTimeInterval(-3 * 86_400), distance: 5_200),
            Self.entry("old", "Swim", start: Self.start.addingTimeInterval(-20 * 86_400)),
        ]
        let now = Self.start.addingTimeInterval(3600)

        let week = CoachWorkoutText.list(entries, days: 7, now: now, calendar: Self.calendar, locale: Self.locale)
        let lines = week.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[1].hasPrefix("1. Rowing \u{2014} "))
        #expect(lines[1].contains("Apple Health \u{00B7} Hydrow \u{00B7} Duration 15 m"))
        #expect(lines[2].hasPrefix("2. Run \u{2014} "))
        #expect(lines[2].contains("Distance 5.2 km"))
        #expect(!week.contains("Swim"))

        #expect(CoachWorkoutText.entry(number: 2, in: entries)?.id == "mid")
        #expect(CoachWorkoutText.entry(number: 0, in: entries) == nil)
        #expect(CoachWorkoutText.entry(number: 4, in: entries) == nil)
        #expect(CoachWorkoutText.list([], days: 7, now: now, calendar: Self.calendar, locale: Self.locale)
            == "No workouts in the last 7 days.")
    }

    // catches: a measurement the detail screen reads missing from the
    // overview, or a second device's line dropped from it.
    @Test func theOverviewNamesEveryMeasurementForEveryDevice() {
        let samples = Self.samples(.heartRate, value: 150, minutes: 15)
            + Self.samples(.heartRate, value: 146, minutes: 15, origin: .fitbit)
            + Self.samples(.runningGroundContactTime, value: 240, minutes: 15)
            + Self.samples(.runningVerticalOscillation, value: 8.5, minutes: 15)
        let text = Self.detail(Self.entry("run"), Self.series(samples, minutes: 15))

        #expect(text.contains("- Heart rate \u{2014} Apple Watch: Avg 150 bpm \u{00B7} 150\u{2013}150; Google Health: Avg 146 bpm"))
        #expect(text.contains("- Ground contact time \u{2014} Apple Watch: Avg 240 ms"))
        #expect(text.contains("- Vertical oscillation \u{2014} Apple Watch: Avg 8.5 cm"))
        #expect(text.contains("Heart rate every 2 min (Apple Watch):"))
        #expect(!text.contains(CoachWorkoutText.readAccessNote))
    }

    // catches: splits cut at the wrong time (pace off), heart rate averaged
    // over the whole workout instead of each split, or a short remainder
    // left as its own misleading split.
    @Test func splitsFollowTheDistanceTheWatchRecorded() {
        // 2.05 km at 6:00 /km: 1 km every 6 min, then 50 m in 18 s that
        // joins km 2 rather than standing alone.
        let minutes = 12.3
        let lastBit = ActivitySample(
            metric: .distance, start: Self.start.addingTimeInterval(720), end: Self.start.addingTimeInterval(738),
            value: 50, origin: .appleWatch
        )
        let samples = Self.samples(.distance, value: 1000.0 / 12, minutes: 12) + [lastBit]
            + Self.samples(.heartRate, value: 140, minutes: 6) + Self.samples(.heartRate, value: 160, minutes: minutes)
                .filter { $0.start > Self.start.addingTimeInterval(360) }
        let text = Self.detail(Self.entry("run", minutes: minutes), Self.series(samples, minutes: minutes))

        #expect(text.contains("Splits (Apple Watch distance):"))
        #expect(text.contains("- 0\u{2013}1 km: 6:00 /km \u{00B7} heart rate 140 bpm"))
        #expect(text.contains("- 1\u{2013}2.05 km: 6:00 /km \u{00B7} heart rate 160 bpm"))
        #expect(!text.contains("- 2\u{2013}"))
    }

    // catches: pool swims split per km, and marathons listing 42 rows past
    // what the on-device model can hold.
    @Test func splitsSuitTheActivity() {
        let swim = Self.series(Self.samples(.swimmingDistance, value: 25, minutes: 5), minutes: 5) // 250 m
        let swimText = Self.detail(Self.entry("swim", "Swim", minutes: 5), swim)
        #expect(swimText.contains("- 0\u{2013}100 m: 2:00 /100 m"))
        #expect(swimText.contains("- 200\u{2013}250 m: 2:00 /100 m"))

        guard let marathon = DistanceSplits(series: Self.series(Self.samples(.distance, value: 175, minutes: 120), minutes: 120)) else {
            Issue.record("no splits for 42 km")
            return
        }
        #expect(marathon.length == 3)
        #expect(marathon.rows.count == 14)
        #expect(marathon.rows.count <= CoachWorkoutText.maxSplits)
    }

    // catches: a breakdown that only covers the first device, averages a
    // running total, or loses amounts between buckets.
    @Test func aMeasurementBreaksDownByDistanceAndByMinute() {
        let minutes = 12.0
        let samples = Self.samples(.distance, value: 1000.0 / 12, minutes: minutes)
            + Self.samples(.runningPower, value: 250, minutes: minutes)
            + Self.samples(.runningPower, value: 240, minutes: minutes, origin: .otherApp)
            + Self.samples(.activeEnergy, value: 5, minutes: minutes)
        let series = Self.series(samples, minutes: minutes)

        let power = Self.detail(Self.entry("run", minutes: minutes), series, measurement: "power")
        #expect(power.contains("Running power \u{2014} Apple Watch: Avg 250 W"))
        #expect(power.contains("- 0\u{2013}1 km: Apple Watch 250 W, Apple Health 240 W"))
        #expect(power.contains("By minute:"))
        #expect(power.contains("- 11\u{2013}12 min: Apple Watch 250 W, Apple Health 240 W"))
        #expect(!power.contains("Splits ("))

        let energy = Self.detail(Self.entry("run", minutes: minutes), series, measurement: "Active energy")
        #expect(energy.contains("- 0\u{2013}1 min: 10 kcal"))
        #expect(energy.contains("- 1\u{2013}2 km: 60 kcal"))
    }

    // catches: the model's name for a measurement not finding it, or a
    // wrong guess answering with an unrelated one.
    @Test func measurementNamesMatchLoosely() {
        let series = Self.series(
            Self.samples(.heartRate, value: 150, minutes: 5) + Self.samples(.runningGroundContactTime, value: 240, minutes: 5)
                + Self.samples(.runningPower, value: 250, minutes: 5),
            minutes: 5
        )
        #expect(CoachWorkoutText.series(named: "Ground Contact Time", in: series)?.metric == .runningGroundContactTime)
        #expect(CoachWorkoutText.series(named: "runningGroundContactTime", in: series)?.metric == .runningGroundContactTime)
        #expect(CoachWorkoutText.series(named: "power", in: series)?.metric == .runningPower)
        #expect(CoachWorkoutText.series(named: "heart rate data", in: series)?.metric == .heartRate)
        #expect(CoachWorkoutText.series(named: "cadence", in: series) == nil)
        #expect(CoachWorkoutText.series(named: " ", in: series) == nil)

        let text = Self.detail(Self.entry("run", minutes: 5), series, measurement: "cadence")
        #expect(text.contains("No measurement called \"cadence\" was recorded during it. Recorded: Heart rate, Running power, Ground contact time."))
    }

    // catches: the coach silently missing running metrics it could have
    // had, or nagging when access is already settled.
    @Test func theReadAccessNoteShowsOnlyWhenAccessWasNeverAsked() {
        let entry = Self.entry("run")
        #expect(Self.detail(entry, [], needsReadAccess: true).hasSuffix(CoachWorkoutText.readAccessNote))
        #expect(Self.detail(entry, []).contains("No measurements were recorded during it beyond these figures."))
        #expect(!Self.detail(entry, []).contains(CoachWorkoutText.readAccessNote))
    }
}
