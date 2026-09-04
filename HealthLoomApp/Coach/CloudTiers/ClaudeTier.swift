// ClaudeTier.swift
//
// WP-28b (implementation-plan.md): the Claude off-device tier behind the
// D9 seam -- Anthropic's official `ClaudeForFoundationModels` package, no
// REST client in this repo.
//
// App-target placement is deliberate, not drift: the package requires
// macOS/iOS 27, which CoachKit's macOS 26 floor (stable matrix toolchain)
// cannot link. CoachKit owns the tier contract (`ModelTier.claude`,
// `SecretKey.claudeAPIKey`, `isEnabled`/`missingCredential` gating -- all
// toolchain-independent and unit-tested there); this file owns only the
// provider construction the package makes possible. Nothing here goes live
// until WP-29's key/consent UI flips the row.

import ClaudeForFoundationModels
import CoachKit
import Foundation
import FoundationModels

/// Claude tier construction.
enum ClaudeTier {
    /// Default model from the package's `ClaudeModel` constants table (the
    /// WP-29 picker will offer the table; this is the pre-picker default).
    /// Sonnet-class: the balanced default -- opus-class reasoning is
    /// overkill for health coaching turns, haiku-class under-reads them.
    static let defaultModel = ClaudeModel.sonnet5

    /// Builds the framework model for the user's runtime key. `serverTools`
    /// is never configured (D11): `.webSearch`/`.webFetch`/`.codeExecution`
    /// would move health-derived text into Anthropic's search
    /// infrastructure -- the framework's client-side `tools:` array (wired
    /// per-session below) is the only tool path.
    static func makeModel(apiKey: String) -> ClaudeLanguageModel {
        ClaudeLanguageModel(name: defaultModel, auth: .apiKey(apiKey))
    }

    /// `CoachSessionFactory` build closure answering from Claude: the same
    /// `LiveCoachSession` adapter as every other tier (D9 -- providers
    /// differ only in the model handed to the session).
    @MainActor
    static func makeBuild(apiKey: String) -> @MainActor @Sendable (String, [any Tool]) -> any CoachSession {
        makeProviderSessionBuild(model: makeModel(apiKey: apiKey))
    }
}

extension CoachError {
    /// Maps the provider's errors onto the normalized UI-facing cases.
    /// `missingCredential` mirrors the orchestrator's pre-dispatch guard
    /// (defense in depth: same case either way); attestation failures are
    /// auth-setup states, so they read as tier-unavailable with fixed
    /// copy (fixed strings -- no redaction concern, no sanitizer needed).
    /// `LanguageModelError`s from Claude sessions flow through the existing
    /// framework mapping, untouched here.
    init(claudeError: ClaudeError) {
        switch claudeError {
        case .missingCredential:
            self = .missingCredential(tier: .claude)
        case .attestationUnsupported:
            self = .tierUnavailable(tier: .claude, reason: "Claude sign-in isn't supported on this device.")
        case .attestationFailed:
            self = .tierUnavailable(tier: .claude, reason: "Claude sign-in failed. Try again.")
        }
    }
}
