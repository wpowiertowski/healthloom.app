// CoachTools.swift
//
// WP-24 (implementation-plan.md): the coach's tool set in one place.
// `all(store:)` builds the four live tools for registration on session
// creation (`LanguageModelSession(model:tools:instructions:)` via
// `CoachSessionFactory` -- WP-25 wires this into the chat UI). Every tool is
// backed by a `KnowledgeStore` summary (WP-19 step 4): derived, user-visible
// text only, exclusion-gated before answering (D7/D8).
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
    /// All four live tools for one store: steps, sleep, workouts, vitals.
    /// Pass the result as `tools:` when creating the session -- WP-25 does
    /// this for chat conversations; one-shot insight sessions (WP-23) stay
    /// tool-free unless a later WP says otherwise.
    public static func all(store: KnowledgeStore) -> [any Tool] {
        [
            GetStepsTool.live(store: store),
            GetRecentSleepTool.live(store: store),
            GetWorkoutsTool.live(store: store),
            GetVitalsTool.live(store: store),
        ]
    }

    /// Single template for every tool's exclusion refusal, so a 5th/6th
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
        summary: () -> String
    ) throws -> String {
        if try isAnyExcludedFromAI(coveredKeys) {
            return excludedMessage
        }
        return summary()
    }
}
