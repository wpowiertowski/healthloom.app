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

@Suite("ReadinessEngine.contributingSignals")
struct ReadinessContributingSignalsTests {
    @Test("names which signals a score stands on, not just how many")
    // catches: a UI that must show *which* signals reported deriving them
    // from the inputs itself and disagreeing with the engine that weighted
    // them (the score says three, the list shows four).
    func namesTheContributingSignals() {
        let inputs = ReadinessInputs(
            hrvRatio: 1.1,
            restingHRDeltaBeatsPerMinute: -2,
            sleepHours: 7.5
            // priorDayStrain left nil — yesterday's load never arrived.
        )
        let signals = ReadinessEngine.contributingSignals(inputs: inputs)
        #expect(signals == [.hrv, .restingHR, .sleep])
        #expect(!signals.contains(.strain))
        // The set and the score's own count are one fact, not two.
        #expect(ReadinessEngine.score(inputs: inputs).signalsUsed == signals.count)
    }

    @Test("an unusable reading is missing, never a contributing zero")
    // catches: invalid input silently counting as a reporting signal, which
    // would both drag the score toward zero and light a cell the user has
    // no data behind.
    func invalidReadingsDoNotContribute() {
        let inputs = ReadinessInputs(
            hrvRatio: 0,                       // degenerate ratio
            restingHRDeltaBeatsPerMinute: .nan,
            sleepHours: 30,                    // out of 0...24
            priorDayStrain: 1.4                // out of 0...1
        )
        #expect(ReadinessEngine.contributingSignals(inputs: inputs).isEmpty)
        #expect(ReadinessEngine.score(inputs: inputs).signalsUsed == 0)
    }

    @Test("every signal reports when every reading is usable")
    // catches: a signal dropped from the set as the engine gains inputs —
    // `allCases` is what the hero iterates to draw its rows.
    func allFourCanReport() {
        let signals = ReadinessEngine.contributingSignals(inputs: ReadinessInputs(
            hrvRatio: 1.0,
            restingHRDeltaBeatsPerMinute: 0,
            sleepHours: 8,
            sleepEfficiency: 0.9,
            priorDayStrain: 0.3
        ))
        #expect(signals.count == ReadinessSignal.allCases.count)
        #expect(Set(ReadinessSignal.allCases) == signals)
    }
}

@Suite("ReadinessEngine.signalScores")
struct ReadinessSignalScoresTests {
    @Test("the total is exactly the weighted mean of the published subscores")
    // catches: the hero drawing bars from one set of numbers while the score
    // comes from another — the defect that made four full bars sit beside a
    // total of 82 and read as broken arithmetic.
    func totalIsTheWeightedMeanOfTheBars() {
        let inputs = ReadinessInputs(
            hrvRatio: 0.92,
            restingHRDeltaBeatsPerMinute: 3,
            sleepHours: 6.75,
            sleepEfficiency: 0.88,
            priorDayStrain: 0.55
        )
        let scores = ReadinessEngine.signalScores(inputs: inputs)
        #expect(scores.count == 4)

        var weighted = 0.0
        var weights = 0.0
        for signal in ReadinessSignal.allCases {
            guard let subscore = scores[signal] else { continue }
            weighted += ReadinessEngine.weight(of: signal) * subscore
            weights += ReadinessEngine.weight(of: signal)
        }
        let expected = Int((weighted / weights).rounded())
        #expect(ReadinessEngine.score(inputs: inputs).score == expected)
    }

    @Test("a partial day renormalises over the signals that reported")
    // catches: a missing signal being treated as a zero subscore, which would
    // drag the total down while its bar sat empty and unexplained.
    func partialDayRenormalises() {
        let inputs = ReadinessInputs(hrvRatio: 1.0, restingHRDeltaBeatsPerMinute: 0)
        let scores = ReadinessEngine.signalScores(inputs: inputs)
        #expect(scores.keys.sorted { $0.rawValue < $1.rawValue } == [.hrv, .restingHR])
        // Both reported subscores are 100, so the total is 100 — not 50,
        // which is what counting the two absent signals as zero would give.
        #expect(ReadinessEngine.score(inputs: inputs).score == 100)
    }

    @Test("every published subscore sits on the score's own 0...100 scale")
    // catches: a subscore escaping 0...100, which would render a bar wider
    // than its track or inverted.
    func subscoresShareTheScoreScale() {
        let extremes = ReadinessInputs(
            hrvRatio: 0.01,
            restingHRDeltaBeatsPerMinute: 400,
            sleepHours: 0,
            sleepEfficiency: 0,
            priorDayStrain: 1
        )
        for (_, subscore) in ReadinessEngine.signalScores(inputs: extremes) {
            #expect(subscore >= 0 && subscore <= 100)
        }
    }
}
