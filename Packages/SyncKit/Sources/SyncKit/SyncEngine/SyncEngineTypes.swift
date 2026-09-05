// SyncEngineTypes.swift
//
// WP-09 (implementation-plan.md): pure, HealthKit-free types `SyncEngine`
// (SyncEngine.swift, `#if canImport(HealthKit)`) is built on -- the same
// pure/impure split WP-06/07/08 established (HealthKitIdentifierClassifier/
// HealthKitObjectTypeResolver; MappedDecision/MappedObject;
// HealthKitWriterTypes.swift/HealthKitWriter.swift). Everything here compiles
// on any platform `swift test` runs on, independent of HealthKit's
// availability, and is `nonisolated` throughout so it never needs an actor
// hop from `actor SyncEngine` (a distinct, non-MainActor actor -- see
// architecture.md §3) to read/call, mirroring GoogleHealthClient's
// `TokenClock`/`BackoffSleeper`/`JitterSource` seams (Networking/Clock.swift,
// Networking/BackoffPolicy.swift) and `HTTPSession` (Networking/HTTPSession.swift).

import CoreModel
import GoogleHealthClient
import Foundation

// MARK: - Window configuration (architecture.md D3)

/// Cursor + lookback window sizing (architecture.md §4 D3): every sync pulls
/// `since: (lastSyncedAt ?? now - initialWindow) - lookback(type)` .. `now`.
/// A pure value type -- `nonisolated` so `SyncEngine` (a distinct actor) can
/// call `lookback(for:)` without an actor hop.
nonisolated public struct SyncConfiguration: Sendable, Equatable {
    /// First-ever sync for a type with no `lastSyncedAt` yet pulls this much
    /// history (WP-09: "initialWindow: 7 d (backfill is WP-15)" -- this is
    /// *not* WP-15's user-chosen backfill horizon, just the incremental
    /// engine's own bootstrap window).
    public var initialWindow: TimeInterval
    /// Default lookback for every type except sleep (architecture.md D3: 72h).
    public var defaultLookback: TimeInterval
    /// Sleep-specific lookback (architecture.md D3: 7d -- "since sleep
    /// sessions finalize late").
    public var sleepLookback: TimeInterval

    public init(
        initialWindow: TimeInterval = 7 * 24 * 3600,
        defaultLookback: TimeInterval = 72 * 3600,
        sleepLookback: TimeInterval = 7 * 24 * 3600
    ) {
        self.initialWindow = initialWindow
        self.defaultLookback = defaultLookback
        self.sleepLookback = sleepLookback
    }

    /// `.sleep` gets the 7-day lookback (sessions finalize late); every other
    /// type gets the 72h default. Compares `GoogleDataType` cases directly --
    /// synthesized `Equatable`, not one of CoreModel's MainActor-isolated
    /// *computed* properties (`.writability`/`.filterName`/`.endpointName`),
    /// so this needs no `await` even from `SyncEngine`'s own (non-MainActor)
    /// actor.
    public nonisolated func lookback(for type: GoogleDataType) -> TimeInterval {
        type == .sleep ? sleepLookback : defaultLookback
    }
}

// MARK: - Sync clock (mirrors GoogleHealthClient's TokenClock)

/// Supplies "now" to `SyncEngine`, exactly mirroring
/// `GoogleHealthClient.TokenClock`'s seam (Networking/Clock.swift) for the
/// same reason: window-boundary math (architecture.md D3) must be testable
/// against an exact, manually-advanced fake clock, never real wall-clock
/// time -- WP-09's explicit instruction not to call `Date()` directly in
/// testable logic.
nonisolated public protocol SyncClock: Sendable {
    nonisolated func now() -> Date
}

/// Production clock: wall-clock time.
nonisolated public struct SystemSyncClock: SyncClock {
    public init() {}
    public func now() -> Date { Date() }
}

// MARK: - Google client seam

/// Narrow protocol over `GoogleHealthClient` (the DataClient struct,
/// GoogleHealthClient/DataClient/GoogleHealthDataClient.swift) covering only
/// the one method `SyncEngine` calls -- WP-09: "the Google client (or a
/// narrow protocol over it so tests can stub it)". The real
/// `GoogleHealthClient` conforms via `GoogleHealthClient+SyncEngine.swift`;
/// tests substitute their own scripted/stub conformer instead of a
/// network-backed client.
nonisolated public protocol GoogleReconcileClient: Sendable {
    nonisolated func reconcile(
        type: GoogleDataType,
        since: Date,
        until: Date,
        pageToken: String?
    ) async throws(GoogleHealthClientError) -> Page
}

// MARK: - Conflict filter hook (WP-09 -> WP-12b)

/// Pass-through hook sitting between `TypeMapper`'s output and the
/// existence-diff/write step (architecture.md D13; WP-09's explicit
/// instruction to leave this seam for WP-12b's `ConflictResolver` -- "not
/// built out further" here). Operates on `MappedObject` -- the already
/// HK-wrapped decision -- because that's exactly what D13.2's real resolver
/// needs to downgrade (e.g. `.quantity`/`.category` -> `.localOnly` when a
/// Google Exercise session overlaps a watch workout) and exactly what the
/// existence-diff/write step immediately downstream in `SyncEngine`
/// consumes. Declared `async` (even though this WP's own conformer,
/// `IdentityConflictFilter`, never suspends) because WP-12b's real resolver
/// will need to consult `WatchCoverageIndex`, itself backed by HealthKit
/// reads -- inherently async; declaring the seam `async` now avoids a
/// signature-breaking change later.
nonisolated public protocol ConflictFiltering: Sendable {
    nonisolated func resolve(_ mapped: MappedObject, for point: GoogleDataPoint) async -> MappedObject

    // WP-12b additions. All three have no-op default implementations (the
    // extension below) so `IdentityConflictFilter` and every pre-existing
    // test conformer keep compiling and behaving identically -- only
    // `WatchConflictResolver` (Conflict/WatchConflictResolver.swift)
    // implements them for real.

    /// Called by `SyncEngine.performSync`/`BackfillCoordinator.pullMapWrite`
    /// once at the start of each type's run, **before** the batched
    /// existence query, with the run's full window. The real resolver
    /// refreshes its per-run coverage cache here and performs D13.4's
    /// retroactive cleanup (deleting app-written objects that now conflict
    /// with watch coverage -- they're re-pulled and re-resolved by the very
    /// window this call precedes). A thrown error fails the run (cursor
    /// untouched, safely retried) -- but see `WatchConflictResolver
    /// .beginRun`'s doc comment: coverage *read* failures degrade gracefully
    /// instead of throwing; only cleanup *delete* failures propagate.
    nonisolated func beginRun(
        type: GoogleDataType,
        windowStart: Date,
        windowEnd: Date
    ) async throws(HealthKitWriterError)

    /// Drains (returns, then clears) the external-ID → watch-workout-UUID
    /// links for every Google Exercise session `resolve` deferred to a watch
    /// workout since the last drain (architecture.md D13.2). The caller
    /// applies them to the matching `LocalSample` rows' `linkedWatchWorkoutUUID`
    /// after its local upserts -- the resolver can't set the field itself
    /// because the row doesn't exist yet when `resolve` runs.
    /// Drains only `type`'s recorded links, leaving any
    /// concurrently-running type's run state untouched (one resolver per
    /// pipeline serves every type that pipeline syncs). There is
    /// deliberately no typeless overload: it would cross-contaminate runs,
    /// and a stale conformer must fail to compile, not fail silently.
    nonisolated func drainDeferredSessionLinks(for type: GoogleDataType) async -> [String: UUID]

    /// Drains (returns, then clears) the count of data points `resolve`
    /// suppressed -- fully or by splitting -- in favor of Apple Watch data
    /// since the last drain. Surfaces in `SyncOutcome.suppressedCount` and
    /// the sync log as "deferred to Apple Watch" (test-plan.md §2.3).
    nonisolated func drainSuppressedCount(for type: GoogleDataType) async -> Int
}

extension ConflictFiltering {
    nonisolated public func beginRun(
        type: GoogleDataType,
        windowStart: Date,
        windowEnd: Date
    ) async throws(HealthKitWriterError) {}

    nonisolated public func drainDeferredSessionLinks(for type: GoogleDataType) async -> [String: UUID] { [:] }

    nonisolated public func drainSuppressedCount(for type: GoogleDataType) async -> Int { 0 }
}

/// P0 default (WP-09): identity. WP-12b installs the real watch-priority
/// resolver in this exact seam (architecture.md D13) without `SyncEngine`'s
/// structure changing at all.
nonisolated public struct IdentityConflictFilter: ConflictFiltering {
    public init() {}
    public func resolve(_ mapped: MappedObject, for point: GoogleDataPoint) async -> MappedObject {
        mapped
    }
    // Explicit (not defaulted): identity records no links and suppresses
    // nothing, so the drains are honest zeros -- written out so a future
    // reader sees the conformance is complete, not inherited.
    public func drainDeferredSessionLinks(for type: GoogleDataType) async -> [String: UUID] { [:] }
    public func drainSuppressedCount(for type: GoogleDataType) async -> Int { 0 }
}

// MARK: - Per-type sync result (WP-09 step 3: syncAll's per-type report)

/// `SyncState.lastStatus`'s in-memory counterpart -- see that model's doc
/// comment (`"idle" | "ok" | "error" | "cancelled"`); `SyncEngine` never
/// writes `"idle"` itself (that's the model's own default for a type never
/// yet synced).
nonisolated public enum SyncStatus: String, Sendable, Equatable, Codable {
    case ok
    case error
    /// The run was cancelled (task cancellation / `.cancelled` from the
    /// data client) before finishing: a stop, not a failure. Pipelines
    /// persist this WITHOUT an error message so the dashboard never shows
    /// a red row for the system winding the run down; the cursor is
    /// untouched and the next run retries the same window.
    case cancelled
}

/// One type's outcome from `SyncEngine.sync(type:)`/`.syncAll(types:)` (WP-09
/// step 3: "collecting a per-type result report").
nonisolated public struct SyncOutcome: Sendable, Equatable {
    public var dataType: GoogleDataType
    public var status: SyncStatus
    /// Items processed *this run* -- see `SyncEngine`'s doc comment for
    /// exactly what counts. Reported even on failure (partial progress up to
    /// the page that failed), though only a fully-successful run's count is
    /// added to the persisted `SyncState.itemCount`.
    public var itemCount: Int
    /// WP-12b: data points suppressed this run in favor of Apple Watch data
    /// (architecture.md D13.3's stream suppression + D13.2's deferred
    /// sessions, drained from the run's `ConflictFiltering`). Rendered in
    /// the sync log as "deferred to Apple Watch" (test-plan.md §2.3).
    /// Defaults to 0 so every pre-WP-12b construction site compiles and
    /// behaves identically.
    public var suppressedCount: Int
    public var errorMessage: String?

    public init(
        dataType: GoogleDataType,
        status: SyncStatus,
        itemCount: Int,
        suppressedCount: Int = 0,
        errorMessage: String? = nil
    ) {
        self.dataType = dataType
        self.status = status
        self.itemCount = itemCount
        self.suppressedCount = suppressedCount
        self.errorMessage = errorMessage
    }
}
