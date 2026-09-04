// PromptEditorViewModel.swift
//
// WP-26 (implementation-plan.md): the coach prompt editor's state. The base
// prompt is user-editable; the safety suffix is always appended at use time
// (D10) and never editable here. Live values (`estimatedTokens`,
// `effectivePreview`, `diffVsDefault`) are computed from `baseText`, never
// stored -- they cannot go stale behind the editor. Writes go through
// `PromptManager` (validated, append-only history); `history` reloads after
// every write so the version list never shows a pre-write snapshot.

import CoachKit
import Foundation
import Observation

@MainActor
@Observable
final class PromptEditorViewModel {
    struct Dependencies {
        var manager: PromptManager
        /// The chat session factory. Every successful write busts its
        /// cached conversation session (round-2 #1): the cache keys on
        /// instructions, so without an explicit `resetConversation()` the
        /// next turn would run on a fresh session with no replayed
        /// transcript -- a coach that silently forgot the conversation.
        var factory: CoachSessionFactory
    }

    /// In-memory history cap, mirroring `PromptManager.history(limit:)`
    ///'s default page (round-2 #18).
    private static let maxHistoryRows = 100

    /// One diff row for the diff-vs-default view (WP-21's `defaultAndCurrent`
    /// stores both strings; the UI diffs here, in WP-26).
    enum DiffLine: Equatable, Sendable {
        case common(String)
        case added(String)
        case removed(String)

        var isCommon: Bool {
            if case .common = self { return true }
            return false
        }
    }

    private let deps: Dependencies

    /// The editor's working copy. Initialized from `currentBase()` by
    /// `load()`; every live value below derives from it.
    var baseText = ""
    /// The last loaded/saved text. `hasUnsavedChanges` derives from the
    /// comparison -- never stored separately, so it cannot go stale.
    private var savedBase = ""
    /// The shipped baseline the diff compares against.
    private(set) var defaultBase = ""
    /// Newest-first user history (edits and resets).
    private(set) var history: [PromptVersionSnapshot] = []
    /// Whether the working copy differs from what's in effect.
    var hasUnsavedChanges: Bool { baseText != savedBase }
    var errorMessage: String?
    var notice: String?

    init(deps: Dependencies) {
        self.deps = deps
    }

    /// Live token estimate over the working copy (WP-26 step: the same
    /// canonical estimator the context budget uses, not a second rule).
    /// Measured over the trimmed text (round-2 #6): validation counts
    /// `trimmed.utf8`, so the counter and the save-time check must measure
    /// the same string near the byte limit.
    var estimatedTokens: Int {
        PromptManager.estimatedTokens(for: baseText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The exact string the model receives for the working copy: base +
    /// `"\n\n"` + safety suffix (the same pure assembly the session uses).
    var effectivePreview: String {
        PromptManager.effectivePrompt(base: baseText)
    }

    /// The preview's base block, derived FROM `effectivePreview` (round-2
    /// #11) rather than re-stating the composition: the view renders
    /// `previewBase` + the locked suffix, so an assembly change (separator,
    /// ordering) flows into the on-screen preview instead of silently
    /// diverging from it.
    var previewBase: String {
        let full = effectivePreview
        let suffix = "\n\n" + SafetyLayer.text
        // True by construction (`effectivePreview` IS base + suffix), so no
        // fallback branch: if the assembly ever changes without updating
        // this splitter, fail visibly in Debug rather than silently
        // rendering the wrong base. In Release `dropLast` clamps (no trap);
        // a mismatch would show an empty base block above the suffix --
        // visibly broken, never silently suffix-less (round-2 #17).
        assert(full.hasSuffix(suffix), "preview splitter out of sync with effectivePrompt assembly")
        return String(full.dropLast(suffix.count))
    }

    /// Line diff of the working copy against the shipped default.
    var diffVsDefault: [DiffLine] {
        Self.diffLines(default: defaultBase, current: baseText)
    }

    /// Whether the working copy matches the shipped default line-for-line.
    var matchesDefault: Bool {
        diffVsDefault.allSatisfy(\.isCommon)
    }

    func load() {
        do {
            // Both fetches land in locals first (round-2 #7): if `history()`
            // throws after `defaultAndCurrent()` succeeded, the UI must keep
            // its previous coherent state, not a half-refreshed mix.
            let (defaultText, current) = try deps.manager.defaultAndCurrent()
            let freshHistory = try deps.manager.history()
            defaultBase = defaultText
            baseText = current
            savedBase = current
            history = freshHistory
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load the prompt. \(error.localizedDescription)"
        }
    }

    /// Saves the working copy as a new history row. Returns `false` when
    /// nothing was written (validation failure surfaces in `errorMessage`).
    /// A whitespace-only difference from what's saved is a no-op (round-2
    /// #15): trimming would reproduce `savedBase` byte-for-byte, so no row
    /// is appended and the editor simply normalizes to the saved text.
    @discardableResult
    func save() -> Bool {
        let trimmed = baseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != savedBase else {
            baseText = savedBase
            errorMessage = nil
            notice = "Already up to date."
            return true
        }
        return performWrite(successNotice: "Saved.") {
            try deps.manager.save(base: baseText)
        }
    }

    /// Resets the working copy and the effect to the shipped default.
    /// Appends a row only when the effect actually changes (round-2 #15):
    /// with the effect already at default, Reset just drops the unsaved
    /// draft without writing a duplicate-effect row.
    func resetToDefault() {
        errorMessage = nil
        notice = nil
        guard canReset else {
            notice = "Already at the shipped default."
            return
        }
        guard savedBase != defaultBase else {
            baseText = savedBase
            notice = "Discarded unsaved changes."
            return
        }
        performWrite(successNotice: "Reset to the shipped default.") {
            try deps.manager.resetToDefault()
        }
    }

    /// Restores a history entry by saving its body as a new row (append-only:
    /// restore never rewrites, so the audit trail stays complete).
    /// Restoring the already-active version is a no-op (round-2 #15): no
    /// duplicate row, and -- critically -- no session reset for an
    /// unchanged prompt.
    func restore(_ snapshot: PromptVersionSnapshot) {
        guard snapshot.body != savedBase else {
            errorMessage = nil
            notice = "Already using this version."
            return
        }
        performWrite(successNotice: "Restored the selected version.") {
            try deps.manager.save(base: snapshot.body)
        }
    }

    /// Whether resetting would change anything (round-2 #5): enabled when
    /// the working copy differs from the default OR carries unsaved edits.
    /// A fresh install (or a just-completed reset) disables Reset, so it
    /// can never append a history row that changes nothing -- which would
    /// break `history().isEmpty` meaning "never customized".
    ///
    /// String comparison, not `matchesDefault` (round-2 #16): line-diff
    /// cleanliness and string equality coincide exactly (the split is
    /// injective), so routing this through the diff would rebuild the table
    /// a second time per render for nothing.
    var canReset: Bool {
        baseText != defaultBase || hasUnsavedChanges
    }

    /// The single write path behind save/reset/restore (round-2 #9): clears
    /// both message slots up front (a stale notice can never sit next to a
    /// new error -- #2), applies the returned snapshot in memory instead of
    /// re-fetching everything (#13), and busts the cached conversation
    /// session so the next turn runs under the new prompt (#1). The bust
    /// only ever fires here for genuine changes -- no-op writes return
    /// above -- where the factory's own instructions-equality check would
    /// rotate sessions anyway; the explicit call keeps that invalidation
    /// visible at the edit site instead of relying on it implicitly.
    ///
    /// The editor's visible text becomes exactly the persisted (trimmed)
    /// body -- `PromptManager` trims by contract, and the UI states that
    /// (see the editor footnote) rather than letting `load()` rewrite it
    /// as a surprise (#4).
    @discardableResult
    private func performWrite(
        successNotice: String,
        _ operation: () throws -> PromptVersionSnapshot
    ) -> Bool {
        errorMessage = nil
        notice = nil
        do {
            let snapshot = try operation()
            baseText = snapshot.body
            savedBase = snapshot.body
            // Same bound the fetch honors (round-2 #18):
            // `PromptManager.history()` pages `limit` rows (default 100) so
            // the version list can't re-read unbounded bodies; the
            // in-memory prepend keeps that contract within a session instead
            // of growing past it until the next load().
            history = Array(([snapshot] + history).prefix(Self.maxHistoryRows))
            deps.factory.resetConversation()
            notice = successNotice
            return true
        } catch let validation as PromptManager.ValidationError {
            // `ValidationError` carries no user-facing copy of its own, so
            // the editor maps its cases instead of showing NSError
            // boilerplate.
            errorMessage = switch validation {
            case .emptyBase: "The prompt can't be empty."
            case .baseTooLong(let count, let limit):
                "The prompt is too long (\(count) of \(limit) bytes max)."
            }
            return false
        } catch {
            errorMessage = "Couldn't save. \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Line diff

    /// Line-based diff over the stdlib's `difference(from:)` (round-2
    /// #8): no hand-rolled DP table -- the minimal edit script comes from
    /// the well-tested primitive, and this function only walks the two
    /// line arrays once, emitting removals before additions at each
    /// position (unified-diff convention). Pure/static, unit-testable
    /// without a container.
    static func diffLines(default defaultText: String, current: String) -> [DiffLine] {
        let old = defaultText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let new = current.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var removedOffsets = Set<Int>()
        var insertedByOffset: [Int: String] = [:]
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _):
                removedOffsets.insert(offset)
            case .insert(let offset, let element, _):
                insertedByOffset[offset] = element
            }
        }
        var result: [DiffLine] = []
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if removedOffsets.contains(i), let element = insertedByOffset[j] {
                result.append(.removed(old[i]))
                result.append(.added(element))
                i += 1
                j += 1
            } else if removedOffsets.contains(i) {
                result.append(.removed(old[i]))
                i += 1
            } else if let element = insertedByOffset[j] {
                result.append(.added(element))
                j += 1
            } else {
                result.append(.common(old[i]))
                i += 1
                j += 1
            }
        }
        return result
    }
}
