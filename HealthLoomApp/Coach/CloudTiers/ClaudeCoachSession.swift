// ClaudeCoachSession.swift
//
// WP-85: the Claude tier's session. The factory builds sessions
// synchronously, but the user's API key lives in the Keychain, which reads
// asynchronously. So this session holds no key when it's built: its first
// answer reads the key, builds the real session (`makeProviderSession` over
// `ClaudeLanguageModel`), and every later answer reuses it. The key is read
// once per session, at the moment the session first needs it, and lives
// only inside that session's model.
//
// A missing key fails the answer with `.missingCredential` and leaves the
// session unbuilt, so a key entered afterwards works on the next turn
// without a new conversation. Package credential errors are mapped to
// `CoachError` here, at the source, so the streaming path (which the
// orchestrator doesn't normalize) shows the same named copy as `respond`.

import ClaudeForFoundationModels
import CoachKit
import Foundation
import FoundationModels
import Secrets

@MainActor
final class ClaudeCoachSession: CoachSession {
    /// Builds the real session for a key. Production wraps
    /// `ClaudeTier.makeModel` in `makeProviderSession`; tests inject a
    /// scripted session so no test reaches Anthropic.
    typealias Build = @MainActor (_ apiKey: String) -> any CoachSession

    private let readKey: @Sendable () async throws -> String?
    private let build: Build
    private var session: (any CoachSession)?

    init(readKey: @escaping @Sendable () async throws -> String?, build: @escaping Build) {
        self.readKey = readKey
        self.build = build
    }

    /// The production session: the key from `keys`, the model the user
    /// picked (`modelID`, resolved through `ClaudeTier.model(id:)`).
    convenience init(keys: any CloudKeyStoring, modelID: String?, instructions: String, tools: [any Tool]) {
        let model = ClaudeTier.model(id: modelID)
        self.init(
            readKey: { try await keys.get(.claudeAPIKey) },
            build: { apiKey in
                makeProviderSession(
                    model: ClaudeTier.makeModel(apiKey: apiKey, model: model),
                    instructions: instructions,
                    tools: tools
                )
            }
        )
    }

    var isResponding: Bool { session?.isResponding ?? false }

    /// Warms the built session only. Before the first turn there is nothing
    /// to warm without reading the key, and a warm-up must not read it.
    /// The Claude provider has no tokenizer API to measure with; forwarded
    /// so the adapter never claims a fit its built session didn't report.
    func contextFit(adding prompt: String) async -> ContextFit? {
        await session?.contextFit(adding: prompt)
    }

    func prewarm() {
        session?.prewarm()
    }

    func respond(to prompt: String) async throws -> String {
        do {
            return try await resolved().respond(to: prompt)
        } catch {
            throw Self.mapped(error)
        }
    }

    func respond<Content: Generable>(to prompt: String, generating type: Content.Type) async throws -> Content {
        do {
            return try await resolved().respond(to: prompt, generating: type)
        } catch {
            throw Self.mapped(error)
        }
    }

    func stream(to prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let deltas = try await resolved().stream(to: prompt)
                    for try await delta in deltas {
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapped(error))
                }
            }
            // A cancelled consumer cancels the pump, which ends the inner
            // stream's iteration and with it the inner session's request.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The built session, reading the key and building it on first use.
    /// An empty stored key counts as missing.
    private func resolved() async throws -> any CoachSession {
        if let session {
            return session
        }
        guard let apiKey = try await readKey(), !apiKey.isEmpty else {
            throw CoachError.missingCredential(tier: .claude)
        }
        // Another turn may have built it while this one read the key.
        if let session {
            return session
        }
        let built = build(apiKey)
        session = built
        return built
    }

    private static func mapped(_ error: Error) -> Error {
        if let claudeError = error as? ClaudeError {
            return CoachError(claudeError: claudeError)
        }
        return error
    }
}
