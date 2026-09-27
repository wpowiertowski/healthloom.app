// ExerciseSessionDecoding.swift
//
// WP-12 (implementation-plan.md): decodes the wire shape of a Google Exercise
// session's nested payload, as preserved verbatim in
// `GoogleDataPoint.sessionPayload`. Exercise is a Session (Se) record type
// per base-knowledge.md §3 -- exactly like Sleep -- so this file follows
// WP-07's `SleepSessionDecoding.swift` pattern precisely: a `nonisolated`
// wire struct decoded by a plain `JSONDecoder`, HealthKit-free, always
// compiles regardless of platform.
//
// WP-51: the real v4 shape (published reference) is the API's typed
// `exercise` object -- `exerciseType` (an `Exercise.ExerciseType` enum value
// such as "RUNNING"), `displayName`, and a `metricsSummary` carrying
// `distanceMillimeters` and `caloriesKcal` among other totals. This file
// reads the three fields the workout needs; distance arrives in millimeters
// and is converted here. The pre-WP-51 assumed keys (`exercise.activity_type`
// ...) never matched a real response.

import Foundation

nonisolated struct ExerciseSessionWire: Decodable {
    let activityType: String
    let distanceMeters: Double?
    let energyKilocalories: Double?

    private enum CodingKeys: String, CodingKey {
        case exerciseType, metricsSummary
    }

    private enum MetricsKeys: String, CodingKey {
        case distanceMillimeters, caloriesKcal
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activityType = try container.decodeIfPresent(String.self, forKey: .exerciseType) ?? "EXERCISE_TYPE_UNSPECIFIED"
        let metrics = try? container.nestedContainer(keyedBy: MetricsKeys.self, forKey: .metricsSummary)
        distanceMeters = (try? metrics?.decodeIfPresent(Double.self, forKey: .distanceMillimeters)).flatMap { $0 }.map { $0 / 1000 }
        energyKilocalories = (try? metrics?.decodeIfPresent(Double.self, forKey: .caloriesKcal)).flatMap { $0 }
    }
}

nonisolated enum ExerciseSessionDecoding {
    /// Decodes `payload` into `ExerciseSessionWire`, returning `nil` (never
    /// throwing) on any malformed shape or a missing/non-string activity
    /// type -- callers treat that identically to "no session data," i.e.
    /// `.skip` (WP-07 step 5's "never crash" rule, followed here too).
    static func decode(_ payload: Data) -> ExerciseSessionWire? {
        try? JSONDecoder().decode(ExerciseSessionWire.self, from: payload)
    }
}
