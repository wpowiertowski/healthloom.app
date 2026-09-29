// CoachTools.swift
//
// WP-24 (implementation-plan.md): the coach's tool set in one place.
// `all(store:workouts:activity:)` builds the live tools for registration on session
// creation (`LanguageModelSession(model:tools:instructions:)` via
// `CoachSessionFactory` -- WP-25 wires this into the chat UI). The steps,
// sleep and vitals tools answer from a `KnowledgeStore` summary (WP-19 step
// 4); the two workout tools answer from the app's per-workout reads (WP-77,
// `CoachWorkoutQueries`). All of it is user-visible text, exclusion-gated
// before answering (D7/D8).
//
// Consistency note for WP-25: tools refuse per *topic* (any covered key
// excluded silences the whole answer) while `ContextAssembler` filters per
// *field* -- both directions are leak-free, but a turn can show resting HR
// in its assembled context while `getVitals` refuses the same data. That
// asymmetry is deliberate (a tool answer speaks values aloud; passive
// context does not) and must survive UI copy review.

import Foundation
import FoundationModels

/// Namespace for building the coach tool set.
@MainActor
public enum CoachTools {
    /// All five live tools for one store: steps, sleep, the workout list
    /// and one workout in detail (WP-77, read by the app through
    /// `workouts`), vitals. Pass the result as `tools:` when creating the
    /// session -- WP-25 does this for chat conversations; one-shot insight
    /// sessions (WP-23) stay tool-free unless a later WP says otherwise.
    ///
    /// Each tool reports to `activity` while it runs (WP-78), under the
    /// label the chat's typing indicator shows.
    public static func all(store: KnowledgeStore, workouts: CoachWorkoutQueries, activity: CoachToolActivity) -> [any Tool] {
        [
            ReportingTool(GetStepsTool.live(store: store), activity: activity) { _ in "Checking your steps" },
            ReportingTool(GetRecentSleepTool.live(store: store), activity: activity) { _ in "Reviewing your sleep" },
            ReportingTool(GetWorkoutsTool.live(store: store, list: workouts.list), activity: activity) { _ in
                "Looking through your workouts"
            },
            ReportingTool(GetWorkoutDetailTool.live(store: store, detail: workouts.detail), activity: activity) { arguments in
                "Reading workout \(arguments.number)" + (arguments.measurement.map { " (\($0.lowercased()))" } ?? "")
            },
            ReportingTool(GetVitalsTool.live(store: store), activity: activity) { _ in "Checking your heart rate and HRV" },
        ]
    }

    /// Single template for every tool's exclusion refusal, so a new
    /// tool can't drift the wording WP-25's UI copy review signs off on.
    /// Each tool still exposes its own `excludedMessage` (stable per-tool
    /// API for tests and UI copy), derived here.
    public static func excludedMessage(forTopic topic: String) -> String {
        "\(topic) data is excluded from the coach in your settings."
    }
}

public extension KnowledgeStore {
    /// Shared exclusion-gate-then-answer behind every tool's `live()` (one
    /// place instead of four hand-copies): refuses with `excludedMessage`
    /// when any covered key is excluded, otherwise answers via `summary`.
    /// A gate fetch failure propagates as a tool error -- it never
    /// fail-opens into answering possibly-excluded data.
    func gatedAnswer(
        coveredKeys: [String],
        excludedMessage: String,
        summary: () async throws -> String
    ) async throws -> String {
        if try isAnyExcludedFromAI(coveredKeys) {
            return excludedMessage
        }
        return try await summary()
    }
}
