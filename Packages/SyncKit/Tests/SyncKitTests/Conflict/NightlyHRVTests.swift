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
        #expect(stamped.values.first == 60)
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
        #expect(fitbit.values.first == 70)
        #expect(NightlyHRV.averages(readings, preference: .appleWatch, fallbackTimeZone: z).values.first == 40)
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
        var averages: [NightKey: Double] = [night: 90, night.adding(days: -31): 1_000]
        for back in 1...30 { averages[night.adding(days: -back)] = 60 }
        #expect(NightlyHRV.baseline(averages, before: night) == 60)
        #expect(NightlyHRV.baseline([night: 90], before: night) == nil)
    }

    // catches: a night still in progress, or one more than a week old,
    // shown as current (a watch unworn for a month would read as fresh).
    @Test func theLatestNightIsCompletedAndFresh() {
        let lastCompleted = NightKey(dayNumber: 10_000)
        let tonight = lastCompleted.adding(days: 1)
        #expect(NightlyHRV.latestNight(in: [tonight: 70, lastCompleted.adding(days: -2): 60], lastCompleted: lastCompleted)
                == lastCompleted.adding(days: -2))
        #expect(NightlyHRV.latestNight(in: [lastCompleted.adding(days: -7): 60], lastCompleted: lastCompleted) == nil)
        #expect(NightlyHRV.latestNight(in: [lastCompleted: 55], lastCompleted: lastCompleted) == lastCompleted)
    }

    // catches: the build-21 crash shape -- this runs in HealthKit handlers.
    @Test func runsOffTheMainActor() async {
        let z = Self.newYork
        let readings = [Self.reading(Self.time(2026, 9, 27, 23, in: z), 50)]
        let count = await Task.detached { NightlyHRV.averages(readings, preference: .fitbit, fallbackTimeZone: z).count }.value
        #expect(count == 1)
    }
}
