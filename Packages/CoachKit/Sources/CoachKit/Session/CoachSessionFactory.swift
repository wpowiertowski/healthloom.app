// CoachSessionFactory.swift
//
// WP-22 (implementation-plan.md): builds `LiveCoachSession`s for the on-device
// model. The on-device arm stays concrete over `SystemLanguageModel`: package
// tests run on macOS 26 hosts, where the 27-only `LanguageModel` protocol
// can't execute. Off-device tiers plug in through `init(providers:)` (WP-85),
// each provider build made with `makeProviderSession(model:...)` by the
// module that owns that provider.
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

    /// Session constructor. Takes the tier (WP-32 F1): routing lives here,
    /// not in the cache — the cache segregates per-tier histories, the
    /// builder decides which model serves. Tests inject per-tier routing
    /// explicitly, which is what lets the suite prove model identity per
    /// tier instead of only slot segregation.
    /// Tier, provider configuration, instructions, tools (see `Provider`).
    private let build: @MainActor @Sendable (ModelTier, String, String, [any Tool]) -> any CoachSession
    // One conversation slot per tier (F12): toggling on-device<->PCC
    // mid-conversation keeps each tier's transcript (the transcript IS the
    // memory) instead of evicting it on every toggle. Bounded by
    // construction -- at most one entry per `ModelTier` case, prompt edits
    // overwrite within the tier rather than growing a prompt-keyed dict.
    private var cachedConversations: [ModelTier: (instructions: String, toolSetKey: String, configuration: String, session: any CoachSession)] = [:]

    /// - Parameter build: session constructor (tier first, then
    ///   instructions and tools). Defaults to a live on-device session with
    ///   every other tier fail-closed (`UnwiredTierSession`) until that
    ///   tier's adapter lands with the flip — a live+enabled-but-unwired
    ///   tier errors namedly instead of serving on-device output badged as
    ///   cloud (WP-32 F1). Tests inject a scripted double so no unit test
    ///   touches the model (real generation is covered by on-device manual
    ///   tests, test plan §7). `@MainActor`-bound because constructing a
    ///   `LiveCoachSession` is actor-isolated.
    public init(build: (@MainActor @Sendable (ModelTier, String, [any Tool]) -> any CoachSession)? = nil) {
        if let build {
            self.build = { tier, _, instructions, tools in build(tier, instructions, tools) }
        } else {
            self.build = Self.defaultBuild(providers: [:])
        }
        self.configuration = { _ in "" }
    }

    /// One off-device tier's session source (WP-85), built by the module
    /// that owns the provider (the app target for Claude, whose package
    /// CoachKit doesn't link) with `makeProviderSession(model:...)`.
    public struct Provider: Sendable {
        /// The tier's current configuration (for Claude, the model the
        /// user picked), read on every `makeSession`. It is part of the
        /// conversation cache key, so changing it builds a new session
        /// instead of reusing one built for the old configuration, and the
        /// same value is handed to `build`, so key and session can't
        /// disagree.
        public let configuration: @MainActor @Sendable () -> String
        /// Configuration, instructions and tools in; a session answering
        /// from that tier's model out.
        public let build: @MainActor @Sendable (String, String, [any Tool]) -> any CoachSession

        public init(
            configuration: @escaping @MainActor @Sendable () -> String,
            build: @escaping @MainActor @Sendable (_ configuration: String, _ instructions: String, _ tools: [any Tool]) -> any CoachSession
        ) {
            self.configuration = configuration
            self.build = build
        }
    }

    /// Live factory with off-device tiers wired (WP-85). On-device stays
    /// built in; each tier in `providers` answers from its own build, and
    /// every other tier stays fail-closed (`UnwiredTierSession`), exactly as
    /// in the default factory. An `.onDevice` entry is ignored: on-device
    /// construction lives here only, so no caller can swap the default
    /// model out from under the on-device badge.
    public init(providers: [ModelTier: Provider]) {
        let offDevice = providers.filter { $0.key != .onDevice }
        self.build = Self.defaultBuild(providers: offDevice)
        self.configuration = { tier in offDevice[tier]?.configuration() ?? "" }
    }

    private static func defaultBuild(
        providers: [ModelTier: Provider]
    ) -> @MainActor @Sendable (ModelTier, String, String, [any Tool]) -> any CoachSession {
        { tier, configuration, instructions, tools in
            switch tier {
            case .onDevice:
                return LiveCoachSession(
                    session: LanguageModelSession(
                        model: SystemLanguageModel.default,
                        tools: tools,
                        instructions: instructions
                    )
                )
            case .privateCloudCompute, .claude, .gemini:
                guard let provider = providers[tier] else {
                    return UnwiredTierSession(tier: tier)
                }
                return provider.build(configuration, instructions, tools)
            }
        }
    }

    /// The tier's provider configuration (WP-85), "" for tiers without one.
    /// A dimension of the conversation cache key.
    private let configuration: @MainActor @Sendable (ModelTier) -> String

    /// Builds (or, for conversations, reuses) a session for `purpose` with the
    /// effective prompt (user base + `SafetyLayer` suffix, D10) as
    /// instructions. A cached conversation session is reused only while the
    /// instructions, the tool-set identity *and* the tier's provider
    /// configuration (WP-85: the picked Claude model) are unchanged -- a prompt
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
    /// - Parameter tier: the model tier the session runs on (WP-28). Part of
    ///   the conversation cache key alongside instructions and tool set: the
    ///   same prompt on PCC must not reuse the on-device session (wrong
    ///   model, wrong privacy boundary, D11/D14.1). Defaults to on-device so
    ///   pre-tier call sites are unaffected.
    public func makeSession(
        for purpose: Purpose,
        instructions: String,
        tools: [any Tool] = [],
        toolSetID: String? = nil,
        tier: ModelTier = .onDevice
    ) -> any CoachSession {
        let cacheKey = if let toolSetID {
            "id:\(toolSetID)"
        } else {
            "names:\(tools.map(\.name).joined(separator: "\0"))"
        }
        // Read once: the same value keys the cache and builds the session.
        let providerConfiguration = self.configuration(tier)
        if !Self.requiresFreshSession(for: purpose),
           let cached = cachedConversations[tier],
           cached.instructions == instructions,
           cached.toolSetKey == cacheKey,
           cached.configuration == providerConfiguration
        {
            return cached.session
        }
        let session = build(tier, providerConfiguration, instructions, tools)
        if !Self.requiresFreshSession(for: purpose) {
            cachedConversations[tier] = (instructions, cacheKey, providerConfiguration, session)
        }
        return session
    }

    /// Drops all cached conversation sessions (prompt edited globally,
    /// conversation closed). The next `.conversation` request builds fresh.
    /// Tier switches do NOT reset -- the per-tier slots keep each
    /// transcript across toggles (F12), so this stays the explicit
    /// conversation-close path, not a second tier guard.
    public func resetConversation() {
        cachedConversations = [:]
    }
}
