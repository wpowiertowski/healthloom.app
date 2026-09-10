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
    @Test func zeroSignalsMapsToPending() {
        #expect(ReadinessInputsProvider.display(Readiness(score: 50, signalsUsed: 0)) == .pending)
    }

    @Test func scoredPassesNilDeltaThrough() {
        // H1: a missing delta stays nil so the hero renders the based-on-N
        // caption — the old `?? 0` coercion rendered a "+0 vs 30-day
        // average" against an average that didn't exist.
        #expect(ReadinessInputsProvider.display(Readiness(
            score: 82, deltaVsAverage: 6, signalsUsed: 4
        )) == .scored(score: 82, deltaVsBaseline: 6, signalsUsed: 4))
        #expect(ReadinessInputsProvider.display(Readiness(
            score: 78, deltaVsAverage: nil, signalsUsed: 4
        )) == .scored(score: 78, deltaVsBaseline: nil, signalsUsed: 4))
        #expect(ReadinessInputsProvider.display(Readiness(
            score: 70, deltaVsAverage: nil, signalsUsed: 2
        )) == .scored(score: 70, deltaVsBaseline: nil, signalsUsed: 2))
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
