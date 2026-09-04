// CoachOrchestrator.swift
//
// WP-27 (implementation-plan.md step 2): owns prompt assembly (always via
// `PromptManager` => safety suffix on every tier, D10/D8), context
// snapshotting, dispatch through `CoachSessionFactory` (WP-22), and error
// normalization into `CoachError`.
//
// Escalation (D14.2) is offer-only: on-device context-over-budget (reported
// by WP-20's `promptOverBudget`) or an explicit "deeper analysis" request
// returns `.escalationOffer`, never an automatic tier switch. The UI renders
// the offer; switching stays a user action (D14.2).

import CoreModel
import Foundation
import FoundationModels

/// Why the orchestrator offers a bigger tier instead of answering.
public enum EscalationReason: String, Sendable, Equatable {
    /// The assembled context (prompt reserve included) overflowed the
    /// on-device window.
    case contextOverBudget
    /// The user explicitly asked for deeper analysis.
    case deeperAnalysisRequested
}

/// One orchestrated turn. Either a model reply or an escalation offer --
/// both carry the persisted snapshot ID so the trace UI (WP-32) links
/// offers exactly like replies.
public enum OrchestratorTurn: Sendable, Equatable {
    /// `didTrim` surfaces WP-20's fields-dropped signal on the reply (WP-27
    /// review §3, option b): trimmed-but-fitting turns answer, deliberately
    /// without an escalation offer (per-turn offers on every rich-profile
    /// turn would be offer fatigue -- the context fit, only reduced), and
    /// the UI can render a quiet "reduced context" affordance instead.
    /// Only `promptOverBudget` (the prompt itself can't fit) offers.
    case reply(text: String, snapshotID: UUID, info: TurnInfo)
    case escalationOffer(reason: EscalationReason, snapshotID: UUID)
}

/// Reply metadata (F4): the third associated value was the signal --
/// at four flags the tuple became match-noise across every call site, and
/// the serving-tier stamp (D15) is already coming. One struct, memberwise
/// defaults, `Equatable` so tests compare whole values.
public struct TurnInfo: Sendable, Equatable {
    /// Fields were dropped to fit the window (quiet reduced-context
    /// affordance; only `promptOverBudget` offers).
    public var didTrim: Bool
    /// PCC quota is near its daily limit (D14.3 -- the UI says so).
    public var quotaWarning: Bool
    /// The turn was requested on this tier but served on-device after
    /// quota exhaustion (D14.3 -- the UI says so: "PCC limit reached,
    /// answered on-device"). Nil when the serving tier is the requested
    /// tier. Offers pass through untouched (no serving happened).
    public var fellBackFromTier: ModelTier?
    public init(didTrim: Bool = false, quotaWarning: Bool = false, fellBackFromTier: ModelTier? = nil) {
        self.didTrim = didTrim
        self.quotaWarning = quotaWarning
        self.fellBackFromTier = fellBackFromTier
    }
}

/// Owns the turn pipeline. A `@MainActor final class` like its
/// collaborators (`PromptManager`, `ContextAssembler`,
/// `CoachSessionFactory` are all actor-isolated classes, not `Sendable`
/// values). Session construction stays injected (defaulting to the live
/// on-device factory) so unit tests script the model seam and the
/// suffix/escalation/snapshot assertions run on both matrix toolchains
/// without a model.
@MainActor
public final class CoachOrchestrator: Sendable {
    /// `let`, not `var` (WP-27 review O4): collaborators are fixed at
    /// construction -- any holder could otherwise swap the factory
    /// mid-stream and the compiler wouldn't stop it. Tests construct fresh
    /// orchestrators rather than mutating.
    public let prompts: PromptManager
    public let assembler: ContextAssembler
    public let sessions: CoachSessionFactory
    public let catalog: ModelCatalog

    public init(
        prompts: PromptManager,
        assembler: ContextAssembler,
        sessions: CoachSessionFactory = CoachSessionFactory(),
        catalog: ModelCatalog? = nil
    ) {
        self.prompts = prompts
        self.assembler = assembler
        self.sessions = sessions
        // Nil means the live wiring. Not a default argument (`= .live()`)
        // because default arguments evaluate outside actor isolation and
        // the live catalog reads the MainActor-bound availability gate.
        self.catalog = catalog ?? ModelCatalog.live()
    }

    /// Runs one turn on `tier`: effective prompt (suffix always on) as
    /// session instructions, assembled + snapshotted context framed as data
    /// under the user message, dispatch through the session factory, errors
    /// normalized to `CoachError`.
    ///
    /// - Parameter tokenBudget: context window for this turn. Defaults to
    ///   the tier's own window (`ModelCatalog.tokenBudget(for:)` -- WP-27
    ///   review §5), so PCC turns aren't silently trimmed to 4K and
    ///   on-device turns escalate when they should. Explicit override stays
    ///   for tests forcing the escalation path.
    public func respond(
        to message: String,
        purpose: ContextAssembler.Purpose = .chat,
        tier: ModelTier = .onDevice,
        tools: [any Tool] = [],
        toolSetID: String? = nil,
        tokenBudget: Int? = nil
    ) async throws(CoachError) -> OrchestratorTurn {
        guard catalog.isEnabled(tier) else {
            throw .tierUnavailable(tier: tier, reason: Self.unavailableReason(for: tier, in: catalog))
        }
        // Defense in depth (WP-27 review §4): the catalog gate should have
        // stopped a keyless tier first, but a TOCTOU key deletion (or a
        // miswired `hasKey`) must throw before any dispatch, never build a
        // keyless session.
        guard !tier.requiresAPIKey || catalog.hasKey(tier) else {
            throw CoachError.missingCredential(tier: tier)
        }
        // PCC quota pre-dispatch (D14.3): exhausted falls back to on-device
        // (a fresh on-device turn -- budget reset to the tier default, so a
        // 32K PCC budget can't suppress on-device escalation); near-limit
        // dispatches with the warning bit the UI renders.
        var quotaWarning = false
        if tier == .privateCloudCompute {
            switch catalog.pccQuota() {
            case .exhausted:
                // F3 decision: availability stays green (the turn CAN run --
                // via fallback) and the reply carries the fallback flag so
                // the UI says so (D14.3). Gating availability red instead
                // would block the fallback the plan requires.
                let turn = try await respond(
                    to: message,
                    purpose: purpose,
                    tier: .onDevice,
                    tools: tools,
                    toolSetID: toolSetID,
                    tokenBudget: nil
                )
                guard case .reply(let text, let snapshotID, var info) = turn else {
                    return turn
                }
                info.fellBackFromTier = .privateCloudCompute
                return .reply(text: text, snapshotID: snapshotID, info: info)
            case .nearLimit:
                quotaWarning = true
            case .ok:
                break
            }
        }
        // PromptManager is the ONLY source of instructions (D10/D8): every
        // tier, every turn, user base + immutable safety suffix. A store
        // failure is a turn failure, not a silent suffix-less fallback.
        let instructions: String
        do {
            instructions = try prompts.effectivePrompt()
        } catch {
            throw CoachError.underlying(CoachError.sanitizedSummary(String(describing: error)))
        }
        // Snapshot persists inside `assemble` (WP-20); the ID rides the
        // result so chat turns link to it (WP-32 trace UI). Offer turns
        // persist too, deliberately (WP-27 review §8): offers link like
        // replies, retention is the shared `pruneSnapshots` cap, and
        // skipping the write for deeper-analysis pokes would leave the
        // accepted turn's snapshot unlinkable.
        let assembled: ContextAssembler.AssembledContext
        do {
            assembled = try assembler.assemble(
                for: purpose,
                tokenBudget: tokenBudget ?? catalog.tokenBudget(for: tier),
                promptTokens: PromptManager.estimatedTokens(for: instructions)
            )
        } catch {
            throw CoachError.underlying(CoachError.sanitizedSummary(String(describing: error)))
        }
        // D14.2 offers, in documented-trigger order: budget overflow first
        // (it dominates -- a deeper request inside an overflowed context
        // still can't run on-device), then the explicit deeper-analysis
        // ask. Either returns instead of dispatching: offering IS the turn.
        // PCC is the offered tier today (first escalation rung, D14); only
        // on-device turns can escalate (a bigger tier has nowhere to go).
        if tier == .onDevice, assembled.promptOverBudget {
            return .escalationOffer(reason: .contextOverBudget, snapshotID: assembled.snapshotID)
        }
        if tier == .onDevice, Self.requestsDeeperAnalysis(message) {
            return .escalationOffer(reason: .deeperAnalysisRequested, snapshotID: assembled.snapshotID)
        }
        let session = sessions.makeSession(
            for: CoachSessionFactory.Purpose(purpose),
            instructions: instructions,
            tools: tools,
            toolSetID: toolSetID,
            tier: tier
        )
        do {
            // Framing via the shared composer (R1): the user message plus
            // context-as-data block, one literal owned by `HealthContext`.
            let text = try await session.respond(to: assembled.context.promptBlock(message: message))
            return .reply(
                text: text,
                snapshotID: assembled.snapshotID,
                info: TurnInfo(didTrim: assembled.didTrim, quotaWarning: quotaWarning)
            )
        } catch {
            throw Self.normalize(error, on: tier)
        }
    }

    /// Explicit "deeper analysis" ask (D14.2, second trigger). One
    /// locale-independent case-insensitive pass per phrase (WP-27 review
    /// O2): the earlier `lowercased().contains` mis-folded Turkic dotted-İ
    /// and friends. Still substring matching without word boundaries -- the
    /// beta tuning point (architecture.md D15.4) -- and the table test pins
    /// both hits and near-miss behavior.
    static func requestsDeeperAnalysis(_ message: String) -> Bool {
        Self.deeperAnalysisPhrases.contains {
            message.range(of: $0, options: .caseInsensitive) != nil
        }
    }

    private static let deeperAnalysisPhrases = [
        "deeper analysis",
        "more detailed analysis",
        "go deeper",
        "think harder",
        "thorough analysis",
        "detailed analysis",
    ]

    /// Maps a catalog availability report onto the `tierUnavailable` reason
    /// so the thrown error and the Settings copy agree word-for-word. The
    /// `.available` arm is unreachable by construction (WP-27 review §11):
    /// `isEnabled` and `availability == .available` are the same
    /// `isLive`+consent+key predicate, so a disabled tier always carries a
    /// reason -- the fallback survives only as defense against future drift.
    private static func unavailableReason(for tier: ModelTier, in catalog: ModelCatalog) -> String {
        switch catalog.availability(for: tier) {
        case .available:
            "This tier is unavailable right now."
        case .unavailable(let reason):
            reason
        }
    }

    /// Session-thrown errors become `CoachError`. The framework mapping is
    /// toolchain-gated (the declaration is 27-SDK-only); everything else is
    /// a transport/store failure the UI renders generically per D11. The
    /// tier rides along so overflow-escalation is decided structurally in
    /// the mapping (F2), not adjusted at the catch site.
    private static func normalize(_ error: Error, on tier: ModelTier) -> CoachError {
#if swift(>=6.4)
        // The cast needs the SDK's own availability: package tests execute
        // on macOS 26 hosts, where the 27-only conformance can't run.
        // Unreachable there in practice (a `LanguageModelError` can only
        // be thrown by 27-only framework code), so the fallthrough is the
        // live path on 26 and dead code on 27+.
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *),
           let lmError = error as? LanguageModelError
        {
            return CoachError(languageModelError: lmError, on: tier)
        }
#endif
        return .underlying(CoachError.sanitizedSummary(String(describing: error)))
    }
}
