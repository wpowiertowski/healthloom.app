// YouViewModel.swift
//
// WP-30 (implementation-plan.md): the You tab's view model over the
// persisted `KnowledgeProfile`. Reads go through a fresh `ModelContext`
// per call (the codebase convention — never a retained context for
// UI-driven reads); writes funnel through `KnowledgeStore`'s funneled
// paths (`setExcludedFromAI`, `pinCorrection`) so the exclusion cache and
// the persisted row agree immediately, then re-loads so the list renders
// the persisted truth, not an optimistic copy.
//
// Deletion scope note: "Forget" deletes rows (DerivedInsight reset, chat
// wipe) but never touches HealthKit or `LocalSample` source data —
// re-derivation stays possible, which is exactly what "forget applies
// forward" means here. The full-data wipe is WP-35's flow, out of scope.

import CoachKit
import CoreModel
import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class YouViewModel {
    struct Dependencies {
        var container: ModelContainer
        var store: KnowledgeStore
        /// WP-30 F1: the live conversation session outlives row deletion
        /// (the factory caches per-tier sessions keyed on instructions +
        /// tool set, neither of which a wipe changes), so the wipe path
        /// resets it explicitly — mirroring `PromptEditorViewModel`.
        var factory: CoachSessionFactory
    }

    private let deps: Dependencies

    /// The persisted profile's fields in stored order (empty when no
    /// profile exists yet — the view renders the empty state).
    var fields: [ProfileField] = []
    var updatedAt: Date?
    /// Write/delete failures with no sheet to host them.
    var errorMessage: String?
    /// One-line confirmation after a Forget action ("3 insights cleared").
    var notice: String?

    init(container: ModelContainer, store: KnowledgeStore, factory: CoachSessionFactory) {
        self.deps = Dependencies(container: container, store: store, factory: factory)
    }

    init(deps: Dependencies) {
        self.deps = deps
    }

    // MARK: - Reads

    /// Loads the newest persisted profile row (no re-derivation — on a
    /// fresh install there is simply nothing yet; `refresh()` runs via the
    /// coach warm-up path, never from this screen).
    func load() {
        errorMessage = nil
        // N1: a wipe/reset confirmation must not linger under later
        // content within one mount.
        notice = nil
        do {
            let context = ModelContext(deps.container)
            var descriptor = FetchDescriptor<KnowledgeProfile>(
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
            descriptor.fetchLimit = 1
            if let profile = try context.fetch(descriptor).first {
                fields = profile.sections
                updatedAt = profile.updatedAt
            } else {
                fields = []
                updatedAt = nil
            }
        } catch {
            errorMessage = "Couldn't load your profile: \(error.localizedDescription)"
        }
    }

    // MARK: - Profile (toggle + correct)

    /// Per-field AI-context toggle. Durable across `refresh()` cycles via
    /// the store's flag carry-over (WP-30 design — see `KnowledgeStore`).
    func setExcluded(_ excluded: Bool, forKey key: String) {
        errorMessage = nil
        do {
            try deps.store.setExcludedFromAI(excluded, forKey: key)
            load()
        } catch {
            errorMessage = "Couldn't update that field: \(error.localizedDescription)"
        }
    }

    /// Pins the user's corrected text for `key`. Beats re-derivation (the
    /// store preserves correction-sourced fields byte-for-byte); keeps the
    /// field's existing sharing posture and clinical flag.
    func pinCorrection(_ text: String, forKey key: String) {
        errorMessage = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Enter the corrected text first."
            return
        }
        do {
            try deps.store.pinCorrection(displayText: trimmed, forKey: key)
            load()
        } catch {
            errorMessage = "Couldn't save the correction: \(error.localizedDescription)"
        }
    }

    // MARK: - Forget

    /// Deletes every persisted derived insight (profile + chat untouched).
    /// Source data is kept, so future insights can re-derive.
    func resetInsights() {
        errorMessage = nil
        do {
            let context = ModelContext(deps.container)
            let rows = try context.fetch(FetchDescriptor<DerivedInsight>())
            for row in rows {
                context.delete(row)
            }
            try context.save()
            notice = rows.count == 1 ? "1 insight cleared." : "\(rows.count) insights cleared."
        } catch {
            errorMessage = "Couldn't reset insights: \(error.localizedDescription)"
        }
    }

    /// Deletes every chat turn and every stored context snapshot (profile +
    /// insights untouched) AND resets the live conversation session, so the
    /// coach cannot answer from a transcript the UI just forgot (WP-30 F1:
    /// row deletion alone leaves the factory's cached session intact). The
    /// next turn starts from an empty transcript and a fresh session.
    func wipeChatHistory() {
        errorMessage = nil
        do {
            let context = ModelContext(deps.container)
            let turns = try context.fetch(FetchDescriptor<ChatTurn>())
            for turn in turns {
                context.delete(turn)
            }
            let snapshots = try context.fetch(FetchDescriptor<ContextSnapshot>())
            for snapshot in snapshots {
                context.delete(snapshot)
            }
            try context.save()
            deps.factory.resetConversation()
            notice = turns.count == 1 ? "1 message cleared." : "\(turns.count) messages cleared."
        } catch {
            errorMessage = "Couldn't erase chat history: \(error.localizedDescription)"
        }
    }
}
