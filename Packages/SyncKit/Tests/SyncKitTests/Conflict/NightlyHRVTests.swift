// NightlyHRVTests.swift
//
// WP-65: one HRV number per night, 8 pm-6 am on the clock the night was
// slept by.

import Foundation
import Testing
@testable import SyncKit

@Suite struct NightlyHRVTests {
    static let newYork = TimeZone(identifier: "America/New_York") ?? .gmt
    static let london = TimeZone(identifier: "Europe/London") ?? .gmt

    static func time(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    static func fitbit(_ ms: Double) -> NightlyHRV.NightAverage { .init(milliseconds: ms, origin: .fitbit) }

    static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    static func reading(_ time: Date, _ ms: Double, _ origin: SleepOrigin = .fitbit, zone: TimeZone? = nil) -> NightlyHRV.Reading {
        NightlyHRV.Reading(time: time, milliseconds: ms, origin: origin, timeZone: zone)
    }

    // catches: daytime readings (a Watch spot check at noon) averaged into
    // the night, or an edge hour landing on the wrong night.
    @Test func theNightRunsFromEightPMToSixAM() {
        let z = Self.newYork
        let evening = NightlyHRV.night(of: Self.time(2026, 9, 27, 20, in: z), in: z)
        #expect(evening == NightlyHRV.night(of: Self.time(2026, 9, 28, 5, 59, in: z), in: z))
        #expect(evening != nil)
        #expect(NightlyHRV.night(of: Self.time(2026, 9, 27, 19, 59, in: z), in: z) == nil)
        #expect(NightlyHRV.night(of: Self.time(2026, 9, 28, 6, in: z), in: z) == nil)
    }

    // catches: judging a night by the phone's current zone after travel --
    // a 3 am New York reading is 8 am in London and would fall out of the
    // night entirely.
    @Test func aReadingKeepsTheClockItWasRecordedBy() {
        let threeAMNewYork = Self.time(2026, 9, 28, 3, in: Self.newYork)
        let stamped = NightlyHRV.averages(
            [Self.reading(threeAMNewYork, 60, zone: Self.newYork)], preference: .fitbit, fallbackTimeZone: Self.london
        )
        #expect(stamped.values.first?.milliseconds == 60)
        let unstamped = NightlyHRV.averages(
            [Self.reading(threeAMNewYork, 60)], preference: .fitbit, fallbackTimeZone: Self.london
        )
        #expect(unstamped.isEmpty, "unstamped readings use the fallback zone")
    }

    // catches: a single reading standing in for the night (the 88 ms vs
    // 65 ms mismatch), or a Watch SDNN night blended into a Fitbit RMSSD one.
    @Test func eachNightAveragesItsPreferredSourcesReadings() {
        let z = Self.newYork
        let readings = [
            Self.reading(Self.time(2026, 9, 27, 23, in: z), 50),
            Self.reading(Self.time(2026, 9, 28, 2, in: z), 70),
            Self.reading(Self.time(2026, 9, 28, 5, 50, in: z), 90),
            Self.reading(Self.time(2026, 9, 28, 1, in: z), 40, .appleWatch),
        ]
        let fitbit = NightlyHRV.averages(readings, preference: .fitbit, fallbackTimeZone: z)
        #expect(fitbit.count == 1)
        #expect(fitbit.values.first == NightlyHRV.NightAverage(milliseconds: 70, origin: .fitbit))
        #expect(NightlyHRV.averages(readings, preference: .appleWatch, fallbackTimeZone: z).values.first
                == NightlyHRV.NightAverage(milliseconds: 40, origin: .appleWatch))
    }

    // catches: the tile or readiness taking a night still in progress
    // (half a night's readings) as "last night".
    @Test func aNightCountsOnceItEndsAtSixAM() {
        let z = Self.newYork
        let lastNight = NightlyHRV.night(of: Self.time(2026, 9, 27, 23, in: z), in: z)
        #expect(NightlyHRV.lastCompletedNight(before: Self.time(2026, 9, 28, 6, in: z), in: z) == lastNight)
        #expect(NightlyHRV.lastCompletedNight(before: Self.time(2026, 9, 28, 22, in: z), in: z) == lastNight)
        #expect(NightlyHRV.lastCompletedNight(before: Self.time(2026, 9, 28, 5, 59, in: z), in: z) == lastNight?.adding(days: -1))
    }

    // catches: the baseline including the night it's compared with (the
    // score always near zero), or reaching past 30 nights.
    @Test func theBaselineIsTheThirtyNightsBefore() {
        let night = NightKey(dayNumber: 10_000)
        var averages: [NightKey: NightlyHRV.NightAverage] = [night: Self.fitbit(90), night.adding(days: -31): Self.fitbit(1_000)]
        for back in 1...30 { averages[night.adding(days: -back)] = Self.fitbit(60) }
        #expect(NightlyHRV.baseline(averages, before: night) == 60)
        #expect(NightlyHRV.baseline([night: Self.fitbit(90)], before: night) == nil)
    }

    // catches (WP-74): a watch SDNN night scored against a baseline of
    // Fitbit RMSSD nights -- a 40 ms night against a 60 ms baseline read as
    // a large drop that never happened -- or the reverse.
    @Test func theBaselineComesFromTheNightsOwnDevice() {
        let night = NightKey(dayNumber: 10_000)
        var averages: [NightKey: NightlyHRV.NightAverage] = [night: .init(milliseconds: 40, origin: .appleWatch)]
        for back in 1...29 { averages[night.adding(days: -back)] = Self.fitbit(60) }
        averages[night.adding(days: -30)] = .init(milliseconds: 42, origin: .appleWatch)
        #expect(NightlyHRV.baseline(averages, before: night) == 42)
        averages[night.adding(days: -30)] = Self.fitbit(60)
        #expect(NightlyHRV.baseline(averages, before: night) == nil)
    }

    // catches: a night still in progress, or one more than a week old,
    // shown as current (a watch unworn for a month would read as fresh).
    @Test func theLatestNightIsCompletedAndFresh() {
        let lastCompleted = NightKey(dayNumber: 10_000)
        let tonight = lastCompleted.adding(days: 1)
        #expect(NightlyHRV.latestNight(in: [tonight: Self.fitbit(70), lastCompleted.adding(days: -2): Self.fitbit(60)], lastCompleted: lastCompleted)
                == lastCompleted.adding(days: -2))
        #expect(NightlyHRV.latestNight(in: [lastCompleted.adding(days: -7): Self.fitbit(60)], lastCompleted: lastCompleted) == nil)
        #expect(NightlyHRV.latestNight(in: [lastCompleted: Self.fitbit(55)], lastCompleted: lastCompleted) == lastCompleted)
    }

    // catches (WP-72): the tile's "latest" coming from the other device
    // than its night (RMSSD beside SDNN), an older reading shown as latest,
    // or a reading after `now` (a clock-skewed sample) winning.
    @Test func theLatestReadingIsTheDevicesNewest() {
        let z = Self.newYork
        let now = Self.time(2026, 9, 28, 14, in: z)
        let readings = [
            Self.reading(Self.time(2026, 9, 28, 5, 50, in: z), 38, .fitbit),
            Self.reading(Self.time(2026, 9, 28, 2, in: z), 44, .fitbit),
            Self.reading(Self.time(2026, 9, 28, 13, in: z), 61, .appleWatch),
            Self.reading(Self.time(2026, 9, 28, 15, in: z), 99, .fitbit),
        ]
        #expect(NightlyHRV.latestReading(readings, origin: .fitbit, now: now)?.milliseconds == 38)
        #expect(NightlyHRV.latestReading(readings, origin: .appleWatch, now: now)?.milliseconds == 61)
        #expect(NightlyHRV.latestReading([], origin: .fitbit, now: now) == nil)
    }

    // catches (WP-74, review): the snapshot pairing last night's watch
    // average with a days-old Fitbit reading (the row mixed devices,
    // statistics and a stale value) or with a Fitbit baseline.
    @Test func theSnapshotKeepsEverythingOnTheNightsDevice() throws {
        let z = Self.newYork
        let now = Self.time(2026, 9, 28, 14, in: z)
        var readings = [
            Self.reading(Self.time(2026, 9, 27, 23, in: z), 40, .appleWatch),
            Self.reading(Self.time(2026, 9, 28, 9, in: z), 43, .appleWatch),
            Self.reading(Self.time(2026, 9, 24, 5, 50, in: z), 72, .fitbit),
        ]
        for back in 2...10 { readings.append(Self.reading(Self.time(2026, 9, 28 - back, 23, in: z), 60, .fitbit)) }
        let snapshot = try #require(NightlyHRV.snapshot(readings, preference: .fitbit, timeZone: z, now: now))
        #expect(snapshot.average == NightlyHRV.NightAverage(milliseconds: 40, origin: .appleWatch))
        #expect(snapshot.latest?.milliseconds == 43)
        #expect(snapshot.baseline == nil)
    }

    // catches (WP-74, review): the coach's "latest" HRV being tonight's
    // first reading (a night still in progress), or the morning half of
    // the night the window starts in averaged as a whole night.
    @Test func theCoachGetsWholeCompletedNightsOnly() {
        let z = Self.newYork
        let readings = [
            Self.reading(Self.time(2026, 9, 25, 2, in: z), 99),   // morning half of the 24th's night
            Self.reading(Self.time(2026, 9, 25, 23, in: z), 50),
            Self.reading(Self.time(2026, 9, 26, 23, in: z), 52),
            Self.reading(Self.time(2026, 9, 27, 21, 45, in: z), 95), // tonight, in progress
        ]
        let nights = NightlyHRV.completedNights(
            readings, preference: .fitbit, timeZone: z,
            from: Self.time(2026, 9, 25, 0, in: z), to: Self.time(2026, 9, 27, 22, 30, in: z)
        )
        #expect(nights.map(\.average.milliseconds) == [50, 52])
        // A window starting after 20:00 skips that evening's night too.
        let late = NightlyHRV.completedNights(
            readings, preference: .fitbit, timeZone: z,
            from: Self.time(2026, 9, 25, 21, in: z), to: Self.time(2026, 9, 27, 22, 30, in: z)
        )
        #expect(late.map(\.average.milliseconds) == [52])
    }

    // catches (WP-74): the calendar-free day and hour arithmetic drifting
    // from the calendar's -- around DST changes, in half- and
    // quarter-hour zones, or before the reference date.
    @Test func theNightArithmeticMatchesTheCalendar() throws {
        let zones = ["America/New_York", "Europe/London", "Asia/Kolkata", "Asia/Kathmandu", "Australia/Lord_Howe", "Pacific/Chatham"]
            .compactMap(TimeZone.init(identifier:))
        #expect(zones.count == 6)
        let start = Self.time(2026, 3, 1, 0, in: .gmt)
        for zone in zones {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            for step in 0..<(24 * 4 * 40) {
                let time = start.addingTimeInterval(TimeInterval(step) * 15 * 60 * 2.7)
                let hour = calendar.component(.hour, from: time)
                let day = calendar.startOfDay(for: time)
                let dayKey = NightKey.civilDay(of: time, in: zone)
                let expected: NightKey? = hour >= 20 ? dayKey : hour < 6 ? dayKey.adding(days: -1) : nil
                #expect(NightlyHRV.night(of: time, in: zone) == expected, "\(zone.identifier) \(time)")
                #expect(dayKey.startOfEveningDate(in: calendar) == day, "\(zone.identifier) \(time)")
            }
        }
        let early = Self.time(1999, 12, 31, 22, in: Self.newYork)
        #expect(NightlyHRV.night(of: early, in: Self.newYork)?.startOfEveningDate(in: Self.calendar(Self.newYork))
                == Self.time(1999, 12, 31, 0, in: Self.newYork))
    }

    // catches: the build-21 crash shape -- this runs in HealthKit handlers.
    @Test func runsOffTheMainActor() async {
        let z = Self.newYork
        let readings = [Self.reading(Self.time(2026, 9, 27, 23, in: z), 50)]
        let count = await Task.detached { NightlyHRV.averages(readings, preference: .fitbit, fallbackTimeZone: z).count }.value
        #expect(count == 1)
    }
}
