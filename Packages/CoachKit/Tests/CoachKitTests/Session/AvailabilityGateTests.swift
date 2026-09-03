// AvailabilityGateTests.swift
//
// WP-22 "Tests" line: availability/quota mapping (inject each case); session
// lifecycle rules (fresh vs reused) as unit logic. No unit test touches the
// model: the factory test injects a scripted `CoachSession` builder, and real
// generation is covered by on-device manual tests (test plan §7).

import Foundation
import FoundationModels
import Testing

@testable import CoachKit

@Suite("AvailabilityGate")
@MainActor
struct AvailabilityGateTests {
    @Test("maps every on-device availability case")
    func mapsEveryCase() {
        #expect(
            AvailabilityGate.status(for: .available) == .available
        )
        #expect(
            AvailabilityGate.status(for: .unavailable(.deviceNotEligible)) == .deviceNotEligible
        )
        #expect(
            AvailabilityGate.status(for: .unavailable(.appleIntelligenceNotEnabled))
                == .appleIntelligenceNotEnabled
        )
        #expect(
            AvailabilityGate.status(for: .unavailable(.modelNotReady)) == .modelNotReady
        )
    }

    @Test("unavailable states carry user copy and a fallback direction")
    func unavailableCopyAndFallback() {
        for state: CoachAvailability in [
            .deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady, .unavailable,
        ] {
            #expect(!state.userMessage.isEmpty)
            #expect(!state.fallbackSuggestion.isEmpty)
        }
        #expect(CoachAvailability.available.fallbackSuggestion.isEmpty)
        #expect(!CoachAvailability.available.userMessage.isEmpty)
    }

    @Test("the neutral case names no specific cause")
    func neutralCaseNamesNoCause() {
        // The @unknown-default mapping must never assert a download (or any
        // other cause) that may never complete.
        let copy = CoachAvailability.unavailable.userMessage.lowercased()
            + CoachAvailability.unavailable.fallbackSuggestion.lowercased()
        #expect(!copy.contains("download"))
    }

    @Test("lifecycle rule: conversations reuse, one-shots are fresh")
    func lifecycleRules() {
        #expect(!CoachSessionFactory.requiresFreshSession(for: .conversation))
        #expect(CoachSessionFactory.requiresFreshSession(for: .oneShot))
    }

    @Test("factory reuses the conversation session and freshens one-shots")
    func factoryLifecycleIsLoadBearing() {
        // Scripted builder: the factory under test never constructs a real
        // `LanguageModelSession`, so this suite has no model dependency.
        let factory = CoachSessionFactory(build: { _, _ in ScriptedCoachSession(chunks: ["ok"]) })
        let conversationA = factory.makeSession(for: .conversation, instructions: "base")
        let conversationB = factory.makeSession(for: .conversation, instructions: "base")
        // Same conversation, same instructions: identical session (shared
        // transcript) -- `!==` here CAN fail, unlike comparing two fresh
        // allocations.
        #expect(conversationA === conversationB)
        // One-shot tasks never share: each call builds fresh so insights
        // can't inherit chat history.
        let oneShotA = factory.makeSession(for: .oneShot, instructions: "base")
        let oneShotB = factory.makeSession(for: .oneShot, instructions: "base")
        #expect(oneShotA !== oneShotB)
        #expect(oneShotA !== conversationA)
        // A prompt edit busts the conversation cache: turns never run under
        // stale instructions.
        let conversationEdited = factory.makeSession(for: .conversation, instructions: "edited")
        #expect(conversationEdited !== conversationA)
        #expect(factory.makeSession(for: .conversation, instructions: "edited") === conversationEdited)
        // A changed tool set busts it too: same instructions but new tools
        // must not return a session built with the old tool set.
        let withTools = factory.makeSession(
            for: .conversation,
            instructions: "edited",
            tools: [StubTool(name: "steps"), StubTool(name: "sleep")]
        )
        #expect(withTools !== conversationEdited)
        #expect(factory.makeSession(
            for: .conversation,
            instructions: "edited",
            tools: [StubTool(name: "steps"), StubTool(name: "sleep")]
        ) === withTools)
        // Explicit reset drops the cache.
        factory.resetConversation()
        #expect(factory.makeSession(for: .conversation, instructions: "edited") !== conversationEdited)
        // Same tool names, different caller IDs: distinct configurations of
        // one tool type must not collide on names alone.
        let sevenDay = factory.makeSession(
            for: .conversation,
            instructions: "tools",
            tools: [StubTool(name: "query")],
            toolSetID: "v1:7d"
        )
        #expect(factory.makeSession(
            for: .conversation,
            instructions: "tools",
            tools: [StubTool(name: "query")],
            toolSetID: "v1:7d"
        ) === sevenDay)
        let thirtyDay = factory.makeSession(
            for: .conversation,
            instructions: "tools",
            tools: [StubTool(name: "query")],
            toolSetID: "v2:30d"
        )
        #expect(thirtyDay !== sevenDay)
    }

    @Test("an explicit tool-set ID never collides with a name-derived key")
    func toolSetIDIsNamespacedAgainstToolNames() {
        // Round-4 #12: the key was `toolSetID ?? joined names`, one flat
        // space -- so an explicit ID that happened to spell the same string
        // as a tool's name handed the second caller the first caller's
        // session, the exact stale-tool-set bug the key exists to prevent.
        let factory = CoachSessionFactory { instructions, _ in
            ScriptedCoachSession(chunks: [instructions])
        }
        let byID = factory.makeSession(
            for: .conversation,
            instructions: "base",
            tools: [],
            toolSetID: "query"
        )
        let byName = factory.makeSession(
            for: .conversation,
            instructions: "base",
            tools: [StubTool(name: "query")]
        )
        #expect(byName !== byID)
    }

    @Test("assembly purpose maps to the matching session lifecycle")
    func purposeMapping() {
        // Round-4 #11: the translation between the two Purpose enums lives in
        // one place, so a WP-23/WP-25 call site can't hand a one-shot the
        // cached conversation session and leak chat history into an insight.
        #expect(CoachSessionFactory.Purpose(ContextAssembler.Purpose.chat) == .conversation)
        #expect(CoachSessionFactory.Purpose(ContextAssembler.Purpose.dailyInsight) == .oneShot)
        #expect(!CoachSessionFactory.requiresFreshSession(
            for: CoachSessionFactory.Purpose(ContextAssembler.Purpose.chat)
        ))
        #expect(CoachSessionFactory.requiresFreshSession(
            for: CoachSessionFactory.Purpose(ContextAssembler.Purpose.dailyInsight)
        ))
    }
}

// MARK: - Scripted seam check (the WP-25 UI-test seam, exercised early)

/// Scripted `CoachSession` double: proves the protocol seam WP-25's UI test
/// will rely on can drive send → stream → done without a model.
@MainActor
final class ScriptedCoachSession: CoachSession, Sendable {
    private let chunks: [String]
    private(set) var receivedPrompts: [String] = []
    var isResponding: Bool { false }

    init(chunks: [String]) {
        self.chunks = chunks
    }

    func prewarm() {}

    func respond(to prompt: String) async throws -> String {
        receivedPrompts.append(prompt)
        return chunks.joined()
    }

    func stream(to prompt: String) -> AsyncThrowingStream<String, Error> {
        receivedPrompts.append(prompt)
        let chunks = chunks
        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}

@Suite("CoachSession seam")
@MainActor
struct CoachSessionSeamTests {
    @Test("scripted session streams chunks in order")
    func scriptedStream() async throws {
        let session = ScriptedCoachSession(chunks: ["Hello", ", ", "world"])
        var collected = ""
        for try await chunk in session.stream(to: "Hi") {
            collected += chunk
        }
        #expect(collected == "Hello, world")
        #expect(try await session.respond(to: "Hi") == "Hello, world")
        #expect(session.receivedPrompts == ["Hi", "Hi"])
    }
}
