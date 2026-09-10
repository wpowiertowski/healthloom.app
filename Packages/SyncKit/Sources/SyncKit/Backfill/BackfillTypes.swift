// BackfillTypes.swift
//
// WP-15 (implementation-plan.md) / architecture.md §4 D5: pure, HealthKit-free
// types `BackfillCoordinator` (BackfillCoordinator.swift, `#if
// canImport(HealthKit)` like `SyncEngine.swift`) is built on -- the same
// pure/impure split every prior SyncKit WP established (SyncEngineTypes.swift
// is the closest sibling; this file mirrors its shape and doc-comment
// lineage deliberately). Everything here compiles on any platform `swift
// test` runs on and is `nonisolated`/nonisolated-protocol throughout so it
// never needs an actor hop from `actor BackfillCoordinator` to read/call.

import CoreModel
import Foundation
import GoogleHealthClient

// MARK: - User-chosen backfill horizon (architecture.md D5)

/// How far back a historical backfill should walk, per architecture.md D5:
/// "First connect offers a backfill range (90 days default; 30 d / 90 d /
/// 1 y / all)". `.all` has no fixed duration -- see `BackfillHorizon
/// .allTimeFloor` below for how a walk terminates anyway.
public nonisolated enum BackfillHorizon: String, Sendable, Equatable, CaseIterable, Codable {
    case days30
    case days90
    case year1
    case all

    /// Architecture.md D5's stated default.
    public static let defaultHorizon: BackfillHorizon = .days90

    /// How far back from "now" this horizon reaches; `nil` for `.all`
    /// (unbounded -- resolved against `allTimeFloor` by whoever needs an
    /// actual `Date`, e.g. `BackfillCoordinator.horizonDate(now:)`).
    public var duration: TimeInterval? {
        switch self {
        case .days30: return 30 * 24 * 3600
        case .days90: return 90 * 24 * 3600
        case .year1: return 365 * 24 * 3600
        case .all: return nil
        }
    }

    /// A fixed, practical "beginning of time" floor for `.all` (the Unix
    /// epoch) -- Google Health API data cannot predate a user's device
    /// history, so this is simply a bound guaranteed to terminate the
    /// backward walk in a finite number of chunks rather than an actual
    /// claim about data existing that far back. Documented here, not
    /// invented ad hoc at each call site.
    public static let allTimeFloor = Date(timeIntervalSince1970: 0)

    /// The concrete boundary date this horizon reaches, relative to `now`.
    public nonisolated func horizonDate(now: Date) -> Date {
        guard let duration else { return Self.allTimeFloor }
        return now.addingTimeInterval(-duration)
    }

    /// Ordering by "how much history this horizon covers" -- `.all` is
    /// always the deepest, everything else compares by `duration`. Used to
    /// decide whether a newly chosen horizon is an *extension* of (or
    /// no-op relative to) a previously completed one (WP-15 step 3:
    /// "extending re-opens the walk").
    public nonisolated func coversAtLeastAsMuchHistoryAs(_ other: BackfillHorizon) -> Bool {
        switch (self, other) {
        case (.all, _): return true
        case (_, .all): return self == .all
        default: return (duration ?? 0) >= (other.duration ?? 0)
        }
    }
}

// MARK: - Chunking / throttling configuration

/// Sizing knobs for the backward walk (WP-15 step 1: "~30-day chunks",
/// "inter-chunk delay for API quota"). A pure value type, mirroring
/// `SyncConfiguration`'s own shape (SyncEngineTypes.swift).
public nonisolated struct BackfillConfiguration: Sendable, Equatable {
    /// Chunk size for the backward walk. WP-15: "~30-day chunks".
    public var chunkDuration: TimeInterval
    /// Delay between chunks/rounds, real production quota throttling --
    /// injected via `BackoffSleeper` (GoogleHealthClient's own seam, reused
    /// here rather than inventing a parallel one -- see this package's
    /// `BackfillCoordinator.swift` header for why).
    public var interChunkDelay: TimeInterval

    public init(chunkDuration: TimeInterval = 30 * 24 * 3600, interChunkDelay: TimeInterval = 2.0) {
        self.chunkDuration = chunkDuration
        self.interChunkDelay = interChunkDelay
    }
}

// MARK: - Horizon-completion side-store (see this file's header note + BackfillCoordinator.swift)

/// **Gap flagged per the handoff protocol's "if you find you truly need a
/// new field, document it instead of editing CoreModel" clause:** ideally
/// `SyncState` would carry a second field alongside `backfillCursor` --
/// something like `completedBackfillHorizon: String?` -- recording *which*
/// horizon a `nil` cursor's completion refers to. `CoreModel` is out of this
/// WP's scope, so this small side-store fills exactly that one gap: it
/// answers "has this type's backfill already reached at least horizon H?"
/// without touching `SyncState`'s literal contract (`backfillCursor`'s own
/// doc comment: "nil = backfill hasn't started or has completed to the
/// chosen horizon" -- `BackfillCoordinator` honors that literally, setting
/// the cursor to `nil` on completion, and uses *this* store, not the cursor,
/// to remember which horizon "completed" means). See
/// `BackfillCoordinator.swift`'s header for the full resume-logic writeup.
///
/// Deliberately not SwiftData/CoreModel: this is booking-keeping the app
/// owns, analogous to WP-17's own "persist toggles in `UserDefaults`"
/// instruction for its unrelated settings -- a plain key-value fact, not a
/// modeled relationship, and nothing else in the schema needs to query it.
nonisolated public protocol BackfillHorizonRecordStore: Sendable {
    /// The deepest horizon this type's backfill has *fully completed*, or
    /// `nil` if it has never completed one (never started, or currently
    /// mid-walk). `nonisolated`, matching every other protocol seam in this
    /// package (`GoogleReconcileClient`, `SyncClock`, `ConflictFiltering`)
    /// so a conforming type's own actor affinity (or lack of one) never
    /// blocks satisfying the requirement -- see SyncEngineTypes.swift's
    /// header for the same rationale applied there.
    nonisolated func completedHorizon(for type: GoogleDataType) -> BackfillHorizon?
    /// Records that `type`'s backfill has fully completed `horizon` (or
    /// clears the record when `nil` -- not currently used by
    /// `BackfillCoordinator` but kept for symmetry/testability).
    nonisolated func setCompletedHorizon(_ horizon: BackfillHorizon?, for type: GoogleDataType)
}

/// Production store: one `UserDefaults` key per type, namespaced under
/// `com.healthloom.backfill.completedHorizon.*` (mirrors this app's existing
/// `com.healthloom.*` identifier convention, architecture.md's naming
/// section).
/// `@unchecked Sendable`: `UserDefaults` doesn't declare `Sendable` itself,
/// but it is Apple-documented as thread-safe for exactly this get/set-by-key
/// usage (the same "known-safe, not statically provable" posture this
/// package already applies to `MockHealthStore`, test target).
nonisolated public final class UserDefaultsBackfillHorizonRecordStore: BackfillHorizonRecordStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(for type: GoogleDataType) -> String {
        "com.healthloom.backfill.completedHorizon.\(type.rawValue)"
    }

    public func completedHorizon(for type: GoogleDataType) -> BackfillHorizon? {
        guard let raw = defaults.string(forKey: key(for: type)) else { return nil }
        return BackfillHorizon(rawValue: raw)
    }

    public func setCompletedHorizon(_ horizon: BackfillHorizon?, for type: GoogleDataType) {
        let k = key(for: type)
        if let horizon {
            defaults.set(horizon.rawValue, forKey: k)
        } else {
            defaults.removeObject(forKey: k)
        }
    }
}

// MARK: - Foreground-sync busy probe (WP-15 step 2)

/// WP-15 step 2: "suspends when a foreground incremental sync is active for
/// a type". A narrow protocol over `SyncEngine.isBusy(for:)`
/// (SyncEngine.swift's new, additive method -- see that file's doc comment
/// for the coordination note) -- mirrors `GoogleReconcileClient`'s own
/// "narrow protocol over the real thing so tests can stub it" pattern
/// (SyncEngineTypes.swift).
nonisolated public protocol BackfillBusyProbe: Sendable {
    nonisolated func isBusy(for type: GoogleDataType) async -> Bool
}

/// Default when no real `SyncEngine` is wired in (e.g. previews, or a
/// deployment that runs backfill before any incremental sync exists):
/// nothing is ever busy, so backfill never suspends for this reason.
nonisolated public struct AlwaysAvailableBusyProbe: BackfillBusyProbe {
    public init() {}
    public func isBusy(for type: GoogleDataType) async -> Bool { false }
}

// MARK: - Per-chunk / per-round outcomes (WP-15 "Tests" line support)

/// What happened when `BackfillCoordinator` tried to advance one type by one
/// chunk (`BackfillCoordinator.runNextChunk(for:)`).
public nonisolated enum BackfillChunkOutcome: Sendable, Equatable {
    /// A chunk was pulled, mapped, and written/upserted; `window` is the
    /// exact `[start, end)` walked (chunk-boundary tests assert on this),
    /// `itemCount` is this chunk's processed-point count (same counting rule
    /// as `SyncEngine.itemCount` -- see that file's doc comment).
    case processedChunk(window: ClosedRange<Date>, itemCount: Int)
    /// This type's backfill was already caught up to (at least) the
    /// currently-chosen horizon -- nothing to do.
    case alreadyDone
    /// Skipped this round: a foreground/background incremental sync is
    /// currently in-flight for this type (`BackfillBusyProbe`).
    case suspendedBusy
    /// Skipped this round: the coordinator is paused (WP-15 step 3: "pause/
    /// resume controls").
    case suspendedPaused
    /// Stopped mid-chunk by task cancellation (NOT a failure): no error
    /// status persisted, cursor left at the last durable save, retried next
    /// round. Lets callers and the log tell "asked to stop" apart from a
    /// real chunk failure.
    case suspendedCancelled
    /// Skipped this round: the type is currently disabled in Settings
    /// (round-4-sync item 4 — the background/backfill paths honor the
    /// same `filteredForSync` toggles as the foreground sync). Distinct
    /// from `.alreadyDone` (which means "caught up"): re-enabling the
    /// type resumes its walk from the untouched cursor.
    case suspendedDisabled
    /// The chunk's pull/map/write failed; the type's `backfillCursor` is
    /// left untouched (same "leave the cursor, retry next time" posture as
    /// `SyncEngine`'s incremental cursor -- architecture.md D3/D4's
    /// idempotency makes a retry safe).
    case failed(String)
}

/// Live progress snapshot for one type, computed from `SyncState` +
/// `BackfillHorizonRecordStore` + the currently-chosen horizon (never cached
/// separately -- avoids a second source of truth drifting from `SyncState`,
/// the same "derive, don't duplicate" posture `Routing/ClinicalClassification
/// .swift` documents for its own, unrelated derivation).
public nonisolated struct BackfillTypeStatus: Sendable, Equatable {
    public var dataType: GoogleDataType
    /// The earliest point this type's backfill has reached so far, or `nil`
    /// if it has never started. When `isComplete` is `true`, this reflects
    /// the boundary actually reached (which may be older than the *current*
    /// horizon if the user later narrowed their choice -- narrowing never
    /// deletes already-imported history, per WP-15's UI note that horizon
    /// changes only ever *extend*, never retract, per architecture.md D5's
    /// framing of backfill as one-directional history import).
    public var reachedDate: Date?
    /// The boundary date the *current* horizon selection targets.
    public var horizonDate: Date
    public var isComplete: Bool
    public var lastError: String?

    public init(dataType: GoogleDataType, reachedDate: Date?, horizonDate: Date, isComplete: Bool, lastError: String?) {
        self.dataType = dataType
        self.reachedDate = reachedDate
        self.horizonDate = horizonDate
        self.isComplete = isComplete
        self.lastError = lastError
    }
}
