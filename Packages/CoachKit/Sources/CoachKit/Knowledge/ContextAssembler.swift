// ContextAssembler.swift
//
// WP-20 (implementation-plan.md) / architecture.md D7: builds the exact
// `HealthContext` handed to a coach provider for one turn, exclusively from
// the persisted `KnowledgeProfile` -- never from HealthKit or `LocalSample`
// directly (architecture.md §2: CoachKit reads health data only through
// `KnowledgeStore`, and `KnowledgeStore`'s derived fields are the only
// externally-visible state).
//
// `@MainActor`: matches CoachKit's package-wide default isolation and
// `KnowledgeStore`'s precedent -- `ModelContext` is naturally used from a
// single actor context, and nothing here is hot enough to need off-main work.

import CoreModel
import Foundation
import SwiftData

@MainActor
public final class ContextAssembler {
    /// What the assembled context is for. Both purposes filter, trim, and
    /// snapshot identically today -- the parameter exists so WP-23's
    /// `ReadinessEngine` (morning insight) and WP-25's Chat UI can diverge
    /// later without reshaping call sites.
    public enum Purpose: String, Sendable {
        case chat
        case dailyInsight
    }

    /// Working token budgets (WP-20 step 2). The on-device (~4K) and PCC
    /// (32K) figures come from architecture.md D9/D14; the cloud figure is
    /// deliberately round -- WP-27's `ModelCatalog` replaces these constants
    /// with per-model queries where the framework exposes them. This WP only
    /// trims to the budget it is given and reports overflow; the escalation
    /// *offer* is WP-27's decision (D14.2), never an auto-switch here.
    public static let onDeviceTokenBudget = 4_000
    public static let privateCloudComputeTokenBudget = 32_000
    public static let largeCloudTokenBudget = 100_000

    /// The assembled payload plus its trace metadata (WP-20 step 3). The
    /// `snapshotID` is what `ChatTurn.contextSnapshotID` links back to for
    /// the "What did the coach see?" trace UI (architecture.md D7, WP-30);
    /// `estimatedTokens`/`didTrim` are the overflow report WP-27's
    /// escalation offer reads (D14.2).
    public struct AssembledContext: Sendable {
        public var context: HealthContext
        public var snapshotID: UUID
        public var estimatedTokens: Int
        public var didTrim: Bool

        public init(context: HealthContext, snapshotID: UUID, estimatedTokens: Int, didTrim: Bool) {
            self.context = context
            self.snapshotID = snapshotID
            self.estimatedTokens = estimatedTokens
            self.didTrim = didTrim
        }
    }

    /// The pure field-selection half of `assemble(for:...)`, kept static and
    /// SwiftData-free so trimming order is unit-testable without a container
    /// -- the same pure/impure split as `KnowledgeDerivation` vs
    /// `KnowledgeStore` (WP-19) and SyncKit's `TypeMapper` vs HealthKit writer.
    public struct FieldSelection: Sendable {
        public var kept: [ProfileField]
        public var estimatedTokens: Int
        public var didTrim: Bool

        public init(kept: [ProfileField], estimatedTokens: Int, didTrim: Bool) {
            self.kept = kept
            self.estimatedTokens = estimatedTokens
            self.didTrim = didTrim
        }
    }

    private let modelContainer: ModelContainer

    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// Token-budget estimate (WP-20 step 2): the JSON-encoded byte size of
    /// the fields divided by 4, rounded up. Measured over the actual
    /// `JSONEncoder` output -- not over `displayText` alone -- so the
    /// per-field framing the model really receives (`asOf`, `source`, the
    /// `excludedFromAI`/`isClinical` flags, and all JSON punctuation) is
    /// counted too (code review WP-20 round 1, #2). UTF-8 multibyte sequences
    /// (the profile's `·`/`—` separators) inflate the byte count, which errs
    /// conservative -- the safe direction for a budget. Always computed over
    /// the whole array at once: summing independently rounded per-field costs
    /// would disagree with the batched value (`ceil(a/4)+ceil(b/4)` is not
    /// `ceil((a+b)/4)`), giving two "canonical" numbers for one field set
    /// (code review #3) -- `selectFields` below reuses this exact function
    /// for every fit check, so there is exactly one formula. Falls back to a
    /// plain character heuristic only if encoding itself throws (never
    /// observed for these `Codable` value types; keeps this non-throwing).
    public static func estimatedTokens(for fields: [ProfileField]) -> Int {
        if fields.isEmpty { return 0 }
        if let json = try? JSONEncoder().encode(fields) {
            return (json.count + 3) / 4
        }
        let chars = fields.reduce(0) { $0 + $1.key.count + $1.displayText.count + $1.source.count }
        return (chars + 3) / 4
    }

    /// The fixed per-context framing around any field set
    /// (`localeIdentifier` / `unitSystem` / `today` plus JSON punctuation),
    /// measured the same way (code review #2). `assemble(for:...)` reserves
    /// this out of the budget before selecting fields, so the reported total
    /// covers the whole payload handed to `JSONEncoder`, not just the fields.
    public static func estimatedShellTokens(
        localeIdentifier: String,
        unitSystem: UnitSystem,
        today: Date
    ) -> Int {
        let shell = HealthContext(
            fields: [],
            localeIdentifier: localeIdentifier,
            unitSystem: unitSystem,
            today: today
        )
        if let json = try? JSONEncoder().encode(shell) {
            return (json.count + 3) / 4
        }
        return 0
    }

    /// Priority rank, low number = keep first (WP-20 step 2: "vitals > sleep
    /// > activity > history"). Matches on `KnowledgeDerivation`'s key-prefix
    /// constants -- not local literals -- so a key rename breaks at compile
    /// time instead of silently demoting the field to rank 3 (code review
    /// #6). Correction-pinned fields (WP-19) keep their original key, so they
    /// rank exactly where the field they override would.
    public static func priorityRank(for key: String) -> Int {
        if key.hasPrefix(KnowledgeDerivation.vitalsKeyPrefix) { return 0 }
        if key.hasPrefix(KnowledgeDerivation.sleepKeyPrefix) { return 1 }
        if key.hasPrefix(KnowledgeDerivation.stepsKeyPrefix) || key.hasPrefix(KnowledgeDerivation.activityKeyPrefix) {
            return 2
        }
        return 3
    }

    /// Drops the lowest-priority eligible fields until the remainder fits
    /// `tokenBudget`, preserving profile order within a rank (explicit index
    /// tie-break, not reliance on sort stability). Strict prefix semantics:
    /// the scan stops at the first field that doesn't fit, so a smaller
    /// lower-priority field can never jump the queue ahead of a larger
    /// higher-priority one (code review #1 -- the previous skip-and-continue
    /// loop allowed exactly that inversion, and its keep-one fallback never
    /// triggered because `kept` was already non-empty). Guarantees at least
    /// the single highest-priority field whenever anything is eligible: a
    /// zero-field context from a non-empty profile would be useless. Every
    /// fit check reuses the batched `estimatedTokens(for:)` over the whole
    /// candidate set, so the running total and the reported total are one
    /// formula, not two disagreeing roundings (#3).
    public static func selectFields(from eligible: [ProfileField], tokenBudget: Int) -> FieldSelection {
        let ordered = eligible.enumerated()
            .sorted {
                let leftRank = priorityRank(for: $0.element.key)
                let rightRank = priorityRank(for: $1.element.key)
                if leftRank != rightRank { return leftRank < rightRank }
                return $0.offset < $1.offset
            }
            .map(\.element)
        var kept: [ProfileField] = []
        for field in ordered {
            let candidate = kept + [field]
            if estimatedTokens(for: candidate) <= tokenBudget {
                kept = candidate
            } else {
                break
            }
        }
        if kept.isEmpty, let first = ordered.first {
            kept = [first]
        }
        return FieldSelection(kept: kept, estimatedTokens: estimatedTokens(for: kept), didTrim: kept.count < eligible.count)
    }

    /// Locale-derived `UnitSystem` default: US locales get imperial, everything
    /// else metric. Explicitly overridable per `assemble(for:...)` call; kept
    /// static so the default is testable without a container.
    public static func defaultUnitSystem(for locale: Locale) -> UnitSystem {
        locale.measurementSystem == .us ? .imperial : .metric
    }

    /// Assembles the context for one coach turn or insight (WP-20 steps 1-3):
    /// loads the single `KnowledgeProfile` row, drops every `excludedFromAI`
    /// field, trims to `tokenBudget` by priority rank, and persists the exact
    /// `HealthContext` handed out as a `ContextSnapshot` (same-`now`
    /// `createdAt`, so the trace row and the context's `today` agree).
    ///
    /// **Filtering (D7/D8):** the only exclusion rule is `excludedFromAI`.
    /// Clinical fields default to excluded at creation (`ProfileField`'s
    /// `init` maps nil to `isClinical`), so they stay out unless the user
    /// explicitly opted that field back in -- no second rule to drift out of
    /// sync with WP-19/WP-30's toggles.
    ///
    /// **Read-only toward the profile:** a missing profile yields an empty
    /// (but still snapshotted -- "the coach saw nothing" is itself trace
    /// data) context; this method never inserts a profile row. The single-row
    /// read is shared with `KnowledgeStore` (`fetchProfile(from:)`,
    /// newest-first), so both call sites resolve a (shouldn't-happen)
    /// duplicate row identically (code review #4). Failures from the fetch,
    /// the JSON encode, or the snapshot save propagate instead of being
    /// swallowed, matching `KnowledgeStore.refresh()`'s posture.
    ///
    /// **Staleness vs. in-flight refresh (code review #5):** `KnowledgeStore
    /// .refresh()` serializes refreshes against each other but not against
    /// this read, so an assembly can snapshot the pre-refresh profile while
    /// a refresh's HealthKit reads are still suspended. That is accepted, not
    /// overlooked: the store's posture is graceful degradation (an
    /// unrequested or denied read looks like no data either way), and the
    /// snapshot's job is to record what the coach *actually saw* --
    /// staleness included -- with every field's `asOf` bounding it. Sharing
    /// the refresh lock here would couple turn latency to HealthKit latency;
    /// revisit if the trace UI (WP-30) needs a "refresh was running" signal.
    public func assemble(
        for purpose: Purpose,
        now: Date = .now,
        locale: Locale = .current,
        unitSystem: UnitSystem? = nil,
        tokenBudget: Int = ContextAssembler.onDeviceTokenBudget
    ) throws -> AssembledContext {
        _ = purpose
        let resolvedUnitSystem = unitSystem ?? Self.defaultUnitSystem(for: locale)
        let context = ModelContext(modelContainer)
        let sections = try KnowledgeStore.fetchProfile(from: context)?.sections ?? []
        let eligible = sections.filter { !$0.excludedFromAI }
        // Reserve the fixed shell before selecting fields, so the reported
        // total covers the whole payload handed to `JSONEncoder` (#2). Off
        // by two bytes (`[]` in the shell vs `[...]` in the full encoding) --
        // negligible and conservative.
        let shell = Self.estimatedShellTokens(
            localeIdentifier: locale.identifier,
            unitSystem: resolvedUnitSystem,
            today: now
        )
        let selection = Self.selectFields(from: eligible, tokenBudget: max(tokenBudget - shell, 0))
        let healthContext = HealthContext(
            fields: selection.kept,
            localeIdentifier: locale.identifier,
            unitSystem: resolvedUnitSystem,
            today: now
        )
        let json = try JSONEncoder().encode(healthContext)
        let snapshot = ContextSnapshot(json: json, createdAt: now)
        context.insert(snapshot)
        try context.save()
        // Authoritative overflow signal (code review #1): trimming *or* the
        // surviving fields still exceeding the budget -- e.g. the keep-one
        // fallback holding a single over-budget top field, where
        // `kept.count < eligible.count` alone would report "nothing trimmed".
        let totalTokens = shell + selection.estimatedTokens
        let didTrim = selection.didTrim || (!eligible.isEmpty && totalTokens > tokenBudget)
        return AssembledContext(
            context: healthContext,
            snapshotID: snapshot.id,
            estimatedTokens: totalTokens,
            didTrim: didTrim
        )
    }
}
