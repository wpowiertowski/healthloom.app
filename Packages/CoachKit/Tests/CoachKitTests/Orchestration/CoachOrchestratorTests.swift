// CoachOrchestratorTests.swift
//
// WP-27 "Tests" line: the orchestrator always includes the suffix
// regardless of tier (asserted on a spy at the factory seam -- see below),
// a snapshot is stored per turn, and escalation is offered exactly on the
// documented triggers.
//
// On the "spy `LanguageModel` conformance" the plan names: the framework
// protocol carries an associated type (`Executor`), so a hand-written test
// double can't conform. The suite instead spies one layer down, at
// `CoachSessionFactory`'s build closure, capturing the `instructions` every
// tier dispatches through -- instructions are the tier-independent carrier
// of the suffix (the factory receives them for any model), so the capture
// asserts exactly what the plan's spy would. All ungated: runs on both
// matrix toolchains with no model.

import CoreModel
import Foundation
import FoundationModels
import SwiftData
import Testing

@testable import CoachKit

/// Recording `CoachSessionFactory` build: captures factory-level
/// instructions per build (the suffix carrier -- distinct from the
/// session-level turn prompts `ScriptedCoachSession.receivedPrompts`
/// records) and answers through the shared scripted double (WP-27 review
/// R2). `@MainActor`-bound (the factory calls it there); the suite is
/// `@MainActor`, so no lock is needed.
@MainActor
final class RecordingBuild {
    var instructions: [String] = []
    var sessions: [ScriptedCoachSession] = []
    var builds: Int { sessions.count }
    var answer: String = "reply"
    var failure: Error?

    func factory() -> CoachSessionFactory {
        // The build closure is `@MainActor`-isolated, so `self` (also
        // `@MainActor`) is directly accessible -- no lock, no hopping.
        CoachSessionFactory(build: { instructions, _ in
            self.instructions.append(instructions)
            let session = ScriptedCoachSession(chunks: [self.answer])
            session.failure = self.failure
            self.sessions.append(session)
            return session
        })
    }
}

/// Seeds a profile with bulky fields (~50 tokens each at the
/// bytes/4 estimator) for the trimming true-arm (N4). Ten fields ≈ 500+
/// tokens of trimmable context -- wide enough that a probing budget lands
/// between the prompt-reserve floor (`promptOverBudget`) and the full
/// total (`didTrim`) without hand-computing either.
@MainActor
private func seedBulkyProfile(into container: ModelContainer) throws {
    let context = ModelContext(container)
    context.insert(KnowledgeProfile(sections: (0 ..< 10).map { i in
        field("test.bulky.\(i)", String(repeating: "datum \(i) ", count: 30))
    }))
    try context.save()
}

@Suite("CoachOrchestrator")
@MainActor
struct CoachOrchestratorTests {
    private func makeOrchestrator(
        recording: RecordingBuild = RecordingBuild(),
        catalog: ModelCatalog = ModelCatalog(onDeviceAvailable: { true })
    ) throws -> (CoachOrchestrator, ModelContainer, RecordingBuild) {
        let container = try CoreModel.makeContainer(inMemory: true)
        let orchestrator = CoachOrchestrator(
            prompts: PromptManager(modelContainer: container),
            assembler: ContextAssembler(modelContainer: container),
            sessions: recording.factory(),
            catalog: catalog
        )
        return (orchestrator, container, recording)
    }

    @Test("instructions carry the safety suffix on every turn")
    func suffixOnEveryTurn() async throws {
        let (orchestrator, _, recording) = try makeOrchestrator()
        let turn = try await orchestrator.respond(to: "How am I doing?")
        guard case .reply = turn else {
            Issue.record("expected a reply, got \(turn)")
            return
        }
        #expect(recording.builds == 1)
        #expect(recording.instructions.count == 1)
        #expect(recording.instructions[0].hasSuffix("\n\n" + SafetyLayer.text))
    }

    @Test("a snapshot is stored per turn and linked on the result")
    func snapshotStoredPerTurn() async throws {
        let (orchestrator, container, _) = try makeOrchestrator()
        let turn = try await orchestrator.respond(to: "How am I doing?")
        guard case .reply(_, let snapshotID, _) = turn else {
            Issue.record("expected a reply, got \(turn)")
            return
        }
        let context = ModelContext(container)
        let stored = try context.fetch(FetchDescriptor<ContextSnapshot>(
            predicate: #Predicate { $0.id == snapshotID }
        ))
        #expect(stored.count == 1)
    }

    @Test("context-over-budget offers escalation and never dispatches")
    func overBudgetOffersEscalation() async throws {
        let (orchestrator, _, recording) = try makeOrchestrator()
        // A one-token window overflows on the prompt reserve alone, forcing
        // `promptOverBudget` without needing any health data.
        let turn = try await orchestrator.respond(to: "How am I doing?", tokenBudget: 1)
        guard case .escalationOffer(let reason, _) = turn else {
            Issue.record("expected an escalation offer, got \(turn)")
            return
        }
        #expect(reason == .contextOverBudget)
        // Offering IS the turn: no session was built, nothing was generated.
        #expect(recording.builds == 0)
    }

    @Test("explicit deeper-analysis ask offers escalation")
    func deeperAnalysisOffersEscalation() async throws {
        let (orchestrator, _, recording) = try makeOrchestrator()
        let turn = try await orchestrator.respond(to: "Give me a deeper analysis of my week.")
        guard case .escalationOffer(let reason, _) = turn else {
            Issue.record("expected an escalation offer, got \(turn)")
            return
        }
        #expect(reason == .deeperAnalysisRequested)
        #expect(recording.builds == 0)
    }

    @Test("budget overflow dominates a simultaneous deeper ask")
    func overflowDominatesDeeperAsk() async throws {
        let (orchestrator, _, _) = try makeOrchestrator()
        let turn = try await orchestrator.respond(
            to: "Go deeper on my week.",
            tokenBudget: 1
        )
        guard case .escalationOffer(let reason, _) = turn else {
            Issue.record("expected an escalation offer, got \(turn)")
            return
        }
        #expect(reason == .contextOverBudget)
    }

    @Test("deeper-analysis trigger phrases")
    func deeperAnalysisPhrases() {
        for phrase in [
            "a deeper analysis please",
            "GO DEEPER into my sleep",
            "think harder about this",
            "give me a thorough analysis",
        ] {
            #expect(CoachOrchestrator.requestsDeeperAnalysis(phrase), "missed: \(phrase)")
        }
        for plain in ["How am I doing?", "log a run", "deeper"] {
            #expect(!CoachOrchestrator.requestsDeeperAnalysis(plain), "false hit: \(plain)")
        }
        // Near-misses: the trigger is the phrase, not its object. A workout
        // question containing "go deeper" escalates today by design (the
        // user asked for depth); beta tuning (D15.4) may narrow this, and
        // these pins force that change to be deliberate.
        for nearMiss in ["go deeper on my run route", "a detailed analysis of last night's sleep"] {
            #expect(CoachOrchestrator.requestsDeeperAnalysis(nearMiss), "changed: \(nearMiss)")
        }
    }

    @Test("disabled tier throws before touching the store or sessions")
    func disabledTierThrows() async throws {
        let (orchestrator, _, recording) = try makeOrchestrator(
            catalog: ModelCatalog(onDeviceAvailable: { false })
        )
        await #expect {
            try await orchestrator.respond(to: "Hi")
        } throws: { error in
            guard case .tierUnavailable(let tier, _) = error as? CoachError else { return false }
            return tier == .onDevice
        }
        #expect(recording.builds == 0)
    }

    @Test("session failures normalize to underlying")
    func sessionFailureNormalizes() async throws {
        struct Boom: Error {}
        let recording = RecordingBuild()
        recording.failure = Boom()
        let (orchestrator, _, _) = try makeOrchestrator(recording: recording)
        await #expect {
            try await orchestrator.respond(to: "Hi")
        } throws: { error in
            guard case .underlying(let description) = error as? CoachError else { return false }
            return description.contains("Boom")
        }
    }

    @Test("turn prompt routes through the shared composer")
    func turnPromptDelegation() async throws {
        // The literal is pinned once in CoreModel (`promptBlock`); here we
        // pin that the session actually receives the shared framing --
        // referenced via the constant, not a re-typed literal, so a future
        // local edit can't silently refork it (R1).
        let recording = RecordingBuild()
        let (orchestrator, _, _) = try makeOrchestrator(recording: recording)
        _ = try await orchestrator.respond(to: "Hi")
        guard let sent = recording.sessions.first?.receivedPrompts.first else {
            Issue.record("no session was built -- nothing received the turn")
            return
        }
        #expect(sent.hasPrefix("Hi\n\n" + HealthContext.dataFramingSentence))
    }

    @Test("reply surfaces fields-dropped signal")
    func replySurfacesDidTrim() async throws {
        // Full budget: nothing trimmed, flag false...
        let (orchestrator, _, _) = try makeOrchestrator()
        let full = try await orchestrator.respond(to: "Hi")
        guard case .reply(_, _, let trimmedFull) = full else {
            Issue.record("expected a reply, got \(full)")
            return
        }
        #expect(!trimmedFull)
    }

    @Test("trimmed-but-fitting turns answer with the flag set")
    func replyTrueArm() async throws {
        // N4: the flag's whole purpose is the true arm -- force trimming
        // (fields must drop) while the prompt reserve still fits (no
        // escalation offer). Budgets probe downward; the first
        // trimmed reply wins. Failing here means the window between the
        // reserve floor and the full total collapsed -- investigate, don't
        // just widen the probe.
        let container = try CoreModel.makeContainer(inMemory: true)
        try seedBulkyProfile(into: container)
        let recording = RecordingBuild()
        let orchestrator = CoachOrchestrator(
            prompts: PromptManager(modelContainer: container),
            assembler: ContextAssembler(modelContainer: container),
            sessions: recording.factory(),
            catalog: ModelCatalog(onDeviceAvailable: { true })
        )
        for budget in [2_000, 1_500, 1_000, 800] {
            let turn = try await orchestrator.respond(to: "Hi", tokenBudget: budget)
            if case .reply(let text, _, let didTrim) = turn, didTrim {
                #expect(text == "reply")
                return
            }
            // An offer means the probe dropped past the reserve floor --
            // keep going only while turns still answer.
            guard case .reply = turn else { break }
        }
        Issue.record("no probed budget produced a trimmed reply -- trimming window collapsed?")
    }

    @Test("offer turns persist a linkable snapshot")
    func offerSnapshotStored() async throws {
        // §8: offers link like replies -- the persisted row must exist for
        // the trace UI even though no model ran.
        let (orchestrator, container, _) = try makeOrchestrator()
        let turn = try await orchestrator.respond(to: "Hi", tokenBudget: 1)
        guard case .escalationOffer(_, let snapshotID) = turn else {
            Issue.record("expected an offer, got \(turn)")
            return
        }
        let context = ModelContext(container)
        let stored = try context.fetch(FetchDescriptor<ContextSnapshot>(
            predicate: #Predicate { $0.id == snapshotID }
        ))
        #expect(stored.count == 1)
    }

    @Test("error payloads are single-line and bounded")
    func errorPayloadSanitized() async throws {
        struct Messy: Error, CustomStringConvertible {
            var description: String {
                String(repeating: "x", count: 500) + "\nsecond line with details"
            }
        }
        let recording = RecordingBuild()
        recording.failure = Messy()
        let (orchestrator, _, _) = try makeOrchestrator(recording: recording)
        await #expect {
            try await orchestrator.respond(to: "Hi")
        } throws: { error in
            guard case .underlying(let summary) = error as? CoachError else { return false }
            return !summary.contains("\n") && summary.count <= 300
        }
    }
}
