// GetWorkoutsTool.swift
//
// WP-24 (implementation-plan.md): the `getWorkouts` coach tool, backed by
// `KnowledgeStore.workoutsSummary` (WP-19 step 4). Output is the same
// user-visible summary text as the profile -- nothing the trace UI can't
// show (D7). Registered on session creation via `CoachTools.all(store:)`.
// See GetStepsTool.swift for the isolation pattern shared by all four tools.

import Foundation
import FoundationModels

/// Answers "what workouts have I done?" from derived workout data
/// (consolidated watch/Fitbit view, supplements included).
@MainActor
public struct GetWorkoutsTool: Tool, Sendable {
    /// Shared day-window shape (see `DaysArguments`) -- one field name,
    /// one guide text, one initializer for both day-windowed tools.
    public typealias Arguments = DaysArguments

    public typealias Output = String

    public nonisolated var name: String { "getWorkouts" }

    public nonisolated var description: String {
        "Summarizes the user's recent workouts and activities."
    }

    /// Profile keys whose exclusion silences this tool (D7/D8 -- see
    /// `KnowledgeStore.isAnyExcludedFromAI`). Adding a derivation key under
    /// this topic without extending this list silently bypasses exclusion
    /// for the new field -- update both together.
    public static let coveredKeys = [KnowledgeDerivation.workoutsFieldKey]

    public static let excludedMessage = CoachTools.excludedMessage(forTopic: "Workout")

    private let answer: @MainActor @Sendable (Int) async throws -> String

    public init(answer: @escaping @MainActor @Sendable (Int) async throws -> String) {
        self.answer = answer
    }

    public nonisolated func call(arguments: Arguments) async throws -> String {
        try await answer(Clamping.window(arguments.days, maximum: KnowledgeStore.workoutsWindowDays))
    }

    /// Live path via the shared gated-answer helper (exclusion refusal +
    /// fetch-error propagation in one place).
    public static func live(store: KnowledgeStore) -> GetWorkoutsTool {
        GetWorkoutsTool { days in
            try store.gatedAnswer(
                coveredKeys: coveredKeys,
                excludedMessage: excludedMessage
            ) {
                store.workoutsSummary(days: days)
            }
        }
    }
}
