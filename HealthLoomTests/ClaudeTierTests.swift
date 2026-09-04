// ClaudeTierTests.swift
//
// WP-28b "Tests" line: adapter construction (default model, no server
// tools) + `ClaudeError` mapping table. App-target suite: the package is
// only linked here (CoachKit's macOS 26 floor can't take the dependency),
// and these tests execute on the iOS simulator under the beta toolchain.

import ClaudeForFoundationModels
import CoachKit
import Testing

@testable import HealthLoom

@Suite("Claude tier")
@MainActor
struct ClaudeTierTests {
    @Test("default model is the pinned constant")
    func defaultModel() {
        #expect(ClaudeTier.defaultModel.id == ClaudeModel.sonnet5.id)
    }

    @Test("server tools are never configured")
    func noServerTools() {
        // D11: health-derived text must never reach Anthropic's server-side
        // search/code infrastructure. The only tool path is the
        // framework's client-side `tools:` array, wired per session.
        let model = ClaudeTier.makeModel(apiKey: "test-key")
        #expect(model.serverTools.isEmpty)
        #expect(model.baseURL == ClaudeLanguageModel.defaultBaseURL)
    }

    @Test("provider error table")
    func errorTable() {
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
