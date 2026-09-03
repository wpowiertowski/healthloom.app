// GetStepsTool.swift
//
// WP-24 (implementation-plan.md): the `getSteps` coach tool, backed by
// `KnowledgeStore.stepsSummary` (WP-19 step 4). Output is the same
// user-visible summary text as the profile -- nothing the trace UI can't
// show (D7). Registered on session creation via `CoachTools.all(store:)`.

import Foundation
import FoundationModels

/// Answers "how have my steps been?" from derived step data.
///
/// The struct itself is `@MainActor` (package default, so the injected
/// `answer` closure and `live(store:)` stay on-actor with the store), but
/// every `Tool` witness is explicitly `nonisolated`: the framework drives
/// tools from its own executor contexts. `Arguments` is a nonisolated type
/// for the same reason (it crosses into `call` as a parameter).
///
/// `name` stays explicit even though it could ride a protocol default: the
/// tool name is the model's dispatch contract and must not shift under a
/// type rename. `parameters`/`includesSchemaInInstructions` do ride the
/// `Tool`-extension defaults (verified on both SDKs this package builds
/// against); `description` and `Output` have no defaults and are required.
@MainActor
public struct GetStepsTool: Tool, Sendable {
    /// Shared day-window shape (see `DaysArguments`) -- one field name,
    /// one guide text, one initializer for both day-windowed tools.
    public typealias Arguments = DaysArguments

    public typealias Output = String

    public nonisolated var name: String { "getSteps" }

    public nonisolated var description: String {
        "Summarizes the user's daily step counts over a recent window."
    }

    /// Profile keys whose exclusion silences this tool (D7/D8 -- see
    /// `KnowledgeStore.isAnyExcludedFromAI`). Adding a derivation key under
    /// this topic without extending this list silently bypasses exclusion
    /// for the new field -- update both together.
    public static let coveredKeys = [KnowledgeDerivation.stepsFieldKey]

    public static let excludedMessage = CoachTools.excludedMessage(forTopic: "Step")

    private let answer: @MainActor @Sendable (Int) async throws -> String

    public init(answer: @escaping @MainActor @Sendable (Int) async throws -> String) {
        self.answer = answer
    }

    public nonisolated func call(arguments: Arguments) async throws -> String {
        try await answer(Clamping.window(arguments.days, maximum: KnowledgeStore.stepsWindowDays))
    }

    /// Live path via the shared gated-answer helper (exclusion refusal +
    /// fetch-error propagation in one place). Never returns excluded data:
    /// a gate throw surfaces as a tool error, never as an answer.
    public static func live(store: KnowledgeStore) -> GetStepsTool {
        GetStepsTool { days in
            try store.gatedAnswer(
                coveredKeys: coveredKeys,
                excludedMessage: excludedMessage
            ) {
                store.stepsSummary(days: days)
            }
        }
    }
}
