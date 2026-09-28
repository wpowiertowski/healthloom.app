// TodayReadinessTests.swift
//
// WP-33 step 1's readiness binding: the pure half of
// `ReadinessInputsProvider` (aggregates -> engine inputs), the
// `ReadinessScoreHistory` ring, and the engine-result -> hero mapping.
// HealthKit fetching itself is untestable on purpose (same posture as
// `TodayMetricsProvider`); the simulator UI test covers the pending hero.

import CoachKit
import CoreModel
import Foundation
import Testing
@testable import HealthLoom
import SyncKit

@Suite("ReadinessInputsProvider.assemble")
struct ReadinessAssembleTests {
    @Test func fullAggregatesAssemble() {
        let inputs = ReadinessInputsProvider.assemble(ReadinessAggregates(
            hrvLatestMs: 60,
            hrvBaselineMs: 50,
            restingHRLatestBpm: 62,
            restingHRBaselineBpm: 60,
            sleepSeconds: 7.5 * 3600,
            sleepEfficiency: 0.92,
            priorDayWorkoutKcal: 400
        ))
        #expect(inputs.hrvRatio == 1.2)
        #expect(inputs.restingHRDeltaBeatsPerMinute == 2)
        #expect(inputs.sleepHours == 7.5)
        #expect(inputs.sleepEfficiency == 0.92)
        #expect(inputs.priorDayStrain == 0.5)
    }

    @Test func strainCapsAtOneAndFloorsAtZero() {
        #expect(ReadinessInputsProvider.assemble(ReadinessAggregates(priorDayWorkoutKcal: 1600)).priorDayStrain == 1)
        #expect(ReadinessInputsProvider.assemble(ReadinessAggregates(priorDayWorkoutKcal: 0)).priorDayStrain == 0)
    }

    @Test func zeroHRVBaselineYieldsNoRatio() {
        // A zero baseline is a data gap, not a superhuman ratio.
        #expect(ReadinessInputsProvider.assemble(ReadinessAggregates(
            hrvLatestMs: 60, hrvBaselineMs: 0
        )).hrvRatio == nil)
    }

    @Test func emptyAggregatesAssembleToEmptyInputs() {
        let inputs = ReadinessInputsProvider.assemble(ReadinessAggregates())
        #expect(inputs == ReadinessInputs())
    }
}

@Suite("ReadinessScoreHistory")
struct ReadinessScoreHistoryTests {
    private func makeDefaults() throws -> EphemeralDefaults {
        try EphemeralDefaults(prefix: "readiness")
    }

    private func day(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Date())!
    }

    // catches: pre-WP-57 scores (sleep double-counted) feeding the
    // "vs 30-day average" caption for a month after the fix, and the
    // launch cleanup not removing them.
    @Test func scoresFromTheRetiredKeyAreDropped() throws {
        let ephemeral = try makeDefaults()
        ephemeral.defaults.set([[ReadinessScoreHistory.dayString(day(-1)), "95"]], forKey: ReadinessScoreHistory.retiredDefaultsKey)
        let history = ReadinessScoreHistory(defaults: ephemeral.defaults)
        #expect(history.recentScores(today: day(0)).isEmpty)
        ReadinessScoreHistory.removeRetiredHistory(defaults: ephemeral.defaults)
        #expect(ephemeral.defaults.object(forKey: ReadinessScoreHistory.retiredDefaultsKey) == nil)
    }

    // catches: the init writing defaults again. TodayView builds one per
    // render; a write posts a change notification mid-render, which fed the
    // render loop that got the app killed by the watchdog (WP-69).
    @Test func buildingAHistoryWritesNothing() throws {
        let ephemeral = try makeDefaults()
        ephemeral.defaults.set([["2026-09-01", "80"]], forKey: ReadinessScoreHistory.retiredDefaultsKey)
        final class Posts: @unchecked Sendable { var count = 0 }
        let posts = Posts()
        let token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: ephemeral.defaults, queue: nil
        ) { _ in posts.count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        _ = ReadinessScoreHistory(defaults: ephemeral.defaults)
        #expect(posts.count == 0)
        #expect(ephemeral.defaults.object(forKey: ReadinessScoreHistory.retiredDefaultsKey) != nil)
    }

    @Test func emptyHistoryYieldsNoRecentScores() throws {
        let ephemeral1 = try makeDefaults()
        #expect(ReadinessScoreHistory(defaults: ephemeral1.defaults).recentScores().isEmpty)
    }

    @Test func todayIsExcludedFromRecentScores() throws {
        let ephemeral2 = try makeDefaults()
        let history = ReadinessScoreHistory(defaults: ephemeral2.defaults)
        history.record(score: 80, today: day(-1))
        history.record(score: 90, today: day(0))
        #expect(history.recentScores(today: day(0)) == [80])
    }

    @Test func sameDayRecordReplacesInsteadOfDuplicating() throws {
        let ephemeral3 = try makeDefaults()
        let history = ReadinessScoreHistory(defaults: ephemeral3.defaults)
        history.record(score: 80, today: day(0))
        history.record(score: 82, today: day(0))
        #expect(history.recentScores(today: day(1)) == [82])
    }

    @Test func staleEntriesExcludedFromAverageWindow() throws {
        // Round-8 item 14: a 60-day-old score must not enter the
        // "30-day average" — the ring alone kept everything.
        let ephemeral5 = try makeDefaults()
        let history = ReadinessScoreHistory(defaults: ephemeral5.defaults)
        history.record(score: 90, today: day(-60))
        history.record(score: 80, today: day(-10))
        #expect(history.recentScores(today: day(0)) == [80])
    }

    @Test func insightsOffDailyOpensAccumulateHistory() throws {
        // Round-10 item 5: drives the view path's exact calls
        // (assemble -> score -> record) across three days with
        // signals and NO MorningInsightRunner anywhere — history
        // accumulates from Today opens alone and the delta appears,
        // independent of the morning-insights toggle.
        let ephemeral6 = try makeDefaults()
        let history = ReadinessScoreHistory(defaults: ephemeral6.defaults)
        let inputs = ReadinessInputsProvider.assemble(ReadinessAggregates(
            hrvLatestMs: 60, hrvBaselineMs: 50,
            restingHRLatestBpm: 62, restingHRBaselineBpm: 60,
            sleepSeconds: 7.5 * 3600, sleepEfficiency: 0.92,
            priorDayWorkoutKcal: 400
        ))
        for offset in [-2, -1, 0] {
            let result = ReadinessEngine.score(inputs: inputs, recentScores: history.recentScores(today: day(offset)))
            #expect(result.signalsUsed > 0)
            history.record(score: result.score, today: day(offset))
        }
        #expect(history.recentScores(today: day(0)).count == 2)
        let final = ReadinessEngine.score(inputs: inputs, recentScores: history.recentScores(today: day(0)))
        #expect(final.deltaVsAverage != nil)
    }

    @Test func fullWindowCoversThirtyDays() throws {
        // Round-9 item 10: 31 consecutive days recorded — the average
        // must cover exactly the 30 promised (today excluded, oldest
        // in-window day kept). Pre-fix the 30-cap dropped the oldest
        // in-window day and the average covered 29.
        let ephemeral5 = try makeDefaults()
        let history = ReadinessScoreHistory(defaults: ephemeral5.defaults)
        for offset in (-30)...0 {
            history.record(score: 70 + offset, today: day(offset))
        }
        let recent = history.recentScores(today: day(0))
        #expect(recent.count == 30)
        #expect(recent.first == 70 - 30)
        #expect(recent.last == 70 - 1)
    }

    @Test func ringCapsAtThirty() throws {
        let ephemeral4 = try makeDefaults()
        let history = ReadinessScoreHistory(defaults: ephemeral4.defaults)
        for offset in (-40)...(-1) {
            history.record(score: 70, today: day(offset))
        }
        #expect(history.recentScores(today: day(0)).count == 30)
    }

    @Test func dayKeysAreGregorianPOSIXRegardlessOfHost() throws {
        // Round-4-sync item 13: the key for a known instant must be the
        // Gregorian `yyyy-MM-dd` — never a Buddhist `2569-…` or
        // Japanese-era key. The reference is computed with an
        // explicitly-constructed Gregorian/POSIX formatter IN THE TEST,
        // so the comparison holds on any host: pre-fix this fails on a
        // non-Gregorian host (verify by running the suite under a
        // Buddhist-calendar locale — pre-fix yields `2569-…`); post-fix
        // the formatter's own explicit calendar/locale make host
        // agreement a contract, not luck.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "Etc/UTC"))
        let instant = try #require(utc.date(from: DateComponents(year: 2026, month: 9, day: 8, hour: 12)))
        // Same time-zone basis as the unit under test (the ring's day
        // is the USER's day — system zone is correct there); the
        // calendars/locales differ, which is the whole assertion.
        let reference = DateFormatter()
        reference.locale = Locale(identifier: "en_US_POSIX")
        reference.calendar = Calendar(identifier: .gregorian)
        reference.timeZone = .current
        reference.dateFormat = "yyyy-MM-dd"
        #expect(ReadinessScoreHistory.dayString(instant) == reference.string(from: instant))
    }
}

@Suite("ReadinessInputsProvider.display")
struct ReadinessDisplayMappingTests {
    /// Four usable readings — the full-signal day.
    private static let fullInputs = ReadinessInputs(
        hrvRatio: 1.05,
        restingHRDeltaBeatsPerMinute: -1,
        sleepHours: 7.2,
        sleepEfficiency: 0.9,
        priorDayStrain: 0.4
    )
    /// Sleep and prior-day load never arrived.
    private static let partialInputs = ReadinessInputs(
        hrvRatio: 1.05,
        restingHRDeltaBeatsPerMinute: -1
    )

    @Test func zeroSignalsMapsToPending() {
        #expect(ReadinessInputsProvider.display(
            Readiness(score: 50, signalsUsed: 0),
            inputs: ReadinessInputs()
        ) == .pending)
    }

    @Test func scoredPassesNilDeltaThrough() {
        // H1: a missing delta stays nil so the hero explains the absent
        // comparison — the old `?? 0` coercion rendered a "+0 vs 30-day
        // average" against an average that didn't exist.
        let full = ReadinessEngine.signalScores(inputs: Self.fullInputs)
        #expect(ReadinessInputsProvider.display(
            Readiness(score: 82, deltaVsAverage: 6, signalsUsed: 4),
            inputs: Self.fullInputs
        ) == .scored(score: 82, deltaVsBaseline: 6, signalScores: full))
        #expect(ReadinessInputsProvider.display(
            Readiness(score: 78, deltaVsAverage: nil, signalsUsed: 4),
            inputs: Self.fullInputs
        ) == .scored(score: 78, deltaVsBaseline: nil, signalScores: full))
    }

    @Test("a partial day carries only the signals that reported, with their subscores")
    // catches: the hero being handed presence instead of magnitude — bars
    // drawn full for every reporting signal regardless of how it scored,
    // which put four full bars beside a total of 82.
    func partialDayCarriesSubscores() {
        let display = ReadinessInputsProvider.display(
            Readiness(score: 70, deltaVsAverage: nil, signalsUsed: 2),
            inputs: Self.partialInputs
        )
        guard case .scored(_, _, let scores) = display else {
            Issue.record("expected a scored display, got \(display)")
            return
        }
        #expect(Set(scores.keys) == [.hrv, .restingHR])
        // The values are the engine's, not re-derived here.
        #expect(scores == ReadinessEngine.signalScores(inputs: Self.partialInputs))
        // And they are real magnitudes on the score's own scale, not flags.
        for (_, subscore) in scores {
            #expect(subscore >= 0 && subscore <= 100)
        }
    }
}

@Suite("TodayView.isCurrentMorningInsight")
struct CurrentMorningInsightTests {
    @Test("only today's own insights count (F3)") func currentOnly() {
        let now = Date()
        let calendar = Calendar.current
        let today = DerivedInsight(
            text: "today",
            createdAt: now,
            sourceProvider: "morningInsight.onDevice"
        )
        #expect(TodayView.isCurrentMorningInsight(today, now: now, calendar: calendar))
        let staleDate = calendar.date(byAdding: .day, value: -1, to: now) ?? now.addingTimeInterval(-86400)
        let yesterday = DerivedInsight(
            text: "stale",
            createdAt: staleDate,
            sourceProvider: "morningInsight.onDevice"
        )
        #expect(!TodayView.isCurrentMorningInsight(yesterday, now: now, calendar: calendar))
        let foreign = DerivedInsight(text: "other", createdAt: now, sourceProvider: "onDevice")
        #expect(!TodayView.isCurrentMorningInsight(foreign, now: now, calendar: calendar))
    }
}

// MARK: - WP-46 / D16.8: signal fields

@Suite("SignalIndex fields")
struct SignalIndexFieldTests {
    // catches: two signals sharing a concrete field, so their bars can't be
    // told apart, or a remap away from the locked mockup's assignment.
    @Test func eachSignalHasTheMockupsField() {
        #expect(SignalIndex.field(.sleep) == .slate)
        #expect(SignalIndex.field(.hrv) == .rust)
        #expect(SignalIndex.field(.restingHR) == .ochre)
        #expect(SignalIndex.field(.strain) == .sky)
        let fields = ReadinessSignal.allCases.map(SignalIndex.field)
        #expect(Set(fields).count == ReadinessSignal.allCases.count)
    }
}

@Suite("LastNightSleep")
struct LastNightSleepTests {
    static let bedtime = Date(timeIntervalSince1970: 1_790_463_600) // an evening, 23:00 UTC
    /// Wide enough to hold every fixture night below.
    static let wholeNight = DateInterval(start: bedtime.addingTimeInterval(-6 * 3600), duration: 20 * 3600)

    static func interval(_ startHours: Double, _ endHours: Double) -> DateInterval {
        DateInterval(
            start: bedtime.addingTimeInterval(startHours * 3600),
            end: bedtime.addingTimeInterval(endHours * 3600)
        )
    }

    static func stage(_ value: Int, _ startHours: Double, _ endHours: Double, from origin: SleepOrigin = .fitbit) -> SleepStageSample {
        SleepStageSample(value: value, interval: interval(startHours, endHours), origin: origin)
    }

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    // catches: overlapping stages counting twice (14 h instead of 7), in
    // hours or in efficiency. The in-bed sample makes the span 8 h: the
    // double count (13.5 h ÷ 8) would clamp to 100%, the right answer is
    // 7/8. (One source here; two devices' nights are a source choice, see
    // below.)
    @Test func aNightRecordedTwiceCountsOnce() throws {
        let samples = [
            Self.stage(0, -1, 0),     // inBed
            Self.stage(3, 0, 7),      // asleepCore
            Self.stage(1, 0.5, 7),    // asleepUnspecified, overlapping
        ]
        let summary = try #require(LastNightSleep.summary(of: samples, in: Self.wholeNight, preference: .fitbit))
        #expect(summary.asleep == 7.0 * 3600)
        #expect(summary.efficiency == 7.0 / 8.0)
        #expect(summary.wokeAt == Self.interval(0, 7).end)
    }

    // catches: awake and in-bed time counted as sleep, or left out of the
    // span efficiency divides by.
    @Test func awakeTimeWidensTheSpanButIsNotSleep() throws {
        let samples = [
            Self.stage(0, -0.5, 0),   // inBed
            Self.stage(4, 0, 3),      // asleepDeep
            Self.stage(2, 3, 3.5),    // awake
            Self.stage(5, 3.5, 7.5),  // asleepREM
        ]
        let summary = try #require(LastNightSleep.summary(of: samples, in: Self.wholeNight, preference: .fitbit))
        #expect(summary.asleep == 7.0 * 3600)
        #expect(summary.efficiency == 7.0 / 8.0)
        #expect(LastNightSleep.summary(of: [Self.stage(2, 0, 1)], in: Self.wholeNight, preference: .fitbit) == nil)
    }

    // catches: the Fitbit's awake stretch counted as sleep because the
    // watch called it asleep (the WP-57 union), and the preference not
    // choosing whose night it is (WP-60).
    @Test func oneSourceWinsANightBothRecorded() throws {
        let samples = [
            Self.stage(3, 0, 3, from: .fitbit),
            Self.stage(2, 3, 4, from: .fitbit),       // awake 40+ min
            Self.stage(3, 4, 7, from: .fitbit),
            Self.stage(3, 0, 7.5, from: .appleWatch), // one long asleep stretch
        ]
        let fitbit = try #require(LastNightSleep.summary(of: samples, in: Self.wholeNight, preference: .fitbit))
        #expect(fitbit.asleep == 6.0 * 3600)
        #expect(fitbit.efficiency == 6.0 / 7.0)
        let watch = try #require(LastNightSleep.summary(of: samples, in: Self.wholeNight, preference: .appleWatch))
        #expect(watch.asleep == 7.5 * 3600)
    }

    // catches: a sample straddling the window edge adding its full length --
    // an evening nap from 4:30 pm counted 2 h toward last night and dragged
    // efficiency down by stretching the span back to 4:30 pm.
    @Test func samplesAreClippedToTheWindow() throws {
        let window = DateInterval(start: Self.bedtime.addingTimeInterval(-5 * 3600), end: Self.bedtime.addingTimeInterval(8 * 3600))
        let samples = [
            Self.stage(3, -6.5, -4.5),  // nap 4:30-6:30 pm; the window opens at 6 pm
            Self.stage(3, 0, 7),
        ]
        let summary = try #require(LastNightSleep.summary(of: samples, in: window, preference: .fitbit))
        #expect(summary.asleep == 7.5 * 3600)
        #expect(summary.efficiency == 7.5 / 12)
    }

    // catches: the Today row and the readiness score reading different
    // nights (the row ran to now and took in an afternoon nap), and a
    // window edge built by adding hours, which lands an hour off on a
    // daylight-saving night.
    @Test func theWindowRunsFromSixPMToNoon() throws {
        let calendar = Self.utc
        let afternoon = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 16)))
        let window = try #require(LastNightSleep.window(now: afternoon, calendar: calendar))
        #expect(window.start == calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 18)))
        #expect(window.end == calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 12)))

        let morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 7)))
        #expect(LastNightSleep.window(now: morning, calendar: calendar)?.end == morning)

        var london = Calendar(identifier: .gregorian)
        london.timeZone = try #require(TimeZone(identifier: "Europe/London"))
        let fallBackAfternoon = try #require(london.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 15)))
        let fallBack = try #require(LastNightSleep.window(now: fallBackAfternoon, calendar: london))
        #expect(london.component(.hour, from: fallBack.start) == 18)
        #expect(london.component(.hour, from: fallBack.end) == 12)
    }

    // catches: the build-21 crash shape -- this runs inside HealthKit's
    // result handler, off the main actor; with main-actor isolation these
    // calls no longer compile.
    @Test func runsOffTheMainActor() async {
        let samples = [Self.stage(3, 0, 7), Self.stage(1, 1, 8)]
        let window = Self.wholeNight
        let asleep = await Task.detached { LastNightSleep.summary(of: samples, in: window, preference: .fitbit)?.asleep }.value
        #expect(asleep == 8.0 * 3600)
        let calendar = Self.utc
        let now = Self.bedtime
        #expect(await Task.detached { LastNightSleep.window(now: now, calendar: calendar) }.value != nil)
    }
}

@Suite("Readiness prior-day strain")
struct ReadinessStrainTests {
    static let today = Date(timeIntervalSince1970: 1_790_467_200) // midnight UTC
    static let priorDay = DateInterval(start: today.addingTimeInterval(-86_400), end: today)

    // catches: a rest day reading as a missing signal ("3 of 4 signals",
    // no rest credit) for someone who does log workouts.
    @Test func aRestDayIsZeroStrain() throws {
        let lastWeek = (start: Self.today.addingTimeInterval(-5 * 86_400), kcal: 600.0)
        let kcal = try #require(ReadinessInputsProvider.priorDayKcal(workouts: [lastWeek], priorDay: Self.priorDay))
        #expect(kcal == 0)
        #expect(ReadinessInputsProvider.assemble(ReadinessAggregates(priorDayWorkoutKcal: kcal)).priorDayStrain == 0)
    }

    // catches: inventing a daily rest signal when HealthKit returns nothing
    // at all (a denied read looks exactly like no workouts).
    @Test func noWorkoutsInThirtyDaysIsNoSignal() {
        #expect(ReadinessInputsProvider.priorDayKcal(workouts: [], priorDay: Self.priorDay) == nil)
    }

    // catches: summing workouts outside yesterday into its strain.
    @Test func onlyYesterdaysWorkoutsCount() {
        let workouts = [
            (start: Self.priorDay.start.addingTimeInterval(8 * 3600), kcal: 300.0),
            (start: Self.priorDay.start.addingTimeInterval(18 * 3600), kcal: 150.0),
            (start: Self.priorDay.start.addingTimeInterval(-3600), kcal: 900.0),
        ]
        #expect(ReadinessInputsProvider.priorDayKcal(workouts: workouts, priorDay: Self.priorDay) == 450)
    }
}

@Suite("SleepSourcePreferences")
@MainActor
struct SleepSourcePreferencesTests {
    // catches: the picker writing a key the sleep readers don't read (they
    // call `SleepSourcePreference.current()`), or not persisting at all.
    @Test func thePickerWritesWhatTheReadersRead() throws {
        let ephemeral = try EphemeralDefaults(prefix: "sleepsource")
        let preferences = SleepSourcePreferences(defaults: ephemeral.defaults)
        #expect(preferences.source == .fitbit)
        preferences.setSource(.appleWatch)
        #expect(SleepSourcePreference.current(defaults: ephemeral.defaults) == .appleWatch)
        #expect(SleepSourcePreferences(defaults: ephemeral.defaults).source == .appleWatch)
    }
}
