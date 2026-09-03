// ReadinessEngineTests.swift
//
// WP-23 "Tests" line: golden vectors (inputs → exact score),
// missing-signal renormalization, delta math, monotonicity (better HRV never
// lowers the score). Pure engine -- no container, no model.

import Foundation
import Testing

@testable import CoachKit

@Suite("ReadinessEngine golden vectors")
struct ReadinessGoldenTests {
    @Test("solid day scores 93 with delta +3 on four signals")
    func solidDay() {
        let inputs = ReadinessInputs(
            hrvRatio: 1.05,
            restingHRDeltaBeatsPerMinute: 1.0,
            sleepHours: 7.5,
            sleepEfficiency: 0.88,
            priorDayStrain: 0.4
        )
        let readiness = ReadinessEngine.score(inputs: inputs, recentScores: [88, 90, 92])
        #expect(readiness.score == 93)
        #expect(readiness.deltaVsAverage == 3)
        #expect(readiness.signalsUsed == 4)
    }

    @Test("missing HRV and strain renormalize to 76 on two signals")
    func missingSignalsRenormalize() {
        let inputs = ReadinessInputs(
            restingHRDeltaBeatsPerMinute: 2.0,
            sleepHours: 6.0
        )
        let readiness = ReadinessEngine.score(inputs: inputs)
        #expect(readiness.score == 76)
        #expect(readiness.signalsUsed == 2)
        #expect(readiness.deltaVsAverage == nil)
    }

    @Test("rough night scores 56 on four signals")
    func roughNight() {
        let inputs = ReadinessInputs(
            hrvRatio: 0.7,
            restingHRDeltaBeatsPerMinute: 6.0,
            sleepHours: 5.0,
            sleepEfficiency: 0.75,
            priorDayStrain: 0.9
        )
        let readiness = ReadinessEngine.score(inputs: inputs, recentScores: [70, 72])
        #expect(readiness.score == 56)
        #expect(readiness.signalsUsed == 4)
        #expect(readiness.deltaVsAverage == 56 - 71)
    }

    @Test("no usable signal yields unknown 50 with zero signals")
    func noSignalsIsUnknown() {
        #expect(ReadinessEngine.score(inputs: ReadinessInputs()) == Readiness(score: 50, deltaVsAverage: nil, signalsUsed: 0))
        // Invalid readings degrade to missing, never to zero-scored signals.
        let invalid = ReadinessInputs(
            hrvRatio: -1.0,
            restingHRDeltaBeatsPerMinute: .nan,
            sleepHours: 25.0,
            sleepEfficiency: 1.5,
            priorDayStrain: 2.0
        )
        let readiness = ReadinessEngine.score(inputs: invalid, recentScores: [80])
        #expect(readiness.score == 50)
        #expect(readiness.signalsUsed == 0)
        #expect(readiness.deltaVsAverage == nil)
    }

    @Test("efficiency alone does not make a sleep signal")
    func efficiencyAloneIsNotSleep() {
        let readiness = ReadinessEngine.score(inputs: ReadinessInputs(sleepEfficiency: 0.95))
        #expect(readiness.signalsUsed == 0)
    }
}

@Suite("ReadinessEngine properties")
struct ReadinessPropertyTests {
    @Test("better HRV never lowers the score")
    func hrvMonotonic() {
        let base = ReadinessInputs(
            restingHRDeltaBeatsPerMinute: 1.0,
            sleepHours: 7.5,
            sleepEfficiency: 0.88,
            priorDayStrain: 0.4
        )
        var previous = -1
        for ratio in stride(from: 0.4, through: 1.6, by: 0.05) {
            var inputs = base
            inputs.hrvRatio = ratio
            let score = ReadinessEngine.score(inputs: inputs).score
            #expect(score >= previous, "ratio \(ratio) lowered the score to \(score)")
            previous = score
        }
    }

    @Test("better resting-HR delta never lowers the score")
    func restingHRMonotonic() {
        let base = ReadinessInputs(hrvRatio: 1.0, sleepHours: 8.0, priorDayStrain: 0.2)
        var previous = -1
        for delta in stride(from: 12.0, through: -4.0, by: -0.5) {
            var inputs = base
            inputs.restingHRDeltaBeatsPerMinute = delta
            let score = ReadinessEngine.score(inputs: inputs).score
            #expect(score >= previous, "delta \(delta) lowered the score to \(score)")
            previous = score
        }
    }

    @Test("scores clamp to 0-100 at extremes")
    func clamps() {
        // Strain omitted: present-but-maximal strain still contributes 55,
        // so the true floor needs every present signal bottomed out.
        let worst = ReadinessInputs(
            hrvRatio: 0.1,
            restingHRDeltaBeatsPerMinute: 30.0,
            sleepHours: 0.0,
            sleepEfficiency: 0.0
        )
        #expect(ReadinessEngine.score(inputs: worst).score == 0)
        let best = ReadinessInputs(
            hrvRatio: 2.0,
            restingHRDeltaBeatsPerMinute: -10.0,
            sleepHours: 8.0,
            sleepEfficiency: 1.0,
            priorDayStrain: 0.0
        )
        #expect(ReadinessEngine.score(inputs: best).score == 100)
    }

    @Test("delta rounds against the recent average")
    func deltaMath() {
        let inputs = ReadinessInputs(hrvRatio: 1.0, restingHRDeltaBeatsPerMinute: 0, sleepHours: 8.0)
        // Subscores: 100, 100, 100 → 100 regardless of renormalization.
        #expect(ReadinessEngine.score(inputs: inputs, recentScores: [90]).deltaVsAverage == 10)
        #expect(ReadinessEngine.score(inputs: inputs, recentScores: []).deltaVsAverage == nil)
    }
}

@Suite("ReadinessEngine edge cases")
struct ReadinessEdgeTests {
    @Test("NaN payloads compare and hash soundly")
    func nanEquality() {
        let a = ReadinessInputs(hrvRatio: .nan, sleepHours: 8.0)
        let b = ReadinessInputs(hrvRatio: .nan, sleepHours: 8.0)
        #expect(a == b)
        #expect(a == a)
        var set = Set<ReadinessInputs>()
        set.insert(a)
        set.insert(b)
        #expect(set.count == 1)
        #expect(a != ReadinessInputs(hrvRatio: 1.0, sleepHours: 8.0))
        #expect(ReadinessInputs() == ReadinessInputs())
    }

    @Test("corrupt score history cannot trap the average")
    func corruptHistoryDoesNotTrap() {
        // [Int.min] averages to -2^63; score minus that overflows Int, so
        // the clamped extreme stands in -- deterministic, never a trap.
        // (Non-negative histories always fit: at most score - 0 magnitude.)
        let inputs = ReadinessInputs(hrvRatio: 1.0)
        let readiness = ReadinessEngine.score(inputs: inputs, recentScores: [Int.min, Int.min])
        #expect(readiness.signalsUsed == 1)
        #expect(readiness.deltaVsAverage == Int.max)
        // Mirror image on the other extreme (2^63 - 100 rounds back to a
        // representable value, so this one lands exactly on Int.min).
        let sane = ReadinessEngine.score(inputs: inputs, recentScores: [Int.max, Int.max])
        #expect(sane.deltaVsAverage == Int.min)
    }

    @Test("zero HRV ratio is missing, not bottomed")
    func zeroRatioIsMissing() {
        // A degenerate exact-zero reading drops the signal (documented
        // alongside negatives) instead of scoring it at the floor.
        let readiness = ReadinessEngine.score(inputs: ReadinessInputs(hrvRatio: 0.0))
        #expect(readiness.signalsUsed == 0)
        #expect(readiness.score == 50)
    }
}
