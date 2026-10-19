// ClaudeTier.swift
//
// WP-85 (implementation-plan.md WP-28b): the Claude off-device tier behind
// the D9 seam -- Anthropic's official `ClaudeForFoundationModels` package,
// no REST client in this repo for dispatch.
//
// App-target placement is deliberate: the package requires iOS/macOS 27,
// which CoachKit's macOS 26 test floor can't link. CoachKit owns the tier
// contract (`ModelTier.claude`, `SecretKey.claudeAPIKey`, the catalog's
// consent/key/live gating); this file owns the provider construction the
// package makes possible.
//
// Only client-side tools ever reach Claude: the framework's `tools:` array,
// wired per session. The package's Anthropic-hosted tools (web search, code
// execution) are never configured -- they would move health-derived text
// into Anthropic's search and sandbox infrastructure (D11). CI's
// launch-gate guard fails on any mention of that parameter in app code.

import ClaudeForFoundationModels
import CoachKit
import Foundation
import FoundationModels

enum ClaudeTier {
    /// The models the AI Models picker offers, newest generation only, from
    /// the package's own constants -- one table for the picker, the key
    /// check, and dispatch.
    static let models: [ClaudeModel] = [.opus5_5, .sonnet5_5, .haiku5_5]

    /// Opus 5.5: the current default Claude model.
    static let defaultModel = ClaudeModel.opus5_5

    /// The key check's model. Any model proves the key; the cheapest one
    /// keeps the one-token check close to free.
    static let keyCheckModel = ClaudeModel.haiku5_5

    /// The table entry for a stored model ID. An ID the table no longer
    /// lists (a pre-WP-85 Claude 4.x pick) falls back to the default, so a
    /// stale preference can't dispatch to a retired model.
    static func model(id: String?) -> ClaudeModel {
        models.first { $0.id == id } ?? defaultModel
    }

    /// Server-side refusal fallbacks: the API's default substitute where the
    /// model supports one (Opus 5.5, Sonnet 5.5). Haiku 5.5 has none, and
    /// the API rejects the field for it, so it sends no fallbacks.
    static func fallbacks(for model: ClaudeModel) -> ClaudeFallbacks {
        model.id == ClaudeModel.haiku5_5.id ? [] : .serverDefault
    }

    /// The framework model for the user's runtime key (BYO key, entered in
    /// Settings and kept in the Keychain -- not a developer key in the
    /// binary).
    static func makeModel(apiKey: String, model: ClaudeModel) -> ClaudeLanguageModel {
        ClaudeLanguageModel(name: model, auth: .apiKey(apiKey), fallbacks: fallbacks(for: model))
    }
}

extension CoachError {
    /// The package's credential errors as the normalized UI-facing cases.
    /// `missingCredential` is also what the package throws for a key the
    /// API rejects (HTTP 401), so a revoked key reads as "re-enter it in
    /// Settings". Attestation cases can't arise under `.apiKey`, but the
    /// switch stays exhaustive with fixed copy. `LanguageModelError`s pass
    /// through untouched to the existing framework mapping.
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
