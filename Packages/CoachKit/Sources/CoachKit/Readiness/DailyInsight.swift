// DailyInsight.swift
//
// WP-23 (implementation-plan.md): the `@Generable` morning-insight shape,
// its prompt composer, and the generator seam. Guided generation itself runs
// on-device and is covered by manual tests (test plan §7) plus the eval set
// (WP-31); unit tests cover the struct shape, the deterministic prompt, and
// the generator through injected sessions -- never the model.

import CoreModel
import Foundation
import FoundationModels

/// One morning insight, generated from `context(.dailyInsight)` plus the
/// `ReadinessEngine` result via a fresh one-shot session (WP-22 lifecycle).
/// Exact shape from implementation-plan.md WP-23 step 2.
@Generable
public struct DailyInsight: Sendable {
    @Guide(description: "One-sentence, encouraging headline.")
    public var headline: String

    @Guide(description: "2-3 concrete, personalized suggestions.", .count(2...3))
    public var suggestions: [String]

    @Guide(.anyOf(["low", "moderate", "high"]))
    public var effortLevel: String

    public init(headline: String, suggestions: [String], effortLevel: String) {
        self.headline = headline
        self.suggestions = suggestions
        self.effortLevel = effortLevel
    }

    /// Allowed effort levels, mirroring the `.anyOf` guide. Single source so
    /// validation and the schema can't drift.
    public static let effortLevels = ["low", "moderate", "high"]

    public var isValidEffortLevel: Bool {
        Self.effortLevels.contains(effortLevel)
    }

    /// The suggestion-count range the schema enforces (mirrors the `.count`
    /// guide, same single-source rule as `effortLevels`).
    public static let suggestionCountRange = 2...3

    public var hasValidSuggestionCount: Bool {
        Self.suggestionCountRange.contains(suggestions.count)
    }

    /// Deterministic prompt for one insight turn: the readiness result plus
    /// the assembled context's human-readable text. Data only -- the response
    /// shape comes from the generation schema (`includeSchemaInPrompt`), not
    /// from instructions in this text, so nothing here competes with the
    /// session's effective-prompt instructions (user base + `SafetyLayer`
    /// suffix, D10). Field lines sit inside explicit DATA markers: once
    /// WP-30's correction UI wires user-pinned text through (preserved
    /// byte-for-byte per `KnowledgeStore`), directive-like user text still
    /// arrives delimited from the schema's own framing.
    ///
    /// Takes the already-filtered `HealthContext` (D7/D8), not
    /// `[ProfileField]`: `KnowledgeProfile.sections` shares that element type
    /// but is unfiltered, so accepting the raw array would let a future call
    /// site leak excluded/clinical fields past the compiler.
    ///
    /// `@MainActor`: required, not conventional -- `HealthContext` and
    /// `ProfileField` live under CoreModel's package-wide
    /// `.defaultIsolation(MainActor.self)`, so member access is MainActor-bound
    /// even though neither is a `@Model` class. (An earlier comment blamed
    /// `@Model`-ness; the compiler disproves that -- removing this breaks
    /// the build.) All callers are MainActor UI/session code.
    @MainActor
    public static func prompt(readiness: Readiness, context: HealthContext) -> String {
        let trend: String = switch readiness.deltaVsAverage {
        case nil: ""
        case 0?: "unchanged vs recent average, "
        case let delta?: "\(delta > 0 ? "+" : "")\(delta) vs recent average, "
        }
        var lines = [
            "Morning readiness: \(readiness.score)/100 (\(trend)based on \(readiness.signalsUsed) of 4 signals).",
        ]
        // The preamble stays inside the non-empty branch: it announces a
        // data block, and emitting it above the empty message would announce
        // one that never follows (WP-25 round-2 review #3 -- the shared
        // helper must not change this legacy wording).
        if context.fields.isEmpty {
            lines.append("No health context available for this insight.")
        } else {
            // Shared sentence constant (WP-27 review R1); layout and
            // legacy empty wording unchanged -- only the literal is shared.
            lines.append(HealthContext.dataFramingSentence)
            lines += context.framedAsData(emptyMessage: "No health context available for this insight.")
        }
        return lines.joined(separator: "\n")
    }
}

/// Generator seam for morning insights. Holds a session source -- not a
/// session -- so **every insight builds a fresh one-shot session** (WP-22
/// lifecycle): insights never inherit chat history, and reusing one
/// generator across days can't leak prior transcripts into new insights.
/// The freshness is structural (a new session per `insight` call), not a doc
/// comment asking callers to pass the right kind of session.
@MainActor
public struct DailyInsightGenerator: Sendable {
    private let makeSession: @MainActor @Sendable () -> any CoachSession

    public init(makeSession: @escaping @MainActor @Sendable () -> any CoachSession) {
        self.makeSession = makeSession
    }

    public func insight(forPrompt prompt: String) async throws -> DailyInsight {
        try await makeSession().respond(to: prompt, generating: DailyInsight.self)
    }

    /// Live path. The factory builds each session as `.oneShot` with the
    /// effective-prompt instructions; tests inject a factory whose builder
    /// returns a scripted double (real generation: on-device manual tests,
    /// test plan §7).
    public static func live(factory: CoachSessionFactory, instructions: String) -> DailyInsightGenerator {
        DailyInsightGenerator {
            factory.makeSession(for: .oneShot, instructions: instructions)
        }
    }
}
