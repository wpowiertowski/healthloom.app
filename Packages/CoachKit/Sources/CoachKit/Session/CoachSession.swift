// CoachSession.swift
//
// WP-22 (implementation-plan.md): the thin `CoachSession` seam over
// `LanguageModelSession` so tests (and WP-25's UI test) can inject a scripted
// stream without a model. Real generation is covered by on-device manual tests
// (test plan §7), never by unit tests.

import Foundation
import FoundationModels

/// Minimum surface the chat UI and one-shot tasks need from a model session
/// (WP-22 step 3): one-shot answers, streaming answers, warm-up, and the
/// busy flag that disables input while responding.
///
/// `stream(to:)` yields **incremental deltas**, not cumulative snapshots:
/// joining every yielded chunk in order reproduces the full response.
/// (The framework's `ResponseStream.Snapshot.content` is cumulative --
/// `PartiallyGenerated`, the entire response so far -- so the live adapter
/// diffs consecutive snapshots. A concatenating consumer must receive deltas,
/// or every turn renders as a quadratically duplicated wall of text.)
public protocol CoachSession: AnyObject, Sendable {
    var isResponding: Bool { get }
    func prewarm()
    func respond(to prompt: String) async throws -> String
    func stream(to prompt: String) -> AsyncThrowingStream<String, Error>
    /// Structured (guided-generation) answers for `@Generable` targets.
    /// A protocol requirement -- not a concrete-class extension -- so every
    /// model-touching capability stays behind the seam and `any CoachSession`
    /// holders (factories, generators) can use it; the generic parameter
    /// touches neither `Self` nor an associated type, so it remains callable
    /// through the existential. Test doubles answer from scripted values.
    func respond<Content: Generable>(to prompt: String, generating type: Content.Type) async throws -> Content
    /// How full the model's context window would be if `prompt` were sent
    /// next on this session, counted by the model's own tokenizer over the
    /// whole transcript (instructions, tools, every earlier turn) plus the
    /// prompt. Nil when the session can't measure -- a provider without a
    /// tokenizer API, or a count that failed -- which callers treat as
    /// "send": a real overflow still surfaces as `contextSizeExceeded`.
    /// A requirement (no default) so every session decides explicitly.
    func contextFit(adding prompt: String) async -> ContextFit?
    /// The model that produced this session's latest response, as the
    /// provider reported it (Claude: the API's model ID, the fallback's
    /// after a refusal handover). Nil when the provider reports none
    /// (on-device) or no response was recorded. Read only after a turn
    /// completes: a failed or cancelled turn leaves the previous turn's
    /// response as the latest.
    func servedModelID() async -> String?
}

/// One measured look at a session's context window (WP-86). The per-turn
/// token budget (`ContextAssembler`) bounds a single turn; this bounds the
/// conversation, whose transcript grows with every turn.
public struct ContextFit: Sendable, Equatable {
    /// Tokens kept free for the reply and its tool calls. A working
    /// figure: on-device replies run a few hundred tokens, and a reply
    /// that still runs over fails as `contextSizeExceeded` mid-stream,
    /// which maps to the same overflow copy.
    public static let responseReserve = 1_000

    /// Transcript plus the prompt about to be sent.
    public let tokens: Int
    /// The model's context window.
    public let contextSize: Int

    public init(tokens: Int, contextSize: Int) {
        self.tokens = tokens
        self.contextSize = contextSize
    }

    public var fits: Bool {
        tokens + Self.responseReserve <= contextSize
    }
}

/// Fail-closed session for live-but-unwired tiers (WP-32 F1). Returned by
/// the factory's default build for any non-on-device tier until that tier's
/// adapter lands with the flip: every answering method fails with
/// `.tierUnavailable` (same copy the orchestrator uses for unwired tiers),
/// so a gated-open tier can never serve on-device output badged as cloud.
/// Final class (the protocol is class-bound) with immutable `Sendable`
/// state, so tests on both toolchains can hold one without a model.
public final class UnwiredTierSession: CoachSession, Sendable {
    public let tier: ModelTier

    public init(tier: ModelTier) {
        self.tier = tier
    }

    public var isResponding: Bool { false }

    public func prewarm() {}

    public func respond(to prompt: String) async throws -> String {
        throw CoachError.tierUnavailable(tier: tier, reason: Self.unwiredReason)
    }

    public func respond<Content: Generable>(to prompt: String, generating type: Content.Type) async throws -> Content {
        throw CoachError.tierUnavailable(tier: tier, reason: Self.unwiredReason)
    }

    public func stream(to prompt: String) -> AsyncThrowingStream<String, Error> {
        let error = CoachError.tierUnavailable(tier: tier, reason: Self.unwiredReason)
        return AsyncThrowingStream { $0.finish(throwing: error) }
    }

    /// Nothing to measure: every answering method fails anyway.
    public func contextFit(adding prompt: String) async -> ContextFit? { nil }

    public func servedModelID() async -> String? { nil }

    /// Shared with `CoachOrchestrator`'s unwired-tier throw: one copy for
    /// "live, enabled, but no session provider," owned here next to the
    /// type that raises it.
    public static let unwiredReason = "This tier isn't wired to a session provider yet."
}

/// Live `LanguageModelSession` adapter. Constructed only through
/// `CoachSessionFactory` so model/tools/instructions wiring stays in one place.
///
/// Deliberately NOT `@Observable`: the macro instruments stored `var`s and
/// this class has none (one `let`, one computed forward), so it would be
/// inert decoration implying a guarantee it doesn't provide. `isResponding`
/// re-renders because the wrapped `LanguageModelSession` is itself
/// observable and the forwarding read happens during body evaluation -- that
/// property of the wrapped type is what the chat UI relies on, not this
/// wrapper. Don't add a stored mirror without a sync mechanism.
@MainActor
public final class LiveCoachSession: CoachSession {
    private let session: LanguageModelSession
    /// The on-device model this session runs on, for `contextFit`. Nil for
    /// provider sessions (`makeProviderSession`): the `LanguageModel`
    /// protocol has no tokenizer API, so those never measure.
    private let systemModel: SystemLanguageModel?
    /// Reads the served model off a response entry, for providers that
    /// record one (`makeProviderSession(servedModelID:)`). Nil: the
    /// provider reports nothing, so `servedModelID()` is nil.
    private let modelIDOfResponse: (@Sendable (Transcript.Response) -> String?)?

    init(
        session: LanguageModelSession,
        systemModel: SystemLanguageModel? = nil,
        modelIDOfResponse: (@Sendable (Transcript.Response) -> String?)? = nil
    ) {
        self.session = session
        self.systemModel = systemModel
        self.modelIDOfResponse = modelIDOfResponse
    }

    public var isResponding: Bool { session.isResponding }

    public func prewarm() {
        session.prewarm()
    }

    public func respond(to prompt: String) async throws -> String {
        try await session.respond(to: prompt).content
    }

    /// Structured (guided-generation) variant for `@Generable` targets such
    /// as `DailyInsight` (WP-23). The generic `respond(to:generating:)` is
    /// iOS 26 / macOS 26 API, so this stays available on the package's macOS
    /// 26 test matrix -- unlike the `LanguageModel`-protocol generics, which
    /// don't exist there at all (WP-22).
    public func respond<Content: Generable>(
        to prompt: String,
        generating type: Content.Type
    ) async throws -> Content {
        try await session.respond(to: prompt, generating: type).content
    }

    /// Pure cumulative-to-delta rule (see the protocol contract): the suffix
    /// of `snapshot` after the byte common prefix with `previous`. Static
    /// and model-free so the genuinely tricky logic in WP-22 is unit-testable
    /// without a session -- the package's pure/impure split.
    ///
    /// UTF-8-byte-level, not grapheme-cluster: UTF-8 is prefix-preserving, so
    /// a snapshot extending the last cluster (emoji ZWJ sequence, combining
    /// mark) still shares the byte prefix, and only genuinely new bytes are
    /// yielded instead of re-emitting the whole response. A non-monotonic
    /// snapshot degrades to the suffix after the common prefix -- never drops
    /// new text, never re-emits delivered bytes.
    static func delta(previous: String, snapshot: String) -> String {
        // Walk the UTF-8 views in place. Materializing both strings into
        // fresh `[UInt8]` arrays copied the whole response so far on *every*
        // snapshot -- O(response bytes x snapshot count) of churn on the
        // MainActor while the UI renders (code review WP-21/22 round 4, #7).
        let prev = previous.utf8
        let snap = snapshot.utf8
        var prevIndex = prev.startIndex
        var snapIndex = snap.startIndex
        var sharedEnd = snap.startIndex
        while prevIndex < prev.endIndex, snapIndex < snap.endIndex,
              prev[prevIndex] == snap[snapIndex]
        {
            prev.formIndex(after: &prevIndex)
            snap.formIndex(after: &snapIndex)
            sharedEnd = snapIndex
        }
        // Snap back to a code-point boundary: a mismatch inside a multi-byte
        // sequence would otherwise start the delta on a continuation byte,
        // decoding to U+FFFD in the visible response.
        while sharedEnd > snap.startIndex, sharedEnd < snap.endIndex,
              snap[sharedEnd] & 0xC0 == 0x80
        {
            snap.formIndex(before: &sharedEnd)
        }
        return String(decoding: snap[sharedEnd...], as: UTF8.self)
    }

    /// The streaming plumbing, model-free: turns a sequence of *cumulative*
    /// snapshots into the incremental-delta stream the protocol promises, and
    /// cancels the pump when the consumer goes away. Generic over the
    /// snapshot sequence so the loop, the cancellation check, the error path
    /// and the `onTermination` hook are all unit-testable without a
    /// `LanguageModelSession` -- the package's pure/impure split, which
    /// previously stopped at `delta` and left this (where both round-1 bugs
    /// actually lived) covered by nothing (code review WP-21/22 round 4, #8).
    /// (Not constrained to `Sendable`: `ResponseStream` isn't, and none is
    /// needed -- this type is `@MainActor`, so the pump `Task` inherits that
    /// isolation and the sequence never crosses an actor boundary.)
    static func deltaStream<Snapshots: AsyncSequence>(
        snapshots: Snapshots
    ) -> AsyncThrowingStream<String, Error> where Snapshots.Element == String {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var previous = ""
                    for try await snapshot in snapshots {
                        try Task.checkCancellation()
                        let delta = Self.delta(previous: previous, snapshot: snapshot)
                        previous = snapshot
                        if !delta.isEmpty {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // A cancelled consumer (chat screen dismissed mid-turn) must not
            // leave the session busy: without this, the orphaned task drains
            // the stream to completion while `isResponding` stays true, and
            // the next turn on the reused conversation session throws
            // `concurrentRequests` for the rest of the conversation.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func stream(to prompt: String) -> AsyncThrowingStream<String, Error> {
        Self.deltaStream(snapshots: session.streamResponse(to: prompt).map(\.content))
    }

    /// The model's own counts: the transcript (instructions and tool
    /// definitions included) plus the prompt, against `contextSize` (the
    /// real window on 27; the SDK back-deploys 4,096 before it). A count
    /// that throws measures nothing rather than blocking the turn.
    /// The latest response entry's model, via the provider's reader.
    public func servedModelID() async -> String? {
        guard let modelIDOfResponse else { return nil }
        for entry in session.transcript.reversed() {
            if case .response(let response) = entry {
                return modelIDOfResponse(response)
            }
        }
        return nil
    }

    public func contextFit(adding prompt: String) async -> ContextFit? {
        guard let systemModel else { return nil }
        guard #available(iOS 26.4, macOS 26.4, visionOS 26.4, *) else { return nil }
        do {
            let transcriptTokens = try await systemModel.tokenCount(for: session.transcript)
            let promptTokens = try await systemModel.tokenCount(for: prompt)
            return ContextFit(tokens: transcriptTokens + promptTokens, contextSize: systemModel.contextSize)
        } catch {
            return nil
        }
    }
}
