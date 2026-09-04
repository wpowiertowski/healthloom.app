// CoachChatViewModel.swift
//
// WP-25 (implementation-plan.md): the Coach tab's conversation owner. One
// `CoachSessionFactory` conversation session per view-model lifetime
// (WP-22: the transcript is the memory), tools registered from
// `CoachTools.all(store:)` (WP-24), instructions from the effective prompt
// (user base + safety suffix, D10), per-turn context assembled + snapshotted
// for `.chat` (WP-20) with the snapshot ID linked on the assistant turn --
// the "What did the coach see?" expander reads it back via
// `ContextAssembler.decodeSnapshot`.
//
// Streaming contract: `session.stream(to:)` yields incremental deltas
// (WP-22); joining them reproduces the reply. Every exit path with a
// non-empty `draft` persists it (success, stop-button cancellation, or
// mid-stream error) so the stored transcript never contradicts what the
// user saw; only a cancellation before the first token leaves no turn.

import CoachKit
import CoreModel
import Foundation
import Observation
import OSLog
import SwiftData

@MainActor
@Observable
final class CoachChatViewModel {
    /// Everything the view model touches, so tests and the UI-test launch
    /// (scripted factory) inject without subclassing. Not `Sendable` (the
    /// store/manager/assembler are `@MainActor`-bound) -- it never leaves
    /// this view model's isolation.
    struct Dependencies {
        var container: ModelContainer
        var store: KnowledgeStore
        var prompts: PromptManager
        var assembler: ContextAssembler
        var factory: CoachSessionFactory
        var availability: any CoachAvailabilityChecking
    }

    /// Tool-set identity for the chat session (WP-22 `toolSetID` contract:
    /// a new tool set must bust the cached conversation session). Bump when
    /// the registered tools change -- nothing enforces this at compile
    /// time, so review the bump whenever `CoachTools.all(store:)` grows.
    static let chatToolSetID = "wp25-chat-v1"

    /// Newest turns kept in memory. The read is newest-first with a
    /// display-order reverse (WP-25 review #1): growth past the cap drops
    /// the oldest turns, never the newest, and sends append in hand (#10)
    /// with `onAppear` the only re-fetch.
    static let maxLoadedTurns = 500

    /// Minimum wall-clock gap between warm-up refreshes (review #9): tab
    /// switches rebuild this view and re-fire `onAppear`, and without a
    /// throttle every bounce would re-run the HealthKit + profile pipeline.
    static let warmupRefreshInterval: TimeInterval = 3600

    private static let logger = Logger(subsystem: "com.healthloom.app", category: "Coach")

    private let deps: Dependencies
    /// The view model's one `ModelContext` for its whole lifetime (round-2
    /// #6): every retained `ChatTurn` in `turns` stays within its
    /// originating context's scope, matching the codebase convention of
    /// never letting a live model object outlive a throwaway context.
    private let viewContext: ModelContext
    private var streamTask: Task<Void, Never>?
    private var warmupTask: Task<Void, Never>?
    private var lastWarmupRefreshAt: Date?

    private(set) var turns: [ChatTurn] = []
    private(set) var draft = ""
    private(set) var isResponding = false
    /// Optimistic until the async gate resolves on first appear. `send`
    /// guards on this cached value for instant feedback, then re-queries
    /// the live gate as the stream task's first step (round-2 #4) -- the
    /// window between appear and gate resolution, or a state change since,
    /// aborts with an error instead of streaming under a stale `.available`.
    private(set) var availability: CoachAvailability = .available
    var errorMessage: String?
    /// Unsent composer text. Owned here (not view `@State`, round-2 #15):
    /// `HomeView`'s switch unmounts the chat view on tab change, which
    /// would discard view-local text; the view model outlives it.
    var inputText = ""

    /// Resolved expander lists by snapshot ID, populated from row tasks
    /// (never during render -- review #5). Snapshots are immutable and
    /// prune-only (a pruned ID stays missing), so a never-invalidated cache
    /// is correct. Assign via a named `let`, never a bare `nil` literal --
    /// a literal deletes the key instead of caching the miss.
    private var contextCache: [UUID: [String]?] = [:]

    init(deps: Dependencies) {
        self.deps = deps
        self.viewContext = ModelContext(deps.container)
    }

    /// History load + availability check + warm-up (prewarm + throttled
    /// knowledge refresh so first-turn context isn't empty when HealthKit
    /// has data but no refresh has run yet). Refresh failure stays silent
    /// in the UI by design (a persistent failure surfaces at send time
    /// instead) but is logged, keeping the diagnostic trail `refresh()`'s
    /// throwing contract promises (review #8).
    func onAppear() {
        reloadTurns()
        // A repeated appear without an intervening disappear (documented
        // SwiftUI corner) must not orphan the previous warm-up (round-2
        // #9). The stream is deliberately NOT touched here: a tab switch
        // mid-reply leaves it running and this same view model reattaches
        // on return (round-2 #1).
        warmupTask?.cancel()
        warmupTask = Task {
            availability = await deps.availability.current()
            // A stream already in flight means a send already passed every
            // gate: skip best-effort warm-up (notably `prewarm()` on the
            // busy shared session) and let it finish undisturbed.
            guard availability == .available, !isResponding else { return }
            if KnowledgeRefreshThrottle.shouldFire(
                lastFiredAt: lastWarmupRefreshAt,
                now: .now,
                minimumInterval: Self.warmupRefreshInterval
            ) {
                do {
                    _ = try await deps.store.refresh()
                    lastWarmupRefreshAt = .now
                } catch {
                    Self.logger.warning(
                        "Coach warm-up refresh failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            // A prompt-fetch failure silences `prewarm()` exactly like a
            // refresh failure -- so it gets the same diagnostic trail
            // (round-2 #5), not a bare `try?`.
            if !Task.isCancelled {
                do {
                    chatSession(instructions: try deps.prompts.effectivePrompt()).prewarm()
                } catch {
                    Self.logger.warning(
                        "Coach warm-up prompt fetch failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
    }

    /// Tab switch: warm-up is best-effort and safe to drop, but an
    /// in-flight reply keeps streaming (round-2 #1) -- this view model (and
    /// its turns/draft/isResponding) outlives the unmounted view and the
    /// next `onAppear()` reattaches to it. Only the stop button cancels a
    /// stream.
    func onDisappear() {
        warmupTask?.cancel()
    }

    /// Sends one user turn. Returns `false` (and leaves the caller's input
    /// intact) when nothing was queued: empty text, already responding,
    /// unavailable, or the user-turn save failed (review #4).
    @discardableResult
    func send(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isResponding, availability == .available else { return false }
        errorMessage = nil
        let userTurn = ChatTurn(role: "user", content: trimmed)
        do {
            try persist(userTurn)
        } catch {
            errorMessage = "Couldn't save your message. Try again."
            return false
        }
        turns.append(userTurn)
        trimTurnsToCap()
        // A queued send supersedes best-effort warm-up: both drive the same
        // shared conversation session, and overlapping calls throw
        // `concurrentRequests` there (review #3). Streaming gets its own
        // handle so `stop()` never touches warm-up either.
        warmupTask?.cancel()
        isResponding = true
        draft = ""
        streamTask = Task {
            defer { isResponding = false }
            // Live re-check (round-2 #4): the sync guard above ran on the
            // cached value, which is optimistic before first appear. A
            // mismatch aborts before any model/streaming work, leaving the
            // already-queued user turn with an explanatory error.
            availability = await deps.availability.current()
            guard availability == .available else {
                errorMessage = "The coach isn't available right now. Try again later."
                return
            }
            var snapshotID: UUID?
            do {
                let instructions = try deps.prompts.effectivePrompt()
                let session = chatSession(instructions: instructions)
                let assembled = try deps.assembler.assemble(
                    for: .chat,
                    promptTokens: PromptManager.estimatedTokens(for: instructions)
                )
                snapshotID = assembled.snapshotID
                let prompt = Self.chatPrompt(message: trimmed, context: assembled.context)
                var streamError: Error?
                do {
                    for try await delta in session.stream(to: prompt) {
                        draft += delta
                    }
                } catch is CancellationError {
                    // Stop button / disappearance: fall through to the
                    // partial persist below (a consumer-side cancel can also
                    // end iteration without throwing -- either way, what
                    // matters is the `Task.isCancelled` check after).
                } catch {
                    streamError = error
                }
                if !draft.isEmpty {
                    do {
                        let reply = ChatTurn(
                            role: "assistant",
                            content: draft,
                            provider: "onDevice",
                            contextSnapshotID: snapshotID
                        )
                        try persist(reply)
                        turns.append(reply)
                        trimTurnsToCap()
                    } catch {
                        errorMessage = "Couldn't save the coach's reply. Try again."
                    }
                }
                if !Task.isCancelled, let streamError {
                    errorMessage = "The coach couldn't reply. \(streamError.localizedDescription)"
                }
            } catch {
                errorMessage = "The coach couldn't reply. \(error.localizedDescription)"
            }
            draft = ""
        }
        return true
    }

    /// Stop button: cancels the in-flight stream only (never warm-up); the
    /// cancellation path above persists any visible partial.
    func stop() {
        streamTask?.cancel()
    }

    /// Backing data for the per-message "What did the coach see?" expander.
    /// Called from row tasks on expansion, never during render (review #5):
    /// the row decides visibility from `contextSnapshotID != nil` alone.
    /// Returns `nil` for user turns, unlinked turns, pruned snapshots, and
    /// snapshots that no longer decode.
    func resolveSharedContext(for turn: ChatTurn) -> [String]? {
        guard turn.role == "assistant", let snapshotID = turn.contextSnapshotID else { return nil }
        if let cached = contextCache[snapshotID] {
            return cached
        }
        var descriptor = FetchDescriptor<ContextSnapshot>(
            predicate: #Predicate { $0.id == snapshotID }
        )
        descriptor.fetchLimit = 1
        let resolved: [String]? = (try? viewContext.fetch(descriptor).first)
            .flatMap { try? ContextAssembler.decodeSnapshot($0) }
            .map { $0.fields.map(\.displayText) }
        let cached: [String]? = resolved
        contextCache[snapshotID] = cached
        return cached
    }

    // MARK: - Private

    /// The single persistence path for turns (round-2 #14): insert +
    /// save on the view model's long-lived context (round-2 #6), so a
    /// future change to turn persistence lands once.
    private func persist(_ turn: ChatTurn) throws {
        viewContext.insert(turn)
        try viewContext.save()
    }

    private func chatSession(instructions: String) -> any CoachSession {
        deps.factory.makeSession(
            for: .conversation,
            instructions: instructions,
            tools: CoachTools.all(store: deps.store),
            toolSetID: Self.chatToolSetID
        )
    }

    private func trimTurnsToCap() {
        if turns.count > Self.maxLoadedTurns {
            turns.removeFirst(turns.count - Self.maxLoadedTurns)
        }
    }

    private func reloadTurns() {
        var descriptor = FetchDescriptor<ChatTurn>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = Self.maxLoadedTurns
        let rows = (try? viewContext.fetch(descriptor)) ?? []
        turns = Array(rows.reversed())
    }

    /// User message plus the assembled health context, framed as data --
    /// delegates to the shared `HealthContext.promptBlock` composer (WP-27
    /// review R1: one framing literal, owned by CoreModel, so a future
    /// injection-hardening lands in the chat, orchestrator, and insight
    /// prompts at once). Output is byte-identical to the inline version
    /// this replaces.
    static func chatPrompt(message: String, context: HealthContext) -> String {
        context.promptBlock(message: message)
    }
}
