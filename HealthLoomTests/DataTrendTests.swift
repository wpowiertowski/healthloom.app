// DataTrendTests.swift
//
// WP-56: the Data tab's 7-day vs 30-day trends -- averaging, day keying,
// sleep's overlap merge, and the strings rows render. All pure: fixed
// calendar, fixed locale, fixed "now".

import CoreModel
import Foundation
import SwiftData
import Testing
@testable import HealthLoom

@Suite struct DataTrendTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()
    static let locale = Locale(identifier: "en_US")
    /// 2026-09-27 15:00 UTC -- mid-afternoon, so "today" is half done.
    static let now = Date(timeIntervalSince1970: 1_790_521_200)

    static func day(_ offset: Int) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: offset, to: today) ?? today
    }

    // catches: today's half-finished total dragging the average down, a
    // missing day counted as zero, and the 30-day average not covering the
    // days before the week.
    @Test func averagesCompletedDaysAndSkipsMissingOnes() throws {
        var daily: [Date: Double] = [Self.day(0): 100]              // today: excluded
        for offset in 1...7 where offset != 4 { daily[Self.day(-offset)] = 8_000 } // day -4 missing
        for offset in 8...30 { daily[Self.day(-offset)] = 5_000 }
        daily[Self.day(-31)] = 1_000_000                           // outside the month

        let trend = try #require(RollingTrend.from(daily: daily, now: Self.now, calendar: Self.calendar))
        #expect(trend.weekAverage == 8_000)
        #expect(trend.monthAverage == Double(6 * 8_000 + 23 * 5_000) / 29)
        #expect(trend.delta > 0)
    }

    // catches: a trend invented from a week with no data (only older days).
    @Test func noTrendWithoutDataInTheLastWeek() {
        let daily = [Self.day(-10): 7_000.0, Self.day(0): 500]
        #expect(RollingTrend.from(daily: daily, now: Self.now, calendar: Self.calendar) == nil)
    }

    // catches: a night split across two days at midnight, last night not
    // counting as a completed day, and a night recorded by both a watch and
    // a Fitbit counted twice.
    @Test func nightsKeyOnTheirEveningAndOverlapsCountOnce() {
        let evening = Self.day(-1).addingTimeInterval(23 * 3600)          // 23:00 yesterday
        let watch = DateInterval(start: evening, duration: 7 * 3600)       // 23:00-06:00
        let fitbit = DateInterval(start: evening.addingTimeInterval(1800), duration: 7 * 3600) // 23:30-06:30
        let nights = RollingTrend.nightlyAsleep([watch, fitbit], calendar: Self.calendar)
        #expect(nights == [Self.day(-1): 7.5 * 3600])
        #expect(RollingTrend.from(daily: nights, now: Self.now, calendar: Self.calendar) != nil)
    }

    // catches: the Today panel's last-night total summing overlapping
    // samples (the pre-WP-56 behaviour) -- one shared merge now.
    @Test func asleepTotalCountsOverlapsOnce() {
        let start = Self.day(-1)
        let a = DateInterval(start: start, duration: 3600)
        let b = DateInterval(start: start.addingTimeInterval(1800), duration: 3600)
        let c = DateInterval(start: start.addingTimeInterval(4 * 3600), duration: 600)
        #expect(AsleepTime.total([b, a, c]) == 5400 + 600)
    }

    // catches: the build-21 launch crash. HealthKit calls the sleep math on
    // its own queues; with main-actor isolation the merge's sort closure
    // trapped the first time a real night of sleep reached it (WP-57). Run
    // here from a detached task, off the main actor, with overlapping
    // intervals so the comparator actually executes.
    @Test func sleepMathRunsOffTheMainActor() async {
        let start = Self.day(-1)
        let intervals = [
            DateInterval(start: start.addingTimeInterval(1800), duration: 3600),
            DateInterval(start: start, duration: 3600),
        ]
        let calendar = Self.calendar
        let (total, nights) = await Task.detached {
            (AsleepTime.total(intervals), RollingTrend.nightlyAsleep(intervals, calendar: calendar))
        }.value
        #expect(total == 5400)
        #expect(nights.values.reduce(0, +) == 5400)
    }

    // catches: a trend printed without its unit, a falling average missing
    // its minus sign, and a rounding-level change shown as "+0".
    @Test func trendStringsCarryUnitsAndSignedChange() {
        let heart = DataTrendText.make(
            RollingTrend(weekAverage: 61.6, monthAverage: 64.9),
            metric: .today(.heart), locale: Self.locale, units: .metric
        )
        #expect(heart.value == "62 bpm")
        #expect(heart.comparison == "7d avg · −3 bpm vs 30d")

        let steps = DataTrendText.make(
            RollingTrend(weekAverage: 8_240, monthAverage: 7_930),
            metric: .today(.steps), locale: Self.locale, units: .metric
        )
        #expect(steps.value == "8,240")
        #expect(steps.comparison == "7d avg · +310 vs 30d")

        let flat = DataTrendText.make(
            RollingTrend(weekAverage: 70.52, monthAverage: 70.5),
            metric: .today(.weight), locale: Self.locale, units: .metric
        )
        #expect(flat.comparison == "7d avg · same as 30d")
        #expect(DataTrendText.make(nil, metric: .today(.sleep), locale: Self.locale, units: .metric) == .empty)
    }

    static func localSample(_ type: GoogleDataType, start: Date, minutes: Double?) -> LocalSample {
        let values = minutes.map { #"{"values":{"minutes":\#($0)}}"# } ?? "{}"
        return LocalSample(
            externalID: UUID().uuidString, dataType: type.rawValue, payloadJSON: Data(values.utf8),
            start: start, end: start.addingTimeInterval(900), source: "Fitbit Air"
        )
    }

    // catches: zone minutes shown as the number of stored records (the old
    // "681") instead of minutes per day, and several records on one day
    // not summing into that day.
    @Test func localMinutesAverageTheDailyTotal() {
        let samples = [
            Self.localSample(.activeZoneMinutes, start: Self.day(-1).addingTimeInterval(3600), minutes: 20),
            Self.localSample(.activeZoneMinutes, start: Self.day(-1).addingTimeInterval(7200), minutes: 10),
            Self.localSample(.activeZoneMinutes, start: Self.day(-2), minutes: 40),
            Self.localSample(.activeZoneMinutes, start: Self.day(-3), minutes: nil), // no value: skipped
        ]
        let summary = LocalRowSummary.make(
            type: .activeZoneMinutes, recent: samples, lastSample: nil, now: Self.now, calendar: Self.calendar
        )
        let text = DataTrendText.local(type: .activeZoneMinutes, summary: summary, locale: Self.locale, units: .metric)
        #expect(text.value == "35 min")
    }

    // catches: ECG / irregular-rhythm rows averaging events that mean
    // nothing averaged, or counting recordings older than 30 days.
    @Test func clinicalEventsAreCountedOverThirtyDays() {
        let samples = [
            Self.localSample(.electrocardiogram, start: Self.day(-2), minutes: nil),
            Self.localSample(.electrocardiogram, start: Self.day(-45), minutes: nil),
        ]
        let summary = LocalRowSummary.make(
            type: .electrocardiogram, recent: samples, lastSample: nil, now: Self.now, calendar: Self.calendar
        )
        let text = DataTrendText.local(type: .electrocardiogram, summary: summary, locale: Self.locale, units: .metric)
        #expect(text == DataTrendText(value: "1 recording", comparison: "last 30 days"))
        let none = DataTrendText.local(type: .irregularRhythmNotification, summary: .empty, locale: Self.locale, units: .metric)
        #expect(none.value == "None")
    }

    // catches: the Data tab reading every in-app sample on the main thread
    // (the WP-67 hang): the summarizer must run on its own actor, read only
    // the last 30 days per type, and still find the newest sample.
    @Test func theSummarizerReadsRecentSamplesOffTheMainActor() async throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let context = ModelContext(container)
        context.insert(Self.localSample(.activeZoneMinutes, start: Self.day(-1), minutes: 30))
        context.insert(Self.localSample(.activeZoneMinutes, start: Self.day(-2), minutes: 30))
        context.insert(Self.localSample(.activeZoneMinutes, start: Self.day(-60), minutes: 900))
        context.insert(Self.localSample(.electrocardiogram, start: Self.day(-3), minutes: nil))
        try context.save()

        let summaries = await LocalRowSummarizer(modelContainer: container)
            .summaries(for: [.activeZoneMinutes, .electrocardiogram, .activeMinutes], now: Self.now, calendar: Self.calendar)

        let zone = try #require(summaries[.activeZoneMinutes])
        #expect(DataTrendText.local(type: .activeZoneMinutes, summary: zone, locale: Self.locale, units: .metric).value == "30 min")
        #expect(zone.lastSample == Self.day(-1).addingTimeInterval(900))
        #expect(summaries[.electrocardiogram]?.recentCount == 1)
        #expect(summaries[.activeMinutes] == LocalRowSummary(trend: nil, recentCount: 0, lastSample: nil))
    }
}
