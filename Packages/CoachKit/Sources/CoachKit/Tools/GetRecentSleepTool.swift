// GetRecentSleepTool.swift
//
// WP-24 (implementation-plan.md): the `getRecentSleep` coach tool, backed by
// `KnowledgeStore.sleepSummary` (WP-19 step 4). Output is the same
// user-visible summary text as the profile -- nothing the trace UI can't
// show (D7). Registered on session creation via `CoachTools.all(store:)`.
// See GetStepsTool.swift for the isolation pattern shared by all four tools.

import Foundation
import FoundationModels

/// Answers "how have I been sleeping?" from derived sleep data.
@MainActor
public struct GetRecentSleepTool: Tool, Sendable {
    @Generable
    public nonisolated struct Arguments: Sendable {
        @Guide(description: "Number of nights to summarize, 1 to 14.")
        public var nights: Int

        public init(nights: Int) {
            self.nights = nights
        }
    }

    public typealias Output = String

    public nonisolated var name: String { "getRecentSleep" }

    public nonisolated var description: String {
        "Summarizes the user's recent sleep duration and sleep stages."
    }

    /// Profile keys whose exclusion silences this tool (D7/D8 -- see
    /// `KnowledgeStore.isAnyExcludedFromAI`). ANY-match: sleep answers one
    /// topic, so one excluded sleep field poisons the whole answer rather
    /// than leaking its substance from the raw cache. Adding a derivation
    /// key under this topic without extending this list silently bypasses
    /// exclusion for the new field -- update both together.
    public static let coveredKeys = [
        KnowledgeDerivation.sleepDurationFieldKey,
        KnowledgeDerivation.sleepStageSplitFieldKey,
    ]

    public static let excludedMessage = CoachTools.excludedMessage(forTopic: "Sleep")

    private let answer: @MainActor @Sendable (Int) async throws -> String

    public init(answer: @escaping @MainActor @Sendable (Int) async throws -> String) {
        self.answer = answer
    }

    public nonisolated func call(arguments: Arguments) async throws -> String {
        // Ceiling matches the store's sleep cache window (tied to
        // `KnowledgeStore.sleepWindowNights`, not the 30-day tool
        // convention): the schema promises only what the store can deliver.
        try await answer(Clamping.window(arguments.nights, maximum: KnowledgeStore.sleepWindowNights))
    }

    /// Live path via the shared gated-answer helper (exclusion refusal +
    /// fetch-error propagation in one place).
    public static func live(store: KnowledgeStore) -> GetRecentSleepTool {
        GetRecentSleepTool { nights in
            try store.gatedAnswer(
                coveredKeys: coveredKeys,
                excludedMessage: excludedMessage
            ) {
                store.sleepSummary(nights: nights)
            }
        }
    }
}
