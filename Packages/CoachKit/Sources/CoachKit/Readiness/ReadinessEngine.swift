// ReadinessEngine.swift
//
// WP-23 (implementation-plan.md) / architecture.md D6: readiness is computed
// deterministically, never by the LLM. The Today hero score comes from here;
// the coach may explain it (it's in the `KnowledgeProfile`) but never invents
// it. Pure and unit-testable (golden vectors pin the formula); identical
// behavior across every model tier.
//
// `@MainActor` via the package default -- everything here is value-type math,
// so isolation is irrelevant, but consistency with the package is free.

import Foundation

/// Numeric inputs to one readiness scoring. All optional: missing signals
/// renormalize (weights rescale over the present signals) and are reported
/// via `Readiness.signalsUsed` ("based on N of 4 signals", D6). Sourcing
/// these numbers from HealthKit reads is later wiring (WP-33's Today hero);
/// this engine deliberately takes them as parameters so the formula stays
/// testable without a store or entitlements.
///
/// NaN-aware equality: a `.nan` payload compares equal to another `.nan`
/// (and hashes like one) instead of violating `Equatable` reflexivity, so
/// this type is safe in sets, as dictionary keys, and in SwiftUI identity
/// positions once WP-33 wires real HealthKit ratios through it.
public struct ReadinessInputs: Sendable, Hashable {
    /// Latest HRV (SDNN) divided by its 30-day baseline. Above 1 is better.
    public var hrvRatio: Double?

    /// Latest resting HR minus its 30-day baseline, in bpm. Negative (below
    /// baseline) is better.
    public var restingHRDeltaBeatsPerMinute: Double?

    /// Last night's total sleep, in hours.
    public var sleepHours: Double?

    /// Last night's sleep efficiency as a fraction (0-1). Modifier on sleep.
    public var sleepEfficiency: Double?

    /// Prior-day training load, 0 (full rest) to 1 (maximal). Higher load
    /// lowers today's readiness (recovery demand).
    public var priorDayStrain: Double?

    public init(
        hrvRatio: Double? = nil,
        restingHRDeltaBeatsPerMinute: Double? = nil,
        sleepHours: Double? = nil,
        sleepEfficiency: Double? = nil,
        priorDayStrain: Double? = nil
    ) {
        self.hrvRatio = hrvRatio
        self.restingHRDeltaBeatsPerMinute = restingHRDeltaBeatsPerMinute
        self.sleepHours = sleepHours
        self.sleepEfficiency = sleepEfficiency
        self.priorDayStrain = priorDayStrain
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        func eq(_ a: Double?, _ b: Double?) -> Bool {
            switch (a, b) {
            case (nil, nil):
                return true
            case let (x?, y?):
                return x == y || (x.isNaN && y.isNaN)
            case (_?, nil), (nil, _?):
                return false
            }
        }
        return eq(lhs.hrvRatio, rhs.hrvRatio)
            && eq(lhs.restingHRDeltaBeatsPerMinute, rhs.restingHRDeltaBeatsPerMinute)
            && eq(lhs.sleepHours, rhs.sleepHours)
            && eq(lhs.sleepEfficiency, rhs.sleepEfficiency)
            && eq(lhs.priorDayStrain, rhs.priorDayStrain)
    }

    public func hash(into hasher: inout Hasher) {
        // NaN hashes as nil so equal values (NaN == NaN above) hash equally;
        // nil-vs-NaN collisions are harmless, divergence would not be.
        func norm(_ v: Double?) -> Double? {
            guard let v, !v.isNaN else { return nil }
            return v
        }
        hasher.combine(norm(hrvRatio))
        hasher.combine(norm(restingHRDeltaBeatsPerMinute))
        hasher.combine(norm(sleepHours))
        hasher.combine(norm(sleepEfficiency))
        hasher.combine(norm(priorDayStrain))
    }
}

/// Deterministic readiness result for one morning.
public struct Readiness: Sendable, Equatable, Hashable {
    /// 0-100 score. 50 with `signalsUsed == 0` means "unknown" (no usable
    /// signal) -- callers gate the hero's pending state on `signalsUsed`,
    /// not on the score.
    public var score: Int

    /// Score minus the rounded average of `recentScores`, nil when there is
    /// no history (or no signal). Feeds the hero's trend tick.
    public var deltaVsAverage: Int?

    /// How many of the 4 signals (HRV, resting HR, sleep, strain) contributed.
    /// Renders as "based on N of 4 signals" (D6).
    public var signalsUsed: Int

    public init(score: Int, deltaVsAverage: Int? = nil, signalsUsed: Int) {
        self.score = score
        self.deltaVsAverage = deltaVsAverage
        self.signalsUsed = signalsUsed
    }
}

/// The four inputs a readiness score can stand on.
///
/// A fixed set: `Readiness.signalsUsed` is this set's count, and the Today
/// hero names each one so "based on 3 of 4 signals" can say *which* three.
/// Declaration order is the engine's own weighting order, so any UI that
/// lists them reads the same way every morning.
public enum ReadinessSignal: String, Sendable, Hashable, CaseIterable {
    case hrv
    case restingHR
    case sleep
    case strain
}

public enum ReadinessEngine {
    /// The one constant weight table (WP-23 step 1): HRV .30, resting HR .25,
    /// sleep .30, prior-day strain .15. Working constants -- golden-vector
    /// tests pin them; retune deliberately, never silently.
    public static let hrvWeight = 0.30
    public static let restingHRWeight = 0.25
    public static let sleepWeight = 0.30
    public static let strainWeight = 0.15

    /// Clamp shared by every subscore below (and the final score).
    static func clamped(_ value: Double) -> Double {
        min(100, max(0, value))
    }

    /// Finite value inside `range`, else nil (missing). Collapses the four
    /// per-signal validity checks to one call-site pattern; HRV's
    /// zero-exclusion stays inline (a degenerate zero ratio is missing, not
    /// a bottomed signal -- see `score`).
    static func valid(_ value: Double?, in range: ClosedRange<Double>) -> Double? {
        guard let value, value.isFinite, range.contains(value) else { return nil }
        return value
    }

    /// Overflow-safe mean of prior scores. Accumulates in `Double` (no `Int`
    /// trap on corrupt input, per the engine's degrade-don't-crash posture);
    /// the delta computation clamps back into `Int` range below.
    static func average(_ values: [Int]) -> Double {
        values.reduce(0.0) { $0 + Double($1) } / Double(values.count)
    }

    /// Per-signal subscores (0-100 each), static for direct unit testing.
    /// Every map is monotone in the healthy direction and clamps at the ends;
    /// the constants below are the same working-constant family as the
    /// weights (golden tests pin them).

    /// 100 at or above baseline, losing 120 points per full ratio point
    /// below (0.8 → 76, 0.5 → 40). No bonus above baseline: extra-high HRV
    /// is not extra readiness.
    public static func hrvSubscore(ratio: Double) -> Double {
        clamped(100 - 120 * max(0, 1 - ratio))
    }

    /// 100 at or below baseline, losing 8 points per bpm above (+2.5 → 80,
    /// +5 → 60, +10 → 20). Below baseline caps at 100 (monotone, no bonus).
    public static func restingHRSubscore(deltaBeatsPerMinute: Double) -> Double {
        clamped(100 - 8 * max(0, deltaBeatsPerMinute))
    }

    /// Bell around 8 h: 15 points per hour short, 10 per hour over
    /// (6 h → 70, 10 h → 80). Undersleeping costs more than oversleeping.
    public static func sleepDurationSubscore(hours: Double) -> Double {
        let penalty = hours < 8 ? 15 * (8 - hours) : 10 * (hours - 8)
        return clamped(100 - penalty)
    }

    /// 100 at or above 90% efficiency, losing 400 points per full fraction
    /// below (0.85 → 80, 0.80 → 60).
    public static func sleepEfficiencySubscore(fraction: Double) -> Double {
        clamped(100 - 400 * max(0, 0.9 - fraction))
    }

    /// Sleep signal: duration weighted .7 with efficiency .3 when both are
    /// present, duration alone otherwise.
    public static func sleepSubscore(hours: Double, efficiency: Double?) -> Double {
        let duration = sleepDurationSubscore(hours: hours)
        guard let efficiency else { return duration }
        return 0.7 * duration + 0.3 * sleepEfficiencySubscore(fraction: efficiency)
    }

    /// 100 at full rest, losing 45 points at maximal load (0.5 → ~78, 1.0 →
    /// 55): a hard day damps readiness without zeroing it.
    public static func strainSubscore(load: Double) -> Double {
        clamped(100 - 45 * load)
    }

    /// Scores one morning. Invalid readings (non-finite; non-positive HRV
    /// ratios including a degenerate exact zero; negative or >24 h sleep;
    /// out-of-range fractions and strain) count as missing, never as zero --
    /// bad data degrades to fewer signals, not a worse score. Empty history
    /// (or zero signals) yields a nil delta.
    ///
    /// - Parameter recentScores: past `Readiness.score` values (newest last;
    ///   order irrelevant), for the delta. Supplied by the caller -- this
    ///   engine keeps no history itself.
    /// The weight each signal carries in the final mean. Reads off the
    /// constants above — one table, not two.
    public static func weight(of signal: ReadinessSignal) -> Double {
        switch signal {
        case .hrv: return hrvWeight
        case .restingHR: return restingHRWeight
        case .sleep: return sleepWeight
        case .strain: return strainWeight
        }
    }

    /// Each contributing signal's own 0...100 subscore — on the *same scale
    /// as the final score*, which is exactly their weighted mean.
    ///
    /// This is what lets the Today hero draw a signal's bar at its real
    /// magnitude instead of just "reported / didn't". A row filled to 68
    /// beside a total of 82 is then arithmetic the user can follow; four
    /// full bars beside 82 was not.
    ///
    /// A signal absent from the returned dictionary had no usable reading.
    /// Invalid values count as missing, never as a contributing zero —
    /// `score`'s degrade-don't-crash rule.
    public static func signalScores(inputs: ReadinessInputs) -> [ReadinessSignal: Double] {
        var scores: [ReadinessSignal: Double] = [:]
        if let ratio = inputs.hrvRatio, ratio.isFinite, ratio > 0 {
            scores[.hrv] = hrvSubscore(ratio: ratio)
        }
        if let delta = valid(inputs.restingHRDeltaBeatsPerMinute, in: -Double.infinity...Double.infinity) {
            scores[.restingHR] = restingHRSubscore(deltaBeatsPerMinute: delta)
        }
        if let hours = valid(inputs.sleepHours, in: 0...24) {
            scores[.sleep] = sleepSubscore(
                hours: hours,
                efficiency: valid(inputs.sleepEfficiency, in: 0...1)
            )
        }
        if let strain = valid(inputs.priorDayStrain, in: 0...1) {
            scores[.strain] = strainSubscore(load: strain)
        }
        return scores
    }

    /// Which of the four signals `inputs` carries a usable reading for.
    ///
    /// Derived from `signalScores` rather than re-testing the same fields,
    /// so "usable" has exactly ONE definition and a lit row can never
    /// disagree with the weighting that produced the score — the repo's
    /// "literal drift" bug shape.
    public static func contributingSignals(inputs: ReadinessInputs) -> Set<ReadinessSignal> {
        Set(signalScores(inputs: inputs).keys)
    }

    public static func score(inputs: ReadinessInputs, recentScores: [Int] = []) -> Readiness {
        let scores = signalScores(inputs: inputs)
        var weightedSum = 0.0
        var weightSum = 0.0
        // Iterated in `allCases` order, not dictionary order: floating-point
        // addition is not associative, so summing in an arbitrary order
        // could move the rounded score by one.
        for signal in ReadinessSignal.allCases {
            guard let subscore = scores[signal] else { continue }
            let signalWeight = weight(of: signal)
            weightedSum += signalWeight * subscore
            weightSum += signalWeight
        }

        guard weightSum > 0 else {
            return Readiness(score: 50, deltaVsAverage: nil, signalsUsed: 0)
        }
        let score = Int(clamped((weightedSum / weightSum).rounded()))
        var delta: Int? = nil
        if !recentScores.isEmpty, !scores.isEmpty {
            let raw = (Double(score) - average(recentScores)).rounded()
            delta = Int(exactly: raw) ?? (raw > 0 ? Int.max : Int.min)
        }
        return Readiness(score: score, deltaVsAverage: delta, signalsUsed: scores.count)
    }
}
