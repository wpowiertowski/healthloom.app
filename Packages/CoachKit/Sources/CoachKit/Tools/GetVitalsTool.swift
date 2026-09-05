// GetVitalsTool.swift
//
// WP-24 (implementation-plan.md): the `getVitals` coach tool, backed by
// `KnowledgeStore.vitalsSummary` (WP-19 step 4): resting HR and HRV trends.
// Output is the same user-visible summary text as the profile -- nothing the
// trace UI can't show (D7). Registered on session creation via
// `CoachTools.all(store:)`. See GetStepsTool.swift for the isolation pattern
// shared by all four tools.

import Foundation
import FoundationModels

/// Answers "how are my vitals trending?" (resting heart rate, HRV vs
/// baseline) from derived vitals data. Takes no arguments.
@MainActor
public struct GetVitalsTool: Tool, Sendable {
    @Generable
    public nonisolated struct Arguments: Sendable {
        public init() {}
    }

    public typealias Output = String

    public nonisolated var name: String { "getVitals" }

    public nonisolated var description: String {
        "Summarizes the user's resting heart rate and heart rate variability trends."
    }

    /// Profile keys whose exclusion silences this tool (D7/D8 -- see
    /// `KnowledgeStore.isAnyExcludedFromAI`). ANY-match: one excluded vitals
    /// field poisons the whole answer rather than leaking its substance.
    /// Adding a derivation key under this topic without extending this list
    /// silently bypasses exclusion for the new field -- update both
    /// together.
    public static let coveredKeys = [
        KnowledgeDerivation.restingHeartRateFieldKey,
        KnowledgeDerivation.heartRateVariabilityFieldKey,
    ]

    public static let excludedMessage = CoachTools.excludedMessage(forTopic: "Vitals")

    private let answer: @MainActor @Sendable () async throws -> String

    public init(answer: @escaping @MainActor @Sendable () async throws -> String) {
        self.answer = answer
    }

    public nonisolated func call(arguments _: Arguments) async throws -> String {
        try await answer()
    }

    /// Live path via the shared gated-answer helper (exclusion refusal +
    /// fetch-error propagation in one place).
    public static func live(store: KnowledgeStore) -> GetVitalsTool {
        GetVitalsTool {
            try store.gatedAnswer(
                coveredKeys: coveredKeys,
                excludedMessage: excludedMessage
            ) {
                store.vitalsSummary()
            }
        }
    }
}
