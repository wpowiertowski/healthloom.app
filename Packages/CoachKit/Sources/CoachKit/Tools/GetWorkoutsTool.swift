// GetWorkoutsTool.swift
//
// WP-24 (implementation-plan.md): the `getWorkouts` coach tool. Since WP-77
// it lists each workout -- numbered, newest first, with its time, source and
// headline figures -- read by the app (`CoachWorkoutQueries.list`: HealthKit
// and the consolidated Activities view live there, not in this package).
// The numbers are what `getWorkoutDetail` takes. Output is plain text the
// trace UI shows (D7). See GetStepsTool.swift for the isolation pattern
// shared by all the tools.

import Foundation
import FoundationModels

/// The app's per-workout reads, as the text the model reads. Numbering is
/// the list's own: 1 is the most recent workout in the last
/// `GetWorkoutsTool.windowDays` days, whatever window a call lists, so a
/// number from any `getWorkouts` answer means the same workout to
/// `getWorkoutDetail`.
public struct CoachWorkoutQueries: Sendable {
    /// The workouts in the last `days` days (already clamped).
    public let list: @MainActor @Sendable (_ days: Int) async throws -> String
    /// One workout by number: its overview, or one measurement's
    /// breakdown when `measurement` names one.
    public let detail: @MainActor @Sendable (_ number: Int, _ measurement: String?) async throws -> String

    public init(
        list: @escaping @MainActor @Sendable (_ days: Int) async throws -> String,
        detail: @escaping @MainActor @Sendable (_ number: Int, _ measurement: String?) async throws -> String
    ) {
        self.list = list
        self.detail = detail
    }
}

/// Answers "what workouts have I done?" one workout per line.
@MainActor
public struct GetWorkoutsTool: Tool, Sendable {
    /// Shared day-window shape (see `DaysArguments`) -- one field name,
    /// one guide text, one initializer for both day-windowed tools.
    public typealias Arguments = DaysArguments

    public typealias Output = String

    /// How far back workouts are listed and numbered.
    public static let windowDays = KnowledgeStore.workoutsWindowDays

    public nonisolated var name: String { "getWorkouts" }

    public nonisolated var description: String {
        "Lists the user's recent workouts, newest first and numbered, with each one's time, source and headline figures. "
            + "Pass a number to getWorkoutDetail for everything recorded during that workout."
    }

    /// Profile keys whose exclusion silences this tool (D7/D8 -- see
    /// `KnowledgeStore.isAnyExcludedFromAI`). Adding a derivation key under
    /// this topic without extending this list silently bypasses exclusion
    /// for the new field -- update both together. `getWorkoutDetail` is
    /// silenced by the same keys.
    public static let coveredKeys = [KnowledgeDerivation.workoutsFieldKey]

    public static let excludedMessage = CoachTools.excludedMessage(forTopic: "Workout")

    private let answer: @MainActor @Sendable (Int) async throws -> String

    public init(answer: @escaping @MainActor @Sendable (Int) async throws -> String) {
        self.answer = answer
    }

    public nonisolated func call(arguments: Arguments) async throws -> String {
        try await answer(Clamping.window(arguments.days, maximum: Self.windowDays))
    }

    /// Live path via the shared gated-answer helper (exclusion refusal +
    /// fetch-error propagation in one place).
    public static func live(
        store: KnowledgeStore,
        list: @escaping @MainActor @Sendable (Int) async throws -> String
    ) -> GetWorkoutsTool {
        GetWorkoutsTool { days in
            try await store.gatedAnswer(coveredKeys: coveredKeys, excludedMessage: excludedMessage) {
                try await list(days)
            }
        }
    }
}
