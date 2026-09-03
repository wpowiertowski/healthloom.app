// CoachSessionFactory.swift
//
// WP-22 (implementation-plan.md): builds `LiveCoachSession`s for the on-device
// model. Deliberately concrete over `SystemLanguageModel` -- never generic over
// a model protocol: the `LanguageModel` protocol only exists in the iOS 27 /
// macOS 27 SDK, while this package's `swift test` matrix also builds on macOS 26
// (Package.swift platforms + CI's macos-26 job), where that symbol is absent
// from the SDK entirely and `@available` cannot gate a missing declaration.
// WP-28 generalizes this factory when the deployment floor allows.
//
// Lifecycle rule (WP-22 step 2): one session per conversation (reused across
// turns -- the transcript is the memory); a fresh session per one-shot task
// (insights), so one-shot prompts never inherit chat history. The rule is
// load-bearing in `makeSession(for:instructions:tools:)` below, not just in
// the pure `requiresFreshSession(for:)` predicate.

import Foundation
import FoundationModels

@MainActor
public final class CoachSessionFactory: Sendable {
    public enum Purpose: Sendable {
        case conversation
        case oneShot

        /// Session lifecycle for an assembly purpose. The two enums live at
        /// different layers (`ContextAssembler.Purpose` names *what the
        /// context is for*, this one names *how the session is reused*), so
        /// they stay separate -- but the translation lives here rather than
        /// being hand-written at every WP-23/WP-25 call site, where a missed
        /// mapping would hand a one-shot the cached conversation session and
        /// leak chat history into an insight (code review WP-21/22 round 4,
        /// #11).
        public init(_ contextPurpose: ContextAssembler.Purpose) {
            switch contextPurpose {
            case .chat: self = .conversation
            case .dailyInsight: self = .oneShot
            }
        }
    }

    /// Pure lifecycle rule: conversations reuse their session, one-shot tasks
    /// always get a fresh one. `makeSession` implements this rule; the
    /// predicate exists so the rule itself is unit-testable without a model.
    public static func requiresFreshSession(for purpose: Purpose) -> Bool {
        switch purpose {
        case .conversation: false
        case .oneShot: true
        }
    }

    private let build: @MainActor @Sendable (String, [any Tool]) -> any CoachSession
    private var cachedConversation: (instructions: String, toolSetKey: String, session: any CoachSession)?

    /// - Parameter build: session constructor. Defaults to a live on-device
    ///   session; tests inject a scripted double so no unit test touches the
    ///   model (real generation is covered by on-device manual tests,
    ///   test plan §7). `@MainActor`-bound because constructing a
    ///   `LiveCoachSession` is actor-isolated.
    public init(build: (@MainActor @Sendable (String, [any Tool]) -> any CoachSession)? = nil) {
        if let build {
            self.build = build
        } else {
            self.build = { instructions, tools in
                LiveCoachSession(
                    session: LanguageModelSession(
                        model: SystemLanguageModel.default,
                        tools: tools,
                        instructions: instructions
                    )
                )
            }
        }
    }

    /// Builds (or, for conversations, reuses) a session for `purpose` with the
    /// effective prompt (user base + `SafetyLayer` suffix, D10) as
    /// instructions. A cached conversation session is reused only while the
    /// instructions *and* the tool-set identity are unchanged -- a prompt
    /// edit or a new tool set busts the cache, so turns never run under
    /// stale instructions or a stale tool set.
    ///
    /// - Parameter toolSetID: caller-controlled identity for the `tools`
    ///   array (e.g. `"v1:steps7d+sleep"`). `Tool.name` defaults to the
    ///   conforming type's name, so distinct configurations of one tool type
    ///   collide on names alone -- callers passing configured tool instances
    ///   (WP-24) must pass a stable ID describing the configuration. Nil
    ///   falls back to the joined tool names (fine for empty or singleton
    ///   sets, not guaranteed unique otherwise). The two forms are
    ///   namespaced, so an explicit ID can never collide with a name-derived
    ///   key that happens to spell the same string (code review WP-21/22
    ///   round 4, #12).
    public func makeSession(
        for purpose: Purpose,
        instructions: String,
        tools: [any Tool] = [],
        toolSetID: String? = nil
    ) -> any CoachSession {
        let cacheKey = if let toolSetID {
            "id:\(toolSetID)"
        } else {
            "names:\(tools.map(\.name).joined(separator: "\0"))"
        }
        if !Self.requiresFreshSession(for: purpose),
           let cached = cachedConversation,
           cached.instructions == instructions,
           cached.toolSetKey == cacheKey
        {
            return cached.session
        }
        let session = build(instructions, tools)
        if !Self.requiresFreshSession(for: purpose) {
            cachedConversation = (instructions, cacheKey, session)
        }
        return session
    }

    /// Drops the cached conversation session (prompt edited, tier switched,
    /// conversation closed). The next `.conversation` request builds fresh.
    public func resetConversation() {
        cachedConversation = nil
    }
}
