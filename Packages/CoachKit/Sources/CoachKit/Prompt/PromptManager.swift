// PromptManager.swift
//
// WP-21 (implementation-plan.md) / architecture.md D10: effective system prompt
// = user-editable base + immutable `SafetyLayer` suffix. The suffix is appended
// at use time, never persisted -- `PromptVersion` rows (CoreModel) hold only the
// base, so edits and resets can never drop or reorder the suffix.
//
// `@MainActor`: matches CoachKit's package-wide default isolation and the
// `KnowledgeStore`/`ContextAssembler` precedent -- `ModelContext` is used from a
// single actor context, and nothing here is hot enough to need off-main work.

import CoreModel
import Foundation
import SwiftData

/// Value snapshot of one `PromptVersion` row. `PromptManager` returns these --
/// never live SwiftData objects: every method builds its `ModelContext`
/// locally, so a returned model object would fault against a deallocated
/// context as soon as the caller touches `.body` (crashing WP-26's version
/// list). Snapshots carry everything the editor needs, including the `id` for
/// restore-by-identifier.
public struct PromptVersionSnapshot: Sendable, Equatable, Identifiable {
    public var id: PersistentIdentifier
    public var body: String
    public var createdAt: Date
    public var isDefault: Bool

    public init(id: PersistentIdentifier, body: String, createdAt: Date, isDefault: Bool) {
        self.id = id
        self.body = body
        self.createdAt = createdAt
        self.isDefault = isDefault
    }
}

@MainActor
public final class PromptManager {
    /// HealthLoom's shipped default base prompt. Non-empty by contract (WP-21
    /// test). The editable half of the effective prompt -- the other half is
    /// always `SafetyLayer.text`, appended at use time.
    public static let defaultPrompt = """
        You are HealthLoom, a supportive health and fitness coach. You help the \
        user understand their activity, sleep, and recovery trends and suggest \
        small, sustainable next steps. Be encouraging, specific, and honest about \
        uncertainty. Personalize to the health context you are given and keep \
        answers concise unless the user asks for detail.
        """

    /// Pure prompt assembly (WP-21 step 2): `userBase + "\n\n" + SafetyLayer.text`.
    /// The suffix is always appended last, unconditionally -- even when the base
    /// already contains the suffix text (a user paste can never satisfy the safety
    /// requirement by itself; the appended copy is what guarantees ordering).
    /// Static and SwiftData-free so the ordering guarantee is unit-testable without
    /// a container -- the same pure/impure split as WP-19/WP-20.
    public static func effectivePrompt(base userBase: String) -> String {
        userBase + "\n\n" + SafetyLayer.text
    }

    /// Heuristic token estimate for the Prompt Editor's live counter (WP-26)
    /// and the context budget's prompt reserve (`ContextAssembler.assemble`
    /// `promptTokens`): UTF-8 bytes / 4, rounded up -- the same rule WP-20's
    /// `ContextAssembler.estimatedTokens` uses over the JSON payload, so the
    /// editor counter and the budget arithmetic are one canonical estimator,
    /// not two disagreeing ones (`String.count` grapheme clusters would
    /// under-report emoji/CJK ~3x). Informational only.
    public static func estimatedTokens(for prompt: String) -> Int {
        bytesToTokens(prompt.utf8.count)
    }

    /// Abuse/length guard for the only write path (WP-26's editor also goes
    /// through `save`). Counted in UTF-8 bytes with the same estimator the
    /// budget uses (`estimatedTokens(for:)`), not grapheme clusters: 10k
    /// bytes is at most ~2.5k tokens for any script, leaving headroom in the
    /// 4K on-device window for the health context. A character count would
    /// pass 10k CJK/emoji characters (30-40k bytes, the whole window and
    /// more). Working constant; surfaced to the user by the editor's live
    /// estimate (WP-26).
    public static let maxBaseBytes = 10_000

    /// Validation failures from `save(base:)`.
    public enum ValidationError: Error, Equatable, Sendable {
        case emptyBase
        case baseTooLong(count: Int, limit: Int)
    }

    private let modelContainer: ModelContainer

    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    static func snapshot(of version: PromptVersion) -> PromptVersionSnapshot {
        PromptVersionSnapshot(
            id: version.persistentModelID,
            body: version.body,
            createdAt: version.createdAt,
            isDefault: version.isDefault
        )
    }

    /// The shipped-default base: the newest `isDefault` row when one exists
    /// (seeded history survives app updates), otherwise the compiled-in
    /// `defaultPrompt` constant. Single source of truth for "diff vs default"
    /// (WP-26) -- callers never hardcode the baseline twice. Bounded read:
    /// sorted fetch with `fetchLimit = 1` (the `KnowledgeStore.fetchProfile`
    /// idiom), never the whole table.
    public func defaultBase() throws -> String {
        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<PromptVersion>(
            predicate: #Predicate { $0.isDefault },
            sortBy: [
                SortDescriptor(\.createdAt, order: .reverse),
                SortDescriptor(\.body, order: .forward),
            ]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.body ?? Self.defaultPrompt
    }

    /// User-visible edit history, newest first: every non-default row (edits
    /// and reset-to-default appends). Seeded `isDefault` baselines are *not*
    /// history -- "the user never edited" reads as empty even on installs
    /// carrying a seeded default row, so `history().isEmpty` reliably means
    /// "never customized" and WP-26 never offers to "restore" a version the
    /// user didn't create.
    /// Bounded newest-first page of the edit history (the descriptor idiom
    /// used throughout this file), so opening WP-26's version list can't
    /// re-read unbounded edit bodies. Grows append-only via `save` with no
    /// deletion path yet -- WP-26 owns history pruning if the list ever
    /// needs it.
    ///
    /// A non-positive `limit` returns no rows. `FetchDescriptor.fetchLimit`
    /// treats 0 (and negatives) as *unbounded*, so a caller paginating with a
    /// computed remaining-count that reaches 0 -- or passing 0 to mean "none"
    /// -- would otherwise read every stored body instead of nothing (code
    /// review WP-21/22 round 4, #2).
    public func history(limit: Int = 100) throws -> [PromptVersionSnapshot] {
        guard limit > 0 else { return [] }
        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<PromptVersion>(
            predicate: #Predicate { !$0.isDefault },
            sortBy: [
                SortDescriptor(\.createdAt, order: .reverse),
                SortDescriptor(\.body, order: .forward),
            ]
        )
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor).map(Self.snapshot(of:))
    }

    /// The base currently in effect: the newest *user* row (edits and resets),
    /// or -- only when the user never customized anything -- the newest seeded
    /// default, or the compiled-in default. User rows win over seeded defaults
    /// regardless of timestamp: an app update seeding a newer shipped default
    /// must move the diff baseline, never silently replace the user's
    /// customization. Never returns the safety suffix -- that is appended
    /// only by `effectivePrompt()`.
    public func currentBase() throws -> String {
        let context = ModelContext(modelContainer)
        var userDescriptor = FetchDescriptor<PromptVersion>(
            predicate: #Predicate { !$0.isDefault },
            sortBy: [
                SortDescriptor(\.createdAt, order: .reverse),
                SortDescriptor(\.body, order: .forward),
            ]
        )
        userDescriptor.fetchLimit = 1
        if let user = try context.fetch(userDescriptor).first {
            return user.body
        }
        var defaultDescriptor = FetchDescriptor<PromptVersion>(
            predicate: #Predicate { $0.isDefault },
            sortBy: [
                SortDescriptor(\.createdAt, order: .reverse),
                SortDescriptor(\.body, order: .forward),
            ]
        )
        defaultDescriptor.fetchLimit = 1
        return try context.fetch(defaultDescriptor).first?.body ?? Self.defaultPrompt
    }

    /// The exact string handed to the model for the current base (D10).
    public func effectivePrompt() throws -> String {
        Self.effectivePrompt(base: try currentBase())
    }

    /// Data for the WP-26 editor's diff-vs-default view: both strings, letting
    /// the UI diff without re-querying.
    public func defaultAndCurrent() throws -> (default: String, current: String) {
        (try defaultBase(), try currentBase())
    }

    /// Saves a user edit as a new history row (WP-21 step 3). Appends -- never
    /// rewrites -- so the version list (WP-26 restore) is complete. Returns a
    /// value snapshot of the inserted row. The timestamp is monotonicized
    /// against the newest stored row (1 ms bump on ties) so rapid successive
    /// writes -- same-instant save + reset, seeded batches, migrations -- can
    /// never leave "the prompt currently in effect" ambiguous.
    @discardableResult
    public func save(base: String, now: Date = .now) throws -> PromptVersionSnapshot {
        // Validated and stored as the same string: the trimmed base. A
        // whitespace-padded base would otherwise pass the guards and persist
        // kilobytes of padding into every subsequent effective prompt.
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.emptyBase }
        guard trimmed.utf8.count <= Self.maxBaseBytes else {
            throw ValidationError.baseTooLong(count: trimmed.utf8.count, limit: Self.maxBaseBytes)
        }
        let base = trimmed
        let context = ModelContext(modelContainer)
        // Bounded monotonicity probe: newest single row, not the table.
        // Scoped to non-default rows -- the same set whose ordering this
        // stamp protects (`currentBase()`/`history()` both read only these).
        // Including seeded `isDefault` rows would let a future-dated shipped
        // default (the `userEditWinsOverNewerSeed` scenario) stamp every
        // later user edit past it, permanently dating the version list in the
        // future (code review WP-21/22 round 4, #4).
        var probe = FetchDescriptor<PromptVersion>(
            predicate: #Predicate { !$0.isDefault },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        probe.fetchLimit = 1
        let latest = try context.fetch(probe).first?.createdAt
        let stamp = if let latest, now <= latest {
            latest.addingTimeInterval(0.001)
        } else {
            now
        }
        let version = PromptVersion(body: base, createdAt: stamp, isDefault: false)
        context.insert(version)
        try context.save()
        return Self.snapshot(of: version)
    }

    /// Reset-to-default (WP-21 step 3): appends a row carrying the default text
    /// rather than deleting history, so "reset" itself stays in the audit trail
    /// and WP-26 restore can still reach pre-reset edits.
    @discardableResult
    public func resetToDefault(now: Date = .now) throws -> PromptVersionSnapshot {
        try save(base: try defaultBase(), now: now)
    }
}
