// SeededProfile.swift
// CoachEval
//
// WP-31 / test plan §9: the one fixed seeded profile every probe runs
// against. Values are chosen to exercise the grounding scorer: a comma
// number (8,432), a decimal (172.4), a time expression (7h 30m), and a
// readiness line with its own numbers (78/100, +5, 4 of 4) so an insight
// that echoes the prompt's own numbers still scores grounded — only
// numbers from outside the fixture (e.g. an invented resting HR of 48
// against the fixture's 62) fail.

import CoreModel
import CoachKit
import Foundation

/// The fixed fixture + the exact prompt text probes run with. Single source:
/// `groundingSourceText` is the same string the nightly run sends, so the
/// scorer can never disagree with the runner about what "the context" was.
public enum SeededProfile {
    /// Frozen fixture date. Byte-stability comes from dateless rendering
    /// (field framing carries no dates) plus this frozen value — not from
    /// the date itself, which never renders into `promptText`.
    public static let today = Date(timeIntervalSince1970: 1_700_000_100)

    public static let readiness = Readiness(score: 78, deltaVsAverage: 5, signalsUsed: 4)

    public static func fields() -> [ProfileField] {
        [
            ProfileField(key: "sleep.duration", displayText: "7h 30m last night", source: "HealthKit", asOf: today),
            ProfileField(key: "steps.count", displayText: "8,432 steps yesterday", source: "HealthKit", asOf: today),
            ProfileField(key: "heart.resting", displayText: "62 bpm resting", source: "HealthKit", asOf: today),
            ProfileField(key: "weight.body", displayText: "172.4 lb this morning", source: "HealthKit", asOf: today),
            ProfileField(key: "workouts.count", displayText: "3 workouts this week", source: "HealthKit", asOf: today),
        ]
    }

    public static func context() -> HealthContext {
        HealthContext(
            fields: fields(),
            localeIdentifier: "en_US",
            unitSystem: .imperial,
            today: today
        )
    }

    /// The exact text the nightly run sends for grounding/structure probes.
    public static func promptText() -> String {
        DailyInsight.prompt(readiness: readiness, context: context())
    }
}
