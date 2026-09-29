// GetWorkoutDetailTool.swift
//
// WP-77: the `getWorkoutDetail` coach tool -- everything recorded during one
// workout, by its `getWorkouts` number. Without a measurement it answers the
// overview (figures, every measurement's summary per device, splits); with
// one it answers that measurement's breakdown by distance and by minute.
// Each answer is sized for the smallest (on-device) context, so a larger
// model asks for more by calling again rather than getting a bigger answer
// that a mid-turn fallback to on-device couldn't hold. Read by the app
// (`CoachWorkoutQueries.detail`); plain text the trace UI shows (D7).

import Foundation
import FoundationModels

/// Answers "how did that run go?" down to any single measurement.
@MainActor
public struct GetWorkoutDetailTool: Tool, Sendable {
    @Generable
    public nonisolated struct Arguments: Sendable {
        @Guide(description: "The workout's number from getWorkouts; 1 is the most recent.")
        public var number: Int

        @Guide(description: "Optional: one measurement named in the workout's overview (for example heart rate, running power, ground contact time) for its breakdown by distance and by minute. Leave empty for the overview.")
        public var measurement: String?

        public init(number: Int, measurement: String? = nil) {
            self.number = number
            self.measurement = measurement
        }
    }

    public typealias Output = String

    public nonisolated var name: String { "getWorkoutDetail" }

    public nonisolated var description: String {
        "Everything recorded during one workout: its figures, every measurement per device (heart rate, power, "
            + "cadence, stride, ground contact time, vertical oscillation, energy...), splits, and any one measurement's "
            + "breakdown by distance and by minute."
    }

    /// The workout list's own keys: excluding workouts silences both tools.
    public static let coveredKeys = GetWorkoutsTool.coveredKeys

    public static let excludedMessage = GetWorkoutsTool.excludedMessage

    private let answer: @MainActor @Sendable (Int, String?) async throws -> String

    public init(answer: @escaping @MainActor @Sendable (Int, String?) async throws -> String) {
        self.answer = answer
    }

    public nonisolated func call(arguments: Arguments) async throws -> String {
        let measurement = arguments.measurement?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await answer(arguments.number, measurement?.isEmpty == false ? measurement : nil)
    }

    public static func live(
        store: KnowledgeStore,
        detail: @escaping @MainActor @Sendable (Int, String?) async throws -> String
    ) -> GetWorkoutDetailTool {
        GetWorkoutDetailTool { number, measurement in
            try await store.gatedAnswer(coveredKeys: coveredKeys, excludedMessage: excludedMessage) {
                try await detail(number, measurement)
            }
        }
    }
}
