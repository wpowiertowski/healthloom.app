// KnowledgeStore.swift
//
// WP-19 (implementation-plan.md) / architecture.md D7: derives the compact,
// human-readable `KnowledgeProfile` from HealthKit (via `HealthReadStore`)
// and `LocalSample`. `ContextAssembler` (WP-20) reads the persisted
// `KnowledgeProfile` this store maintains -- never HealthKit or
// `LocalSample` directly (architecture.md §2).
//
// `@MainActor`: matches CoachKit's package-wide default isolation and the
// app target's own `TodayMetricsProvider`/`ActivitiesProvider` precedent
// (both `@MainActor final class`) -- `ModelContext` is naturally used from a
// single actor context, and nothing here is hot enough to need off-main
// work. `KnowledgeRefreshTrigger.swift` is the separate, also-`@MainActor`
// type that wires this store's `refresh()` to SwiftData's `HistoryObserver`
// (WP-19 step 3).

import CoreModel
import Foundation
import SwiftData
import SyncKit

@MainActor
public final class KnowledgeStore {
    /// The exact `GoogleDataType` read set WP-19 step 1 specifies (steps,
    /// resting HR, HRV, sleep, workouts) -- passed to `HealthKitAuth
    /// .requestRead(_:)` by `requestReadAuthorization()`. Deliberately
    /// excludes the four `.localOnly` types (Active Zone Minutes, Active
    /// Minutes, ECG, Irregular Rhythm Notification): those come from
    /// `LocalSample`/SwiftData, not a HealthKit read, so they need no HK
    /// authorization at all.
    ///
    /// **Deviation (plan predates the SDK, per this plan's own "Blocked?"
    /// clause):** step 1 also names "the user's heart-rate zone
    /// configuration (new iOS 27 HealthKit zones API)." No such API exists
    /// in the actual iOS 27.0 SDK (`HealthKit.framework/Headers` at Xcode
    /// 27.0 build 27A5218g was searched for "zone"; the only hit,
    /// `HKLiveWorkoutZoneUpdate`, is a live-workout zone-*crossing* event
    /// during an in-progress `HKWorkoutSession`, not a readable
    /// configuration object). Omitted entirely rather than guessed; flagged
    /// in progress.md for whoever revisits architecture.md D6's zones
    /// mention once/if Apple ships the real API.
    public static let readDataTypes: [GoogleDataType] = [
        .steps, .dailyRestingHeartRate, .heartRateVariability, .sleep, .exercise,
    ]

    /// `ProfileField.source` value marking a field as a user-pinned
    /// correction (WP-19 step 2 / WP-30's future "Correct" UI): `refresh()`
    /// never overwrites a field carrying this source, regardless of what
    /// fresh HealthKit/LocalSample data would otherwise derive for the same
    /// `key`. WP-30 (P3, "Knowledge transparency UI") owns the UI that
    /// writes fields with this source; this WP only guarantees they survive
    /// once written -- see `refresh()`'s doc comment.
    public static let correctionSourceLabel = "User correction"

    // Internal (not private): the steps/workouts tools clamp to these same
    // windows so each schema promises only what the store caches -- one
    // compiler-tied constant per topic, not two numbers to keep in sync
    // (same treatment `sleepWindowNights` already has).
    static let stepsWindowDays = 30
    private static let vitalsWindowDays = 30
    // Internal (not private): `GetRecentSleepTool` clamps to this same
    // window so the schema the model sees matches what the store caches --
    // one compiler-tied constant, not two numbers to keep in sync.
    static let sleepWindowNights = 14
    static let workoutsWindowDays = 30
    private static let localOnlyWindowDays = 7

    private let modelContainer: ModelContainer
    private let healthReadStore: HealthReadStore
    private let healthKitAuth: HealthKitAuth
    private let calendar: Calendar

    // Last-fetched raw arrays, retained only so the tool-facing summary API
    // (step 4, below) can re-slice a different window than the profile's
    // fixed one without a second HealthKit round trip. Never read by
    // anything outside this file -- `refresh()`'s derived `ProfileField`s are
    // the only externally-visible state (architecture.md D7).
    private var cachedSteps: [DailyQuantityValue] = []
    private var cachedRestingHeartRate: [QuantityReading] = []
    private var cachedHeartRateVariability: [QuantityReading] = []
    private var cachedSleepSegments: [SleepStageSegment] = []
    private var cachedWorkouts: [WorkoutRecord] = []
    private var cachedExerciseSupplements: [ExerciseSupplement] = []
    private var cachedLocalSamples: [LocalSample] = []

    /// The `now` most recently passed to `refresh(now:)` -- code review
    /// (2026-08-28) finding #5: the tool-facing summaries below must window
    /// the *cached* arrays (fetched relative to that `now`) against the same
    /// reference point, never real wall-clock `.now`, or a summary call can
    /// silently disagree with the data actually sitting in the cache.
    private var referenceNow: Date = .distantPast

    /// Cached excluded-key set for the WP-24 tool gate, populated at the end
    /// of every `refresh()` from the just-written profile (and on a cold
    /// gate check from the fetched row). Lets the gate answer without a
    /// store fetch per tool call. Anyone mutating `excludedFromAI` outside
    /// `refresh()` (tests, the future WP-30 settings UI) must call
    /// `invalidateCachedExclusions()` first -- the cache cannot observe
    /// external writes.
    private var cachedExcludedKeys: Set<String>?

    /// Serializes `refresh(now:)` calls -- code review (2026-08-28) finding
    /// #3: see `refresh(now:)`'s doc comment. A plain FIFO async lock, not a
    /// `Task`-chaining scheme: `KnowledgeProfile` (a `@Model` reference type)
    /// has its `Sendable` conformance explicitly marked unavailable by
    /// SwiftData, so it cannot be a `Task<Success, Failure>`'s result type
    /// -- confirmed by direct compilation, not assumed. `isRefreshing` +
    /// `refreshWaiters` need no further isolation of their own since every
    /// access happens on this `@MainActor` type.
    private var isRefreshing = false
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        modelContainer: ModelContainer,
        healthReadStore: HealthReadStore,
        healthKitAuth: HealthKitAuth,
        calendar: Calendar = .current
    ) {
        self.modelContainer = modelContainer
        self.healthReadStore = healthReadStore
        self.healthKitAuth = healthKitAuth
        self.calendar = calendar
    }

    /// Requests HealthKit read authorization for exactly `Self.readDataTypes`
    /// (WP-19 step 1, via `HealthKitAuth.requestRead(_:)`, WP-06). Safe to
    /// call repeatedly (`HealthKitAuth`'s own documented incremental-call
    /// contract, HealthKitAuth.swift) -- callers don't need to track whether
    /// this has run before.
    ///
    /// **Not wired to any UI by this WP** (its "Touches" line names only
    /// `CoachKit`): the app target already owns every other `requestRead`
    /// call site (onboarding's HealthKit screen, widened once each by
    /// WP-12b and WP-33) with its own copy explaining *why*; adding this
    /// read set's prompt there — with equivalent copy — is scope for
    /// whichever future WP first gives the coach an app-target surface
    /// (WP-25's Chat UI is the next candidate). Until then this method
    /// exists and is called by nothing; `refresh()` still functions and
    /// degrades gracefully (see its doc comment) because HealthKit read
    /// denial is invisible regardless (HealthKitAuth.swift's documented
    /// rule) — un-requested and denied authorization look identical to a
    /// query, so there is no broken intermediate state, only fewer signals
    /// until the prompt exists.
    public func requestReadAuthorization() async throws(HealthKitAuthError) {
        try await healthKitAuth.requestRead(Self.readDataTypes)
    }

    /// Re-derives every `ProfileField` from HealthKit + `LocalSample` and
    /// persists the result to the single `KnowledgeProfile` row.
    ///
    /// **Correction pinning (WP-19 step 2):** any existing field whose
    /// `source == Self.correctionSourceLabel` is preserved byte-for-byte
    /// instead of being overwritten by this cycle's derivation for the same
    /// `key` — "corrections beat re-derivation." A correction field with a
    /// `key` this cycle didn't derive anything for (e.g. a user goal with no
    /// HealthKit counterpart) is kept too, appended after the derived set.
    ///
    /// **Graceful degradation:** every per-signal read degrades to an empty
    /// result on failure or missing authorization (`HealthReadStore`'s
    /// documented posture) — an empty read simply omits that field from the
    /// profile this cycle, it never fails `refresh()` itself.
    ///
    /// **Reentrancy (code review 2026-08-28 finding #3):** overlapping calls
    /// are serialized strictly in call order — a call never starts its own
    /// HealthKit reads until every call made before it has fully finished
    /// (succeeded or thrown). Without this, a slow call started with an
    /// earlier `now` could finish and save *after* a faster call started
    /// with a later `now`, moving `KnowledgeProfile.updatedAt` backward and
    /// clobbering fresher data with stale data.
    ///
    /// **Failure (code review 2026-08-28 finding #2):** propagates
    /// `ModelContext.save()`'s error instead of swallowing it — a failed
    /// save must be visible to the caller, not silently leave the on-disk
    /// profile stale while returning as if it persisted.
    @discardableResult
    public func refresh(now: Date = .now) async throws -> KnowledgeProfile {
        await acquireRefreshLock()
        defer { releaseRefreshLock() }
        return try await performRefresh(now: now)
    }

    /// FIFO async lock (code review 2026-08-28 finding #3's fix -- see
    /// `refresh(now:)`'s doc comment and this type's `isRefreshing`/
    /// `refreshWaiters` properties for why this isn't `Task`-based).
    private func acquireRefreshLock() async {
        guard isRefreshing else {
            isRefreshing = true
            return
        }
        await withCheckedContinuation { continuation in
            refreshWaiters.append(continuation)
        }
    }

    /// Hands the lock to the next waiter (in call order) if any, or releases
    /// it entirely. Always runs via `defer`, so a thrown `performRefresh`
    /// never leaves a waiter stuck forever.
    private func releaseRefreshLock() {
        guard !refreshWaiters.isEmpty else {
            isRefreshing = false
            return
        }
        refreshWaiters.removeFirst().resume()
    }

    private func performRefresh(now: Date) async throws -> KnowledgeProfile {
        let stepsStart = windowStart(daysBack: Self.stepsWindowDays, from: now)
        let vitalsStart = windowStart(daysBack: Self.vitalsWindowDays, from: now)
        let sleepStart = windowStart(daysBack: Self.sleepWindowNights, from: now)
        let workoutsStart = windowStart(daysBack: Self.workoutsWindowDays, from: now)
        let localOnlyStart = windowStart(daysBack: Self.localOnlyWindowDays, from: now)

        async let steps = healthReadStore.dailySteps(from: stepsStart, to: now)
        async let restingHeartRate = healthReadStore.dailyRestingHeartRate(from: vitalsStart, to: now)
        async let heartRateVariability = healthReadStore.dailyHeartRateVariability(from: vitalsStart, to: now)
        async let sleepSegments = healthReadStore.sleepStageSegments(from: sleepStart, to: now)
        async let workouts = healthReadStore.workouts(from: workoutsStart, to: now)

        let fetchedSteps = await steps
        let fetchedRestingHeartRate = await restingHeartRate
        let fetchedHeartRateVariability = await heartRateVariability
        let fetchedSleepSegments = await sleepSegments
        let fetchedWorkouts = await workouts

        let context = ModelContext(modelContainer)
        // Code review (2026-08-28) finding #10: bound the fetch to the
        // widest window any derivation below actually needs
        // (`workoutsWindowDays`, always ≥ `localOnlyWindowDays`) instead of
        // pulling every `LocalSample` row ever stored. This is also what
        // fixes finding #4 (the unlinked-workout count silently including
        // arbitrarily old sessions): `cachedExerciseSupplements` below is
        // derived from this same bounded fetch, so it can never contain a
        // sample older than `workoutsWindowDays` in the first place.
        //
        // Code review (2026-09-01): upper-bound against `now` too, matching
        // `KnowledgeDerivation.localOnlyField`'s own `asOf` bound a few
        // layers downstream -- without it, a future-dated sample (device
        // clock skew during import) never aged out of this cache at all.
        let localSampleFetchStart = min(workoutsStart, localOnlyStart)
        let localSampleDescriptor = FetchDescriptor<LocalSample>(
            predicate: #Predicate<LocalSample> { $0.start >= localSampleFetchStart && $0.start <= now }
        )
        // Code review (2026-09-01): propagate a real fetch failure instead of
        // swallowing it via `try?` -- treating "SwiftData fetch threw" the
        // same as "no local samples" would, on every derived-field rebuild
        // below, silently erase previously-persisted local-only/clinical
        // fields from the profile instead of leaving them stale. Matches
        // `refresh()`'s own doc comment ("Failure ... propagates
        // `ModelContext.save()`'s error instead of swallowing it").
        let fetchedLocalSamples = try context.fetch(localSampleDescriptor)
        let fetchedExerciseSupplements = fetchedLocalSamples
            .filter { $0.dataType == GoogleDataType.exercise.rawValue }
            .map(ExerciseSupplement.init(sample:))

        // Code review (2026-09-01): commit every cached array + `referenceNow`
        // together, with no `await` between these assignments -- the
        // tool-facing summaries below (`stepsSummary`/`sleepSummary`/
        // `workoutsSummary`/`vitalsSummary`) read this cache directly and
        // don't coordinate with `acquireRefreshLock()`/`releaseRefreshLock()`,
        // so a concurrent summary call must never be able to observe a
        // partially-updated cache straddling two different refresh
        // generations (e.g. `cachedRestingHeartRate` already from this cycle
        // while `cachedHeartRateVariability` is still from the last one).
        cachedSteps = fetchedSteps
        cachedRestingHeartRate = fetchedRestingHeartRate
        cachedHeartRateVariability = fetchedHeartRateVariability
        cachedSleepSegments = fetchedSleepSegments
        cachedWorkouts = fetchedWorkouts
        cachedLocalSamples = fetchedLocalSamples
        cachedExerciseSupplements = fetchedExerciseSupplements
        referenceNow = now

        var derived: [ProfileField] = []
        if let field = KnowledgeDerivation.stepsField(
            dailyValues: cachedSteps, windowDays: Self.stepsWindowDays, asOf: now, source: "HealthKit"
        ) {
            derived.append(field)
        }
        if let field = KnowledgeDerivation.restingHeartRateField(
            readings: cachedRestingHeartRate, windowDays: Self.vitalsWindowDays, asOf: now, source: "HealthKit"
        ) {
            derived.append(field)
        }
        if let field = KnowledgeDerivation.heartRateVariabilityField(
            readings: cachedHeartRateVariability, windowDays: Self.vitalsWindowDays, asOf: now, source: "HealthKit"
        ) {
            derived.append(field)
        }
        derived.append(contentsOf: KnowledgeDerivation.sleepFields(
            segments: cachedSleepSegments, nights: Self.sleepWindowNights, asOf: now, source: "HealthKit", calendar: calendar
        ))
        if let field = KnowledgeDerivation.workoutsField(
            workouts: cachedWorkouts,
            exerciseSupplements: cachedExerciseSupplements,
            windowDays: Self.workoutsWindowDays,
            asOf: now,
            source: "HealthKit"
        ) {
            derived.append(field)
        }
        for type in GoogleDataType.allCases where type.writability == .localOnly {
            if let field = KnowledgeDerivation.localOnlyField(
                dataType: type,
                samples: cachedLocalSamples,
                windowStart: localOnlyStart,
                windowDays: Self.localOnlyWindowDays,
                asOf: now
            ) {
                derived.append(field)
            }
        }

        let profile = try fetchOrCreateProfile(context: context)
        // Code review (2026-08-28) finding #1: `Dictionary(uniqueKeysWithValues:)`
        // traps on a duplicate key. Nothing in this type enforces that at
        // most one correction-sourced field exists per key (`sections` is a
        // plain array) -- a future correction-writing UI bug, migration
        // artifact, or hand-seeded profile must degrade, not crash. Keeping
        // the first occurrence is an arbitrary but deterministic tie-break.
        let corrections = Dictionary(
            profile.sections
                .filter { $0.source == Self.correctionSourceLabel }
                .map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // WP-30 (durable exclusion): carry each key's previous
        // `excludedFromAI` forward onto this cycle's rebuilt derived field.
        // Without this, a You-tab toggle would be wiped by the next
        // `refresh()`, which rebuilds every non-correction field from
        // scratch. Correction-sourced fields keep their own flags untouched
        // (taken as-is below); brand-new keys fall back to the derivation
        // defaults (D8). A field absent for a cycle then re-derived loses
        // its flag — accepted and documented on `setExcludedFromAI`.
        let previousFlags = Dictionary(
            profile.sections.map { ($0.key, $0.excludedFromAI) },
            uniquingKeysWith: { first, _ in first }
        )
        let merged = derived.map { fresh -> ProfileField in
            if let pinned = corrections[fresh.key] {
                return pinned
            }
            var carried = fresh
            if let previous = previousFlags[fresh.key] {
                carried.excludedFromAI = previous
            }
            return carried
        }
        let derivedKeys = Set(derived.map(\.key))
        // Code review (2026-09-01): read from the already-deduped `corrections`
        // dictionary, not `profile.sections` directly -- filtering the raw
        // array here had no dedup of its own, so two correction-sourced
        // fields that happened to share a key (duplicate seed data, a
        // migration artifact) would both survive into `profile.sections`
        // every cycle, forever.
        // Deterministic order: `Dictionary.values` iterates in per-process
        // hash order, and these fields now sort highest-priority at trim time
        // (ContextAssembler.orderingRank) -- persisting hash order would make
        // which user correction survives trimming vary across launches.
        let untouchedCorrections = corrections.values
            .filter { !derivedKeys.contains($0.key) }
            .sorted { $0.key < $1.key }
        profile.sections = merged + untouchedCorrections
        profile.updatedAt = now
        try context.save()
        // Populated only after the save succeeds: caching the about-to-be-
        // attempted write would stick on a throw while the disk row stays
        // old, reopening the fail-open leak the gate exists to close. On
        // throw the previous generation's set (matching the still-persisted
        // row) simply stays put.
        cachedExcludedKeys = profile.sections.excludedKeys
        return profile
    }

    /// Drops the cached exclusion set; the next gate check re-reads it.
    /// Call after any out-of-band `excludedFromAI` mutation.
    public func invalidateCachedExclusions() {
        cachedExcludedKeys = nil
    }

    /// Shared single-row read for the persisted profile (code review WP-20
    /// round 1, #4): `fetchOrCreateProfile(context:)` below and
    /// `ContextAssembler.assemble(for:...)` both resolve through here, so a
    /// future change to how the row is located lands in one place. Newest
    /// `updatedAt` first with `fetchLimit` 1: a no-op while the single-row
    /// invariant holds, and a deterministic choice (the freshest row -- the
    /// one the last successful `refresh()` wrote) if it is ever violated,
    /// instead of whichever row SwiftData happens to return first. A
    /// schema-level `@Attribute(.unique)` constraint would enforce rather
    /// than resolve the invariant, but it needs a synthetic key plus a store
    /// migration -- left for whoever next touches this model's schema.
    static func fetchProfile(from context: ModelContext) throws -> KnowledgeProfile? {
        var descriptor = FetchDescriptor<KnowledgeProfile>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Exclusion gate for WP-24 tools (D7/D8): whether ANY listed profile
    /// key is currently excluded from AI. Tools check this before answering
    /// and refuse with a settings message instead of speaking excluded data
    /// -- the summary methods below re-derive from raw caches that know
    /// nothing of exclusions, so the gate (not the summary) enforces them.
    /// ANY-match, not ALL: a tool answers a topic, and one excluded field
    /// in that topic poisons the whole answer. Missing profile (never
    /// refreshed) means no exclusions known -- tools answer normally and
    /// the summaries' own "no data" fallbacks apply.
    ///
    /// Write-path note (WP-30 design): `refresh()` carries each key's
    /// previous `excludedFromAI` onto the rebuilt derived field, so a
    /// settings toggle survives refreshes. The one gap is a field absent
    /// for a cycle then re-derived (its flag resets to the derivation
    /// default) -- accepted: the next `refresh()` after a re-toggle
    /// re-carries it.
    public func isAnyExcludedFromAI(_ keys: [String]) throws -> Bool {
        guard !keys.isEmpty else { return false }
        if let cachedExcludedKeys {
            return keys.contains(where: cachedExcludedKeys.contains)
        }
        let context = ModelContext(modelContainer)
        guard let profile = try Self.fetchProfile(from: context) else {
            // Warm the cache even here: no profile means no exclusions, and
            // `refresh()` overwrites the set the moment it writes a row, so
            // the empty placeholder can't go stale.
            cachedExcludedKeys = []
            return false
        }
        let excluded = profile.sections.excludedKeys
        cachedExcludedKeys = excluded
        return keys.contains(where: excluded.contains)
    }

    /// The funneled write path for `excludedFromAI` (the You tab calls this,
    /// never flips flags on the row directly): mutates the key's field,
    /// persists, and refreshes the exclusion cache in the same breath, so
    /// the gate and `ContextAssembler`'s live read agree immediately.
    /// Durable across `refresh()` cycles via flag carry-over (see
    /// `performRefresh`); a field absent for a cycle then re-derived resets
    /// to the derivation default.
    public func setExcludedFromAI(_ excluded: Bool, forKey key: String) throws {
        let context = ModelContext(modelContainer)
        guard let profile = try Self.fetchProfile(from: context),
              let index = profile.sections.firstIndex(where: { $0.key == key })
        else { return }
        profile.sections[index].excludedFromAI = excluded
        try context.save()
        cachedExcludedKeys = profile.sections.excludedKeys
    }

    /// Pins a user correction for `key` (WP-30 "Correct"): inserts or
    /// replaces a `correctionSourceLabel`-sourced field with the user's
    /// text. Beats re-derivation — `refresh()` preserves
    /// correction-sourced fields byte-for-byte. Preserves the existing
    /// field's `excludedFromAI`/`isClinical` when one exists (a correction
    /// edits the fact, not its sharing posture); brand-new keys (e.g. user
    /// goals with no HealthKit counterpart) take the struct defaults.
    public func pinCorrection(displayText: String, forKey key: String) throws {
        let context = ModelContext(modelContainer)
        let profile = try fetchOrCreateProfile(context: context)
        let trimmed = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = profile.sections.first(where: { $0.key == key })
        let pinned = ProfileField(
            key: key,
            displayText: trimmed,
            source: Self.correctionSourceLabel,
            asOf: .now,
            excludedFromAI: existing?.excludedFromAI,
            isClinical: existing?.isClinical ?? false
        )
        if let index = profile.sections.firstIndex(where: { $0.key == key }) {
            profile.sections[index] = pinned
        } else {
            profile.sections.append(pinned)
        }
        try context.save()
        cachedExcludedKeys = profile.sections.excludedKeys
    }

    private func fetchOrCreateProfile(context: ModelContext) throws -> KnowledgeProfile {
        // Code review (2026-09-01): propagate a real fetch failure instead of
        // swallowing it via `try?` -- treating "fetch threw" the same as "no
        // profile exists yet" would insert a second `KnowledgeProfile`
        // alongside the real one already on disk, breaking this store's
        // documented single-row invariant (this type's header, and this
        // method's own name).
        if let existing = try Self.fetchProfile(from: context) {
            return existing
        }
        let created = KnowledgeProfile()
        context.insert(created)
        return created
    }

    // MARK: - Tool-facing summaries (WP-19 step 4)
    //
    // "Summary API for tools... all reading derived data, never raw dumps"
    // (WP-24's `Tool`s call these). Each re-runs the same pure derivation
    // over a caller-chosen sub-window of the data `refresh()` already
    // fetched — real derived text at the requested granularity, not the
    // fixed profile window, but still never a raw sample dump. Falls back to
    // a plain "no data" sentence (never `nil`/a thrown error) since a tool's
    // output is spoken back to the user by the coach.

    // Code review (2026-08-28) finding #5: every window below is computed
    // against `referenceNow` (the `now` `refresh()` last fetched relative
    // to), never wall-clock `.now` -- `cachedSteps` et al. were fetched
    // relative to that `now`, so windowing against a *different* "now" here
    // can disagree with what's actually sitting in the cache (e.g. reporting
    // "no data" for a window that, relative to real wall-clock time, has
    // aged past what was fetched).

    // Code review (2026-09-01): every window below is clamped to the fixed
    // window `refresh()` actually cached (`stepsWindowDays`/`sleepWindowNights`/
    // `workoutsWindowDays`) before being used both to slice the cache *and*
    // as the derivation's displayed `windowDays`/`nights` label. Without the
    // clamp, a caller-requested window wider than the cache (e.g.
    // `stepsSummary(days: 90)` when `cachedSteps` only ever holds 30 days)
    // was a no-op over the actual cached data yet still rendered a claim
    // like "(90-day avg)" -- a wider window than the data underneath it.

    /// Window-start helper shared by the fetch windows above and the three
    /// cache-slicing summaries below (WP-24 deduplication): `daysBack` days
    /// before the reference point, falling back to the reference itself when
    /// the calendar computation fails.
    private func windowStart(daysBack: Int, from reference: Date) -> Date {
        calendar.date(byAdding: .day, value: -daysBack, to: reference) ?? reference
    }

    /// Joins derived field text for tool answers (WP-24 deduplication).
    private func joinedDisplayText(_ fields: [ProfileField]) -> String {
        fields.map(\.displayText).joined(separator: " ")
    }

    public func stepsSummary(days: Int, locale: Locale = .current) -> String {
        let clampedDays = Clamping.window(days, maximum: Self.stepsWindowDays)
        let start = windowStart(daysBack: clampedDays, from: referenceNow)
        let sliced = cachedSteps.filter { $0.day >= calendar.startOfDay(for: start) }
        return KnowledgeDerivation.stepsField(
            dailyValues: sliced, windowDays: clampedDays, asOf: referenceNow, source: "HealthKit", locale: locale
        )?.displayText ?? "No step data available for the last \(clampedDays) days."
    }

    public func sleepSummary(nights: Int) -> String {
        let clampedNights = Clamping.window(nights, maximum: Self.sleepWindowNights)
        let start = windowStart(daysBack: clampedNights, from: referenceNow)
        let sliced = cachedSleepSegments.filter { $0.start >= start }
        let fields = KnowledgeDerivation.sleepFields(
            segments: sliced, nights: clampedNights, asOf: referenceNow, source: "HealthKit", calendar: calendar
        )
        guard !fields.isEmpty else { return "No sleep data available for the last \(clampedNights) nights." }
        return joinedDisplayText(fields)
    }

    public func workoutsSummary(days: Int) -> String {
        let clampedDays = Clamping.window(days, maximum: Self.workoutsWindowDays)
        let start = windowStart(daysBack: clampedDays, from: referenceNow)
        let workouts = cachedWorkouts.filter { $0.start >= start }
        // `supplement.start` directly (code review finding #4's `ExerciseSupplement`
        // addition) -- no more looking the sample back up in `cachedLocalSamples`.
        let supplements = cachedExerciseSupplements.filter { $0.start >= start }
        return KnowledgeDerivation.workoutsField(
            workouts: workouts, exerciseSupplements: supplements, windowDays: clampedDays,
            asOf: referenceNow, source: "HealthKit"
        )?.displayText ?? "No workouts recorded in the last \(clampedDays) days."
    }

    public func vitalsSummary(locale: Locale = .current) -> String {
        let fields = [
            KnowledgeDerivation.restingHeartRateField(
                readings: cachedRestingHeartRate, windowDays: Self.vitalsWindowDays, asOf: referenceNow,
                source: "HealthKit", locale: locale
            ),
            KnowledgeDerivation.heartRateVariabilityField(
                readings: cachedHeartRateVariability, windowDays: Self.vitalsWindowDays, asOf: referenceNow,
                source: "HealthKit", locale: locale
            ),
        ].compactMap { $0 }
        guard !fields.isEmpty else { return "No recent vitals available." }
        return joinedDisplayText(fields)
    }
}
