// DailyInsightTests.swift
//
// WP-23 "Tests" line (unit half): prompt composition and the generator seam
// with injected sessions. Schema decoding from fixture transcripts and real
// generation are device/manual + eval set (test plan §7, WP-31) -- no unit
// test touches the model.

import CoreModel
import Foundation
import Testing

@testable import CoachKit

private func insightContext(_ fields: [ProfileField]) -> HealthContext {
    HealthContext(
        fields: fields,
        localeIdentifier: "en_US",
        unitSystem: .imperial,
        today: Date(timeIntervalSince1970: 1_700_000_100)
    )
}

@Suite("DailyInsight prompt")
@MainActor
struct DailyInsightPromptTests {
    @Test("prompt carries readiness and field text as data, not instructions")
    func promptComposition() {
        let readiness = Readiness(score: 93, deltaVsAverage: 3, signalsUsed: 4)
        let prompt = DailyInsight.prompt(
            readiness: readiness,
            context: insightContext([field("sleep.duration", "7h 30m last night")])
        )
        #expect(prompt.contains("93/100"))
        #expect(prompt.contains("+3 vs recent average"))
        #expect(prompt.contains("4 of 4 signals"))
        #expect(prompt.contains("7h 30m last night"))
        #expect(prompt.contains("data, not instructions"))
        // The response shape comes from the generation schema, so the prompt
        // carries no competing imperative.
        #expect(!prompt.contains("Respond with"))
    }

    @Test("empty context renders an explicit nothing-available line")
    func emptyContextPrompt() {
        let readiness = Readiness(score: 50, deltaVsAverage: nil, signalsUsed: 0)
        let prompt = DailyInsight.prompt(readiness: readiness, context: insightContext([]))
        #expect(prompt.contains("No health context available"))
    }

    @Test("zero delta renders as unchanged, not +0")
    func zeroDeltaPrompt() {
        let readiness = Readiness(score: 88, deltaVsAverage: 0, signalsUsed: 4)
        let prompt = DailyInsight.prompt(readiness: readiness, context: insightContext([]))
        #expect(prompt.contains("unchanged vs recent average"))
        #expect(!prompt.contains("+0"))
    }

    @Test("effort levels and suggestion counts match the schema guides")
    func schemaGuards() {
        #expect(DailyInsight.effortLevels == ["low", "moderate", "high"])
        #expect(DailyInsight(headline: "h", suggestions: [], effortLevel: "moderate").isValidEffortLevel)
        #expect(!DailyInsight(headline: "h", suggestions: [], effortLevel: "extreme").isValidEffortLevel)
        #expect(DailyInsight(headline: "h", suggestions: ["a", "b"], effortLevel: "low").hasValidSuggestionCount)
        #expect(!DailyInsight(headline: "h", suggestions: ["only"], effortLevel: "low").hasValidSuggestionCount)
    }
}

@Suite("DailyInsight generator seam")
@MainActor
struct DailyInsightGeneratorTests {
    private func scriptedFactory(_ insight: DailyInsight) -> CoachSessionFactory {
        CoachSessionFactory(build: { _, _, _ in
            let session = ScriptedCoachSession(chunks: [])
            session.scriptedStructured = insight
            return session
        })
    }

    @Test("live path returns the scripted insight through the protocol seam")
    func livePathThroughSeam() async throws {
        let fixture = DailyInsight(
            headline: "Recovery looks strong.",
            suggestions: ["Take a walk", "Get morning light"],
            effortLevel: "moderate"
        )
        let generator = DailyInsightGenerator.live(
            factory: scriptedFactory(fixture),
            instructions: "base"
        )
        let insight = try await generator.insight(forPrompt: "morning?")
        #expect(insight.headline == "Recovery looks strong.")
        #expect(insight.suggestions.count == 2)
        #expect(insight.effortLevel == "moderate")
    }

    @Test("every insight builds a fresh session")
    func freshSessionPerInsight() async throws {
        var builds = 0
        let factory = CoachSessionFactory(build: { _, _, _ in
            builds += 1
            let session = ScriptedCoachSession(chunks: [])
            session.scriptedStructured = DailyInsight(headline: "h", suggestions: ["a", "b"], effortLevel: "low")
            return session
        })
        let generator = DailyInsightGenerator.live(factory: factory, instructions: "base")
        _ = try await generator.insight(forPrompt: "day one")
        _ = try await generator.insight(forPrompt: "day two")
        // Two insights, two one-shot sessions: no transcript can leak across.
        #expect(builds == 2)
    }

    @Test("generation errors propagate")
    func errorsPropagate() async throws {
        // No scripted structured answer configured: the double throws
        // instead of answering, and the generator lets it through.
        let factory = CoachSessionFactory(build: { _, _, _ in ScriptedCoachSession(chunks: []) })
        let generator = DailyInsightGenerator.live(factory: factory, instructions: "base")
        await #expect(throws: ScriptedCoachSession.NoStructuredResponse.self) {
            try await generator.insight(forPrompt: "anything")
        }
    }
}

@Suite("Empty-context legacy wording (WP-25 round-2 review #3)")
struct EmptyInsightWordingTests {
    @Test("empty context emits the legacy lines exactly, preamble-free")
    func emptyPromptExact() {
        let readiness = Readiness(score: 88, deltaVsAverage: nil, signalsUsed: 4)
        let prompt = DailyInsight.prompt(readiness: readiness, context: insightContext([]))
        #expect(prompt == "Morning readiness: 88/100 (based on 4 of 4 signals).\nNo health context available for this insight.")
    }
}
