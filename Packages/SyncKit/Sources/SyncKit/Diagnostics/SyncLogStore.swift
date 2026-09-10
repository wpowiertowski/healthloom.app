// SyncLogStore.swift
//
// WP-18 (implementation-plan.md): "ring-buffer log (SwiftData or file) of
// sync runs -- timestamps, types, counts, error strings... Explicitly a
// ring buffer with a capped size (document the cap and eviction policy)."
//
// **Cap and eviction policy, as required to be documented:** `capacity`
// defaults to 500 entries, evicted strict-FIFO -- once appending would push
// the count past `capacity`, the *oldest* entries are removed first (via
// `removeFirst(overflow)`), never a size-based/random/LRU policy. 500 was
// sized against this app's own worst-case emission rate: one entry per
// `GoogleDataType` per completed `SyncEngine.sync(type:)` run
// (`SyncRunRecording.swift`), roughly 26 syncable types (CoreModel's
// non-`.skip` `GoogleDataType` count -- see `AppEnvironment.backfillTypes`'s
// identical derivation), triggered at most every ~15 minutes
// (`BackgroundSyncConfiguration.minInterval`, BackgroundSync/
// BackgroundSyncPlanner.swift) plus occasional manual "Sync Now" taps -- 500
// entries covers several days of continuous per-type activity before the
// oldest entries roll off, comfortably enough for a support conversation
// ("what happened in the last day or two") without the backing file growing
// unbounded.
import Foundation

/// In-memory ring buffer of `SyncLogEntry` values, mirrored to disk via an
/// injected `SyncLogPersisting` (production: `FileSyncLogPersistence`;
/// tests/previews: `NullSyncLogPersistence` or a scripted fake). An `actor`
/// -- like every other piece of shared, mutable state in this package
/// (`SyncEngine`, `BackfillCoordinator`) -- so concurrent recordings from
/// multiple in-flight `SyncEngine.sync(type:)` calls serialize safely with
/// no external locking.
public actor SyncLogStore {
    public static let defaultCapacity = 500

    private let capacity: Int
    private let persistence: any SyncLogPersisting
    private var entries: [SyncLogEntry]

    public init(capacity: Int = SyncLogStore.defaultCapacity, persistence: any SyncLogPersisting = FileSyncLogPersistence()) {
        self.capacity = capacity
        self.persistence = persistence
        var loaded = persistence.load()
        if loaded.count > capacity {
            loaded.removeFirst(loaded.count - capacity)
        }
        self.entries = loaded
    }

    /// Appends one entry, evicting the oldest entries first if `capacity` is
    /// now exceeded (strict FIFO -- see this file's header for the sizing
    /// rationale). Persists the post-eviction array on every append so a
    /// killed app never loses more than the in-flight entry.
    public func append(_ entry: SyncLogEntry) {
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        persistence.save(entries)
    }

    /// Chronological (oldest-first) order, optionally windowed to the
    /// `limit` most-recent entries. Callers that want newest-first display
    /// order (the Settings viewer, `SyncLogView.swift`) reverse this
    /// themselves -- kept in insertion order here so capping/ordering
    /// assertions in tests read naturally ("last element is the newest").
    /// A non-positive `limit` returns `[]` (round-7 item 11): `suffix`
    /// traps on negatives, and an empty window is empty — never the
    /// whole log (same contract as `PromptManager.history(limit:)`).
    public func recentEntries(limit: Int? = nil) -> [SyncLogEntry] {
        guard let limit else { return entries }
        guard limit > 0 else { return [] }
        guard limit < entries.count else { return entries }
        return Array(entries.suffix(limit))
    }

    /// Entries currently held (test/UI convenience -- e.g. capping
    /// assertions, an "N entries" footer in the viewer).
    public func count() -> Int { entries.count }

    /// Clears every entry (both in-memory and on disk). Not exposed in the
    /// viewer UI in this WP (no "clear log" button was in the brief), but a
    /// small, harmless, testable primitive kept for completeness/future use
    /// -- mirroring `BackfillHorizonRecordStore.setCompletedHorizon(nil:)`'s
    /// own "kept for symmetry" precedent (Backfill/BackfillTypes.swift).
    public func clear() {
        entries = []
        persistence.save(entries)
    }
}
