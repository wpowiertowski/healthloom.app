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
    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "ReadinessScoreHistoryTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func day(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Date())!
    }

    @Test func emptyHistoryYieldsNoRecentScores() throws {
        #expect(ReadinessScoreHistory(defaults: try makeDefaults()).recentScores().isEmpty)
    }

    @Test func todayIsExcludedFromRecentScores() throws {
        let history = ReadinessScoreHistory(defaults: try makeDefaults())
        history.record(score: 80, today: day(-1))
        history.record(score: 90, today: day(0))
        #expect(history.recentScores(today: day(0)) == [80])
    }

    @Test func sameDayRecordReplacesInsteadOfDuplicating() throws {
        let history = ReadinessScoreHistory(defaults: try makeDefaults())
        history.record(score: 80, today: day(0))
        history.record(score: 82, today: day(0))
        #expect(history.recentScores(today: day(1)) == [82])
    }

    @Test func ringCapsAtThirty() throws {
        let history = ReadinessScoreHistory(defaults: try makeDefaults())
        for offset in (-40)...(-1) {
            history.record(score: 70, today: day(offset))
        }
        #expect(history.recentScores(today: day(0)).count == 30)
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
