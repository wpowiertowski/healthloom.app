// ClaudeTierTests.swift
//
// WP-85: the Claude tier's construction (model table, refusal fallbacks,
// no Anthropic-hosted tools, error table) and its session's lazy key read.
// App-target suite: the package links only here. Nothing reaches
// Anthropic: models are built offline, and sessions answer from scripted
// doubles.

import ClaudeForFoundationModels
import CoachKit
import Foundation
import FoundationModels
import Testing

@testable import HealthLoom

@Suite("Claude tier")
@MainActor
struct ClaudeTierTests {
    // Pin, not a behavior test: the picker table and default are a product
    // choice, so a change has to be deliberate.
    @Test("the picker offers the current models, Opus 5.5 first and default")
    func modelTable() {
        #expect(ClaudeTier.models == [.opus5_5, .sonnet5_5, .haiku5_5])
        #expect(ClaudeTier.defaultModel == .opus5_5)
        #expect(CloudModelOptions.claudeOptions == ClaudeTier.models.map(\.id))
        #expect(CloudModelOptions.claudeDefault == ClaudeTier.defaultModel.id)
    }

    @Test("a stored model the table no longer offers dispatches the default")
    func staleModelResolves() {
        // Catches: a pre-WP-85 Claude 4.x preference dispatching a retired
        // model, and a valid pick being ignored.
        #expect(ClaudeTier.model(id: ClaudeModel.sonnet5_5.id) == .sonnet5_5)
        #expect(ClaudeTier.model(id: "claude-haiku-4-5-20251001") == ClaudeTier.defaultModel)
        #expect(ClaudeTier.model(id: nil) == ClaudeTier.defaultModel)
    }

    @Test("refusal fallbacks only where the model supports them")
    func fallbacksPerModel() {
        // Catches: fallbacks sent for Haiku 5.5 (the API rejects the
        // request) or dropped for Opus/Sonnet 5.5.
        #expect(ClaudeTier.fallbacks(for: .opus5_5) == .serverDefault)
        #expect(ClaudeTier.fallbacks(for: .sonnet5_5) == .serverDefault)
        #expect(ClaudeTier.fallbacks(for: .haiku5_5) == [])
    }

    @Test("the model carries the key's model and no Anthropic-hosted tools")
    func modelConstruction() {
        // Catches: D11 -- health-derived text reaching Anthropic's search or
        // sandbox through hosted tools, a proxy base URL, or the wrong model.
        // Construction stays offline: the package validates nothing at init.
        for model in ClaudeTier.models {
            let built = ClaudeTier.makeModel(apiKey: "test-key", model: model)
            #expect(built.model == model)
            #expect(built.serverTools.isEmpty)
            #expect(built.baseURL == ClaudeLanguageModel.defaultBaseURL)
            #expect(built.fallbacks == ClaudeTier.fallbacks(for: model))
        }
    }

    @Test("package credential errors map to named coach errors")
    func errorTable() {
        // Catches: a revoked key (the package's `missingCredential`) shown as
        // a generic failure instead of "re-enter it in Settings".
        #expect(CoachError(claudeError: .missingCredential) == .missingCredential(tier: .claude))
        #expect(
            CoachError(claudeError: .attestationUnsupported)
                == .tierUnavailable(tier: .claude, reason: "Claude sign-in isn't supported on this device.")
        )
        #expect(
            CoachError(claudeError: .attestationFailed)
                == .tierUnavailable(tier: .claude, reason: "Claude sign-in failed. Try again.")
        )
    }
}

@Suite("Claude session")
@MainActor
struct ClaudeCoachSessionTests {
    /// Scripted key store and build counter. `nonisolated`: the session
    /// reads the key from a `@Sendable` closure off the main actor.
    nonisolated final class Fixture: @unchecked Sendable {
        private let lock = NSLock()
        private var key: String?
        private var _keyReads = 0
        private var _builtWithKeys: [String] = []

        var keyReads: Int { lock.withLock { _keyReads } }
        var builtWithKeys: [String] { lock.withLock { _builtWithKeys } }

        init(key: String?) {
            self.key = key
        }

        func setKey(_ key: String?) {
            lock.withLock { self.key = key }
        }

        func readKey() -> String? {
            lock.withLock {
                _keyReads += 1
                return key
            }
        }

        @MainActor
        func session(inner: any CoachSession = TestCoachSession(chunks: ["Hi"], chunkDelay: .zero)) -> ClaudeCoachSession {
            ClaudeCoachSession(
                readKey: { self.readKey() },
                build: { apiKey in
                    self.lock.withLock { self._builtWithKeys.append(apiKey) }
                    return inner
                }
            )
        }
    }

    @Test("no key fails the turn without building; a key entered later works")
    func missingKeyThenKey() async throws {
        // Catches: a keyless session being built, and a failed first turn
        // leaving the session unusable after the user enters a key.
        let fixture = Fixture(key: nil)
        let session = fixture.session()
        await #expect(throws: CoachError.missingCredential(tier: .claude)) {
            try await session.respond(to: "hello")
        }
        #expect(fixture.builtWithKeys.isEmpty)
        fixture.setKey("sk-test")
        #expect(try await session.respond(to: "hello") == "Hi")
        #expect(fixture.builtWithKeys == ["sk-test"])
    }

    @Test("an empty stored key counts as missing")
    func emptyKeyIsMissing() async {
        // Catches: building a session with an empty credential.
        let fixture = Fixture(key: "")
        let session = fixture.session()
        await #expect(throws: CoachError.missingCredential(tier: .claude)) {
            try await session.respond(to: "hello")
        }
        #expect(fixture.builtWithKeys.isEmpty)
    }

    @Test("the key is read once; later turns reuse the built session")
    func keyReadOnce() async throws {
        // Catches: a Keychain read and a fresh session (dropping the
        // transcript) on every turn.
        let fixture = Fixture(key: "sk-test")
        let session = fixture.session()
        _ = try await session.respond(to: "one")
        var streamed = ""
        for try await delta in session.stream(to: "two") {
            streamed += delta
        }
        #expect(streamed == "Hi")
        #expect(fixture.keyReads == 1)
        #expect(fixture.builtWithKeys == ["sk-test"])
    }

    @Test("a package error mid-stream arrives as the named coach error")
    func streamErrorsAreMapped() async {
        // Catches: the streaming path (which the orchestrator doesn't
        // normalize) surfacing a raw package error for a revoked key.
        let fixture = Fixture(key: "sk-test")
        let session = fixture.session(inner: FailingStreamSession(error: ClaudeError.missingCredential))
        await #expect(throws: CoachError.missingCredential(tier: .claude)) {
            for try await _ in session.stream(to: "hello") {}
        }
    }

    @Test("warm-up before the first turn doesn't read the key")
    func prewarmReadsNoKey() {
        // Catches: opening the chat (which warms the session) reading the
        // Keychain for a tier the user hasn't sent a turn to.
        let fixture = Fixture(key: "sk-test")
        let session = fixture.session()
        session.prewarm()
        #expect(fixture.keyReads == 0)
        #expect(fixture.builtWithKeys.isEmpty)
    }
}

/// Streams nothing and fails with `error`.
private final class FailingStreamSession: CoachSession, Sendable {
    let error: any Error & Sendable

    init(error: any Error & Sendable) {
        self.error = error
    }

    var isResponding: Bool { false }
    func prewarm() {}
    func contextFit(adding prompt: String) async -> ContextFit? { nil }
    func servedModelID() async -> String? { nil }
    func respond(to prompt: String) async throws -> String { throw error }
    func respond<Content: Generable>(to prompt: String, generating type: Content.Type) async throws -> Content {
        throw error
    }
    func stream(to prompt: String) -> AsyncThrowingStream<String, Error> {
        let error = error
        return AsyncThrowingStream { $0.finish(throwing: error) }
    }
}
