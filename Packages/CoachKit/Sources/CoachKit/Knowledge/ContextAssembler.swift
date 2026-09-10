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

    /// Working cap on stored `ContextSnapshot` rows (see `assemble`). Every
    /// assembly persists a full JSON copy of the health context, and turns
    /// that fail, cancel, or never run leave orphans no `ChatTurn` will ever
    /// link -- without a cap the store grows ~15k rows/year of its most
    /// sensitive data. WP-30 (trace UI + retention) owns the real policy;
    /// until then rows evicted past the window have their `ChatTurn` links
    /// nulled first, so the bound holds for linked rows too and no ID ever
    /// dangles (see `pruneSnapshots`). Exposed as an `assemble` parameter
    /// for testability.
    public static let maxStoredSnapshots = 200

    /// Upper bound on rows evicted per `assemble` call. Steady state evicts
    /// at most one, so this only caps the transition cases (a pre-cap store,
    /// or a lowered `maxStoredSnapshots`), keeping the coach's turn path off
    /// an unbounded load of health-context blobs; the backlog drains over
    /// successive assemblies (code review WP-21/22 round 4, #6).
    static let maxSnapshotEvictionsPerAssembly = 64

    /// The assembled payload plus its trace metadata (WP-20 step 3). The
    /// `snapshotID` is what `ChatTurn.contextSnapshotID` links back to for
    /// the "What did the coach see?" trace UI (architecture.md D7, WP-30)
    /// (`nil` renders as "context expired" after retention eviction);
    /// `estimatedTokens`/`didTrim` are the overflow report WP-27's
    /// escalation offer reads (D14.2), and `promptOverBudget` distinguishes
    /// the remedy: prompt too long (shorten it) vs fields dropped (escalate
    /// may recover them).
    public struct AssembledContext: Sendable {
        public var context: HealthContext
        public var snapshotID: UUID
        public var estimatedTokens: Int
        public var didTrim: Bool
        /// True when prompt + shell alone exceed the budget, so no field
        /// selection could fit. Pairs with `didTrim`: overflow with
        /// `promptOverBudget == false` means fields were dropped to fit (or
        /// the full request still overflows with fields present) --
        /// escalation may help; overflow with it `true` means the prompt
        /// itself must shrink.
        public var promptOverBudget: Bool

        public init(context: HealthContext, snapshotID: UUID, estimatedTokens: Int, didTrim: Bool, promptOverBudget: Bool = false) {
            self.context = context
            self.snapshotID = snapshotID
            self.estimatedTokens = estimatedTokens
            self.didTrim = didTrim
            self.promptOverBudget = promptOverBudget
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

    /// One shared encoder (round-4-sync item 14, AGENTS.md §2's
    /// shared-encoder rule): the three encode sites below (per-field
    /// bytes, shell tokens, assembly) allocated a fresh `JSONEncoder`
    /// per call on this MainActor hot path. Default configuration, so
    /// output bytes are identical — the existing token/byte tests prove
    /// behavior-neutrality by passing unchanged.
    private static let encoder = JSONEncoder()

    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// Encoded JSON byte size of one field. Measured over the actual
    /// `JSONEncoder` output -- not over `displayText` alone -- so the
    /// per-field framing the model really receives (`asOf`, `source`, the
    /// `excludedFromAI`/`isClinical` flags, and all JSON punctuation) is
    /// counted too (code review WP-20 round 1, #2). UTF-8 multibyte sequences
    /// (the profile's `·`/`—` separators) inflate the byte count, which errs
    /// conservative -- the safe direction for a budget. Falls back to a plain
    /// character heuristic only if encoding itself throws (never observed for
    /// these `Codable` value types; keeps the estimate non-throwing).
    static func encodedBytes(for field: ProfileField) -> Int {
        if let encoded = try? Self.encoder.encode(field) {
            return encoded.count
        }
        return field.key.count + field.displayText.count + field.source.count
    }

    /// **The** budget formula, in one place (code review WP-21/22 round 4,
    /// #5): `JSONEncoder` frames an array as `[` + objects joined by single
    /// commas + `]`, so a field array's byte size is `2 + summed field bytes
    /// + (count - 1)` commas, and tokens are bytes / 4 rounded up. Both
    /// `estimatedTokens(for:)` and `selectFields`'s incremental fit check go
    /// through here, so the running total and the reported total can never be
    /// two disagreeing roundings (`ceil(a/4)+ceil(b/4)` is not
    /// `ceil((a+b)/4)`, code review WP-20 round 1, #3) and there is no
    /// second copy of the array framing to drift. If `ProfileField` ever
    /// gains a custom `encode(to:)`, or the encoder gains `outputFormatting`,
    /// this is the single function to update.
    static func tokens(forFieldBytes bytes: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return bytesToTokens(2 + bytes + (count - 1))
    }

    /// Token-budget estimate (WP-20 step 2) for a field set: the JSON-encoded
    /// byte size of the array divided by 4, rounded up, via the shared
    /// `tokens(forFieldBytes:count:)` formula.
    public static func estimatedTokens(for fields: [ProfileField]) -> Int {
        tokens(
            forFieldBytes: fields.reduce(0) { $0 + encodedBytes(for: $1) },
            count: fields.count
        )
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
        if let json = try? Self.encoder.encode(shell) {
            return bytesToTokens(json.count)
        }
        return 0
    }

    /// Priority rank, low number = keep first (WP-20 step 2: "vitals > sleep
    /// > activity > history"). Matches on `KnowledgeDerivation`'s key-prefix
    /// constants -- not local literals -- so a key rename breaks at compile
    /// time instead of silently demoting the field to rank 3 (code review
    /// #6). Correction-pinned fields (WP-19) keep their original key, so a
    /// correction shadowing a derived key ranks exactly where the field it
    /// overrides would; standalone user content is lifted ahead of every
    /// derived rank by `orderingRank` (see `selectFields`), so WP-19's
    /// "corrections beat re-derivation" survives trimming too, not just
    /// `refresh()`.
    /// Single ordered table of derived-key prefixes. Both `priorityRank` and
    /// `hasDerivedKeyPrefix` consult it, so a newly added prefix is visible
    /// in both -- the set can't silently drift between the two.
    static let derivedKeyRanks: [(prefix: String, rank: Int)] = [
        (KnowledgeDerivation.vitalsKeyPrefix, 0),
        (KnowledgeDerivation.sleepKeyPrefix, 1),
        (KnowledgeDerivation.stepsKeyPrefix, 2),
        (KnowledgeDerivation.activityKeyPrefix, 2),
        (KnowledgeDerivation.clinicalKeyPrefix, 3),
    ]
    public static func priorityRank(for key: String) -> Int {
        derivedKeyRanks.first { key.hasPrefix($0.prefix) }?.rank ?? 3
    }

    /// Drops the lowest-priority eligible fields until the remainder fits
    /// `tokenBudget`, preserving profile order within a rank (explicit index
    /// tie-break, not reliance on sort stability). Standalone correction-
    /// sourced fields (`source == KnowledgeStore.correctionSourceLabel` with
    /// no derived key prefix -- e.g. a WP-30 user goal) sort before rank 0:
    /// they are the user's own authoritative facts and are dropped last,
    /// never first. Strict prefix semantics: the scan stops at the
    /// first field that doesn't fit, so a smaller lower-priority field can
    /// never jump the queue ahead of a larger higher-priority one (code
    /// review #1 -- the previous skip-and-continue loop allowed exactly that
    /// inversion, and its keep-one fallback never triggered because `kept`
    /// was already non-empty). Guarantees at least the single
    /// highest-priority field whenever anything is eligible: a zero-field
    /// context from a non-empty profile would be useless. Every fit check and
    /// the reported total go through the shared
    /// `tokens(forFieldBytes:count:)` formula that `estimatedTokens(for:)`
    /// also uses, so they are one formula, not two disagreeing roundings
    /// (#3), and each field is encoded once rather than re-encoding the whole
    /// growing candidate array per iteration.
    public static func selectFields(from eligible: [ProfileField], tokenBudget: Int) -> FieldSelection {
        let ordered = eligible.enumerated()
            .sorted {
                let leftRank = orderingRank(for: $0.element)
                let rightRank = orderingRank(for: $1.element)
                if leftRank != rightRank { return leftRank < rightRank }
                return $0.offset < $1.offset
            }
            .map(\.element)
        // Incremental byte accounting through the shared formula: each field
        // is encoded once, with no per-iteration whole-array re-encode and no
        // final re-encode for the report, while every fit check and the
        // reported total go through `tokens(forFieldBytes:count:)` -- one
        // formula, so the running total and the reported total can never
        // disagree (code review WP-21/22 round 4, #5).
        var kept: [ProfileField] = []
        var keptBytes = 0
        for field in ordered {
            let fieldBytes = encodedBytes(for: field)
            if tokens(forFieldBytes: keptBytes + fieldBytes, count: kept.count + 1) <= tokenBudget {
                kept.append(field)
                keptBytes += fieldBytes
            } else {
                break
            }
        }
        if kept.isEmpty, let first = ordered.first {
            kept = [first]
            keptBytes = encodedBytes(for: first)
        }
        let keptTokens = tokens(forFieldBytes: keptBytes, count: kept.count)
        // Overflow is reported here -- not patched up by callers -- so the
        // pure container-free API WP-27's escalation offer reads is itself
        // correct: trimming *or* the surviving fields still exceeding the
        // budget (e.g. the keep-one fallback holding a single over-budget
        // top field, where `kept.count < eligible.count` alone would report
        // "nothing trimmed").
        let didTrim = kept.count < eligible.count || (!kept.isEmpty && keptTokens > tokenBudget)
        return FieldSelection(kept: kept, estimatedTokens: keptTokens, didTrim: didTrim)
    }

    /// Sort rank for one field. A correction *shadowing* a derived key keeps
    /// that key's rank (the `priorityRank` doc invariant); a
    /// correction-sourced field no derivation produces (standalone user
    /// content -- e.g. a WP-30 goal) sorts before rank 0 instead of falling
    /// to rank 3, so the user's own authoritative facts are dropped last.
    /// Kept separate from `priorityRank(for:)` so the key-prefix table stays
    /// testable on keys alone while trimming honors provenance.
    static func orderingRank(for field: ProfileField) -> Int {
        if field.source == KnowledgeStore.correctionSourceLabel, !hasDerivedKeyPrefix(field.key) {
            return -1
        }
        return priorityRank(for: field.key)
    }

    /// Whether `key` carries one of `KnowledgeDerivation`'s prefixes (i.e. a
    /// derivation could have produced it). Single place that knows the prefix
    /// set outside `priorityRank` itself.
    static func hasDerivedKeyPrefix(_ key: String) -> Bool {
        derivedKeyRanks.contains { key.hasPrefix($0.prefix) }
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
    ///
    /// - Parameter promptTokens: estimated tokens of the effective system
    ///   prompt (instructions) for this turn -- reserved out of `tokenBudget`
    ///   before the shell and fields. WP-21's prompt is unbounded user text
    ///   plus a ~150-token safety suffix; without this reserve a long persona
    ///   plus a full 4K health context overflows the on-device window while
    ///   `didTrim` reports `false`. Callers pass
    ///   `PromptManager.estimatedTokens(for: effectivePrompt)`; pass 0 only
    ///   for a turn that genuinely carries no instructions. Deliberately has
    ///   **no default**: a default of 0 made the reserve opt-in, so a caller
    ///   that simply forgot it silently reproduced the overflow this
    ///   parameter exists to prevent (code review WP-21/22 round 4, #9).
    /// - Parameter maxStoredSnapshots: hard retention cap; oldest snapshots
    ///   beyond it are deleted on each assembly, nulling linked
    ///   `ChatTurn`s first (see `maxStoredSnapshots` and `pruneSnapshots`).
    public func assemble(
        for purpose: Purpose,
        now: Date = .now,
        locale: Locale = .current,
        unitSystem: UnitSystem? = nil,
        tokenBudget: Int = ContextAssembler.onDeviceTokenBudget,
        promptTokens: Int,
        maxStoredSnapshots: Int = ContextAssembler.maxStoredSnapshots
    ) throws -> AssembledContext {
        let resolvedUnitSystem = unitSystem ?? Self.defaultUnitSystem(for: locale)
        let context = ModelContext(modelContainer)
        let sections = try KnowledgeStore.fetchProfile(from: context)?.sections ?? []
        let eligible = sections.includedInAI()
        // Reserve the prompt and the fixed shell before selecting fields, so
        // the reported total covers the whole request, not just the fields
        // (#2, plus the WP-21 prompt reserve). Off by two bytes (`[]` in the
        // shell vs `[...]` in the full encoding) -- negligible and
        // conservative.
        let shell = Self.estimatedShellTokens(
            localeIdentifier: locale.identifier,
            unitSystem: resolvedUnitSystem,
            today: now
        )
        let selection = Self.selectFields(
            from: eligible,
            tokenBudget: max(tokenBudget - promptTokens - shell, 0)
        )
        let healthContext = HealthContext(
            fields: selection.kept,
            localeIdentifier: locale.identifier,
            unitSystem: resolvedUnitSystem,
            today: now
        )
        let json = try Self.encoder.encode(healthContext)
        // Single commit: prune the pre-insert set first -- reserving the new
        // row's slot arithmetically (`keeping - 1`) so its own assembly can
        // never evict it, whatever `now` says -- then insert + save once. A
        // save-prune-save split could commit the snapshot and then throw,
        // orphaning the health-context row it exists to bound. (A cap of 0
        // still retains the in-flight row: the returned ID must always
        // resolve.)
        try Self.pruneSnapshots(in: context, keeping: maxStoredSnapshots - 1)
        let snapshot = ContextSnapshot(json: json, createdAt: now, purpose: purpose.rawValue)
        context.insert(snapshot)
        try context.save()
        // Overflow signal: field trimming (reported by `selectFields`) *or*
        // the whole request -- prompt + shell + fields -- still exceeding the
        // budget. `promptOverBudget` separates the remedies: prompt too long
        // (shorten it) vs fields dropped (escalation may recover them).
        // Together they are the overflow report WP-27's escalation offer
        // reads (D14.2).
        let totalTokens = promptTokens + shell + selection.estimatedTokens
        let didTrim = selection.didTrim || totalTokens > tokenBudget
        return AssembledContext(
            context: healthContext,
            snapshotID: snapshot.id,
            estimatedTokens: totalTokens,
            didTrim: didTrim,
            // `>=`, not `>`: at exact equality the field budget is already 0,
            // so no field selection can fit and the remedy is a shorter
            // prompt, not escalation -- the documented contract. `>` reported
            // "fields were dropped to fit" for a request whose prompt plus
            // shell consumed the entire window (code review WP-21/22 round 4,
            // #3).
            promptOverBudget: promptTokens + shell >= tokenBudget
        )
    }

    /// Decodes a persisted snapshot back to its health context -- the single
    /// reader for the encoding this type writes in `assemble` (WP-25 review
    /// #20): the chat UI's "What did the coach see?" expander goes through
    /// here, so a future encoding change breaks one call site, not a
    /// hand-rolled decode elsewhere.
    public static func decodeSnapshot(_ snapshot: ContextSnapshot) throws -> HealthContext {
        try JSONDecoder().decode(HealthContext.self, from: snapshot.json)
    }

    /// Evicts snapshots older than the `keeping`-newest window so the table
    /// stays bounded *including* chat-linked rows: each evicted row first has
    /// its `ChatTurn`s' `contextSnapshotID` nulled (nil renders as "context
    /// expired" -- never a dangling ID), then the row is deleted. Static and
    /// context-taking so the policy is unit-testable; called pre-insert by
    /// `assemble` (with `keeping - 1`, reserving the incoming row's slot).
    ///
    /// Bounded on the hot path: eviction candidates come from a sorted fetch
    /// with `fetchOffset = keeping` (the `KnowledgeStore.fetchProfile`
    /// idiom) -- never a whole-table load -- and each evicted row costs one
    /// targeted turn-nulling query. Steady state (nothing past the window)
    /// costs exactly one offset query and zero turn queries.
    static func pruneSnapshots(in context: ModelContext, keeping: Int) throws {
        // Clamp rather than bail: a negative window means "retain none of the
        // pre-existing rows", not "retain all of them". `assemble` passes
        // `maxStoredSnapshots - 1`, so a cap of 0 arrives here as -1 -- the
        // early `return` it used to hit made cap 0 the one value that
        // disabled pruning entirely, inverting the constant's meaning and
        // growing the store without bound (code review WP-21/22 round 4, #1).
        let keeping = max(keeping, 0)
        var descriptor = FetchDescriptor<ContextSnapshot>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchOffset = keeping
        // Bounded drain: without a limit, any non-steady-state prune (a store
        // that accumulated rows before the cap existed, or a lowered cap)
        // materializes every over-cap row *including its `json` payload* on
        // the turn's hot path. Steady state is one row; the backlog drains
        // over successive assemblies (round 4, #6).
        descriptor.fetchLimit = Self.maxSnapshotEvictionsPerAssembly
        for expired in try context.fetch(descriptor) {
            // Hoisted: the predicate macro reads `expired.id` member access
            // as a key path, so the UUID goes through a local first.
            let targetID = expired.id
            let turns = try context.fetch(FetchDescriptor<ChatTurn>(
                predicate: #Predicate { $0.contextSnapshotID == targetID }
            ))
            for turn in turns {
                turn.contextSnapshotID = nil
            }
            context.delete(expired)
        }
    }
}
