// WatchCoverage.swift
//
// WP-12b (implementation-plan.md) / architecture.md D13: the pure,
// HealthKit-free heart of watch-priority conflict resolution -- coverage
// windows, the overlap-classification policy, and the stream
// suppress/split/keep decision. Follows the pure/impure split every prior
// SyncKit WP established (MappedDecision vs MappedObject, WP-07;
// HealthKitIdentifierClassifier vs HealthKitObjectTypeResolver, WP-06):
// everything in this file is plain Swift values, fully unit-testable on any
// platform `swift test` runs on. The HealthKit-touching pieces live in
// `WatchCoverageProvider.swift` (querying real watch workouts) and
// `WatchConflictResolver.swift` (the `ConflictFiltering` conformer installed
// in `SyncEngine`'s WP-09 seam).
//
// `nonisolated` throughout, mirroring SyncEngineTypes.swift's own posture
// (and commit-precedent from the Xcode 27 beta's stricter conformance-
// isolation enforcement: protocols and pure value types in this package are
// declared `nonisolated` explicitly, never left to the package's
// `.defaultIsolation(MainActor.self)` inference).

import Foundation

// MARK: - Coverage window

/// One workout already in Apple Health (not written by HealthLoom), as
/// discovered by a `WatchCoverageProviding` conformer (architecture.md
/// D13.1; widened beyond Apple Watch by WP-55). `start`/`end`
/// are the workout's **own, unpadded** bounds -- D13.2's session-overlap
/// classification compares against these directly, while D13.3's stream
/// suppression uses the ±`WatchConflictPolicy.coveragePadding` padded form
/// (`WatchCoverageIndex` applies the padding; it is never baked into this
/// struct, so the two rules can't drift onto the wrong bounds).
nonisolated public struct WatchCoverageWindow: Sendable, Hashable {
    /// The watch workout's `HKWorkout.uuid` -- what
    /// `LocalSample.linkedWatchWorkoutUUID` links a deferred Fitbit session
    /// to (architecture.md D13.2).
    public var workoutUUID: UUID
    public var start: Date
    public var end: Date
    public var source: Source

    /// What recorded the workout, which decides how much it wins (WP-55).
    public enum Source: Sendable, Hashable {
        /// An Apple Watch: it also measured heart rate, steps, energy and
        /// distance throughout, so it wins the session (D13.2) AND those
        /// streams (D13.3).
        case appleWatch
        /// Another app that saves workouts to Apple Health (a Hydrow
        /// rower, iPhone Fitness...). The session is already there, but
        /// its streams may not be -- Hydrow saves no continuous heart
        /// rate -- so it wins the session only, and Fitbit's streams
        /// still fill Apple Health.
        case otherApp
    }

    public init(workoutUUID: UUID, start: Date, end: Date, source: Source = .appleWatch) {
        self.workoutUUID = workoutUUID
        self.start = start
        self.end = end
        self.source = source
    }
}

// MARK: - Policy constants (architecture.md §7.3: tune during beta)

/// D13's overlap thresholds, kept in one value type (architecture.md open
/// question 3 says these are beta-tuning constants -- one place to tune).
nonisolated public struct WatchConflictPolicy: Sendable, Equatable {
    /// D13.1: coverage windows are padded ±5 min for stream suppression.
    public var coveragePadding: TimeInterval
    /// D13.2: a session overlapping a watch workout by ≥ this fraction of
    /// the *shorter* of the two durations defers to the watch.
    public var sessionOverlapFraction: Double
    /// D13.2's other trigger: session start *and* end each within this
    /// tolerance of the workout's own start/end.
    public var sessionStartEndTolerance: TimeInterval

    public init(
        coveragePadding: TimeInterval = 5 * 60,
        sessionOverlapFraction: Double = 0.5,
        sessionStartEndTolerance: TimeInterval = 10 * 60
    ) {
        self.coveragePadding = coveragePadding
        self.sessionOverlapFraction = sessionOverlapFraction
        self.sessionStartEndTolerance = sessionStartEndTolerance
    }

    public static let `default` = WatchConflictPolicy()
}

// MARK: - Stream resolution result

/// One kept sub-interval of a split cumulative sample (`StreamResolution
/// .split`). Plain dates, no `DateInterval` -- avoids depending on that
/// type's `Sendable` status across SDK versions and keeps this file's
/// vocabulary self-contained.
nonisolated public struct StreamSlice: Sendable, Hashable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// D13.3's per-sample decision for a watch-covered stream type.
nonisolated public enum StreamResolution: Sendable, Equatable {
    /// No padded coverage window touches this sample -- import normally.
    case keep
    /// The sample falls (fully, or partially for an instantaneous type)
    /// inside padded coverage -- do not write; the watch already recorded
    /// this window at higher fidelity. Counted in the sync log as
    /// "deferred to Apple Watch" (test-plan.md §2.3 bookkeeping row).
    case suppress
    /// A *cumulative* interval sample partially overlaps coverage: write
    /// only these outside-coverage slices, each with its value pro-rated by
    /// duration (test-plan.md §2.3: "split at window edges with value
    /// pro-rated"). Never produced for instantaneous types (those get
    /// `.suppress` at the edge instead) and never empty.
    case split([StreamSlice])
}

// MARK: - Coverage index

/// The per-sync-run index of watch coverage (architecture.md D13.1) plus the
/// two pure classification rules built on it: session-level deferral (D13.2)
/// and stream-level suppress/split (D13.3). Constructed once per run by
/// `WatchConflictResolver.beginRun` from whatever windows the injected
/// `WatchCoverageProviding` returned -- all methods here are pure functions
/// of `windows` + `policy`, which is what makes the whole truth table
/// unit-testable with injected windows (the simulator cannot fake an Apple
/// Watch source; test-plan.md §2.3's explicit instruction).
nonisolated public struct WatchCoverageIndex: Sendable, Equatable {
    /// Sorted by `start`.
    public let windows: [WatchCoverageWindow]
    public let policy: WatchConflictPolicy

    /// Padded (±`policy.coveragePadding`) Apple Watch window spans, merged
    /// where padding makes neighbors overlap or touch -- so back-to-back
    /// watch workouts behave as one continuous covered span for stream
    /// math, and split slices can never fall into the sliver between two
    /// adjacent windows. `.otherApp` windows never enter it: they win
    /// sessions, not streams (WP-55).
    private let mergedPaddedSpans: [StreamSlice]

    public init(windows: [WatchCoverageWindow], policy: WatchConflictPolicy = .default) {
        let sorted = windows.sorted { $0.start < $1.start }
        self.windows = sorted
        self.policy = policy
        self.mergedPaddedSpans = Self.mergePaddedSpans(
            sorted.filter { $0.source == .appleWatch }, padding: policy.coveragePadding
        )
    }

    public var isEmpty: Bool { windows.isEmpty }

    /// Whether any window suppresses streams -- i.e. at least one Apple
    /// Watch workout (WP-55: other-app workouts win sessions only).
    public var coversStreams: Bool { !mergedPaddedSpans.isEmpty }

    // MARK: Session rule (D13.2)

    /// The Apple Health workout (watch or other app) an incoming Google
    /// Exercise session defers to, or `nil` if the session stands on its own (Fitbit-only workout --
    /// architecture.md §6: "no coverage window ⇒ full Fitbit session imports
    /// as HKWorkout").
    ///
    /// Matches when **either** holds against a window's unpadded bounds:
    ///   - overlap duration ≥ `sessionOverlapFraction` × the shorter of the
    ///     two durations (a zero-length shorter duration can never satisfy
    ///     this rule -- it falls through to the tolerance rule), or
    ///   - |Δstart| ≤ `sessionStartEndTolerance` **and** |Δend| ≤ the same
    ///     (both ends, not just one -- test-plan.md §2.3's truth-table row).
    /// With several candidates (back-to-back watch workouts spanned by one
    /// long Fitbit auto-detected session), the earliest matching window wins
    /// -- deterministic, and the consolidated Activities entry links to the
    /// activity the session most plausibly began as.
    public func matchingWorkout(forSessionStart start: Date, end: Date) -> WatchCoverageWindow? {
        guard end > start else { return nil }
        let sessionDuration = end.timeIntervalSince(start)
        for window in windows {
            let overlap = max(0, min(end, window.end).timeIntervalSince(max(start, window.start)))
            let shorter = min(sessionDuration, window.end.timeIntervalSince(window.start))
            if shorter > 0, overlap >= policy.sessionOverlapFraction * shorter {
                return window
            }
            if abs(start.timeIntervalSince(window.start)) <= policy.sessionStartEndTolerance,
               abs(end.timeIntervalSince(window.end)) <= policy.sessionStartEndTolerance {
                return window
            }
        }
        return nil
    }

    // MARK: Stream rule (D13.3)

    /// Suppress/split/keep for one stream sample's interval, against the
    /// merged **padded** Apple Watch coverage spans (other-app workouts
    /// never suppress streams). `cumulative: true` for types whose
    /// value distributes over the interval (steps, distance, active energy
    /// -- splittable with pro-rating); `false` for instantaneous readings
    /// (heart rate -- a partial overlap is dropped whole, there is nothing
    /// meaningful to pro-rate).
    ///
    /// Zero-duration samples (`start == end`, e.g. spot heart-rate readings)
    /// are suppressed when the instant lies within a padded span (boundary
    /// inclusive) and kept otherwise.
    public func resolveStream(start: Date, end: Date, cumulative: Bool) -> StreamResolution {
        guard !mergedPaddedSpans.isEmpty else { return .keep }

        if end <= start {
            // Instant (or degenerate) sample: containment check only.
            let covered = mergedPaddedSpans.contains { start >= $0.start && start <= $0.end }
            return covered ? .suppress : .keep
        }

        if mergedPaddedSpans.contains(where: { start >= $0.start && end <= $0.end }) {
            return .suppress
        }

        let overlapping = mergedPaddedSpans.filter { $0.start < end && $0.end > start }
        guard !overlapping.isEmpty else { return .keep }
        guard cumulative else { return .suppress }

        // Subtract the (already sorted, disjoint) covered spans from
        // [start, end]; whatever remains is written, pro-rated by the caller.
        var slices: [StreamSlice] = []
        var cursor = start
        for span in overlapping {
            if span.start > cursor {
                slices.append(StreamSlice(start: cursor, end: span.start))
            }
            cursor = max(cursor, span.end)
        }
        if cursor < end {
            slices.append(StreamSlice(start: cursor, end: end))
        }
        // Merged spans are disjoint and none contains [start, end] fully
        // (checked above), so at least one gap always survives; the guard is
        // pure defense.
        return slices.isEmpty ? .suppress : .split(slices)
    }

    /// Whether `[start, end]` touches any padded coverage span at all --
    /// D13.4's retroactive-cleanup test: an app-written stream sample that
    /// now intersects coverage is deleted and re-resolved on the same run's
    /// re-pull (which then suppresses or splits it correctly).
    public func intersectsPaddedCoverage(start: Date, end: Date) -> Bool {
        if end <= start {
            return mergedPaddedSpans.contains { start >= $0.start && start <= $0.end }
        }
        return mergedPaddedSpans.contains { $0.start < end && $0.end > start }
    }

    // MARK: Private

    private static func mergePaddedSpans(_ sorted: [WatchCoverageWindow], padding: TimeInterval) -> [StreamSlice] {
        var merged: [StreamSlice] = []
        for window in sorted {
            let padded = StreamSlice(
                start: window.start.addingTimeInterval(-padding),
                end: window.end.addingTimeInterval(padding)
            )
            if var last = merged.last, padded.start <= last.end {
                last.end = max(last.end, padded.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(padded)
            }
        }
        return merged
    }
}

// MARK: - Coverage source seam

/// Async source of coverage windows for a date range (architecture.md
/// D13.1): Apple Watch workouts, and since WP-55 every other workout in
/// Apple Health that HealthLoom didn't write, each tagged with its
/// `WatchCoverageWindow.Source`. Production: `HealthKitWatchCoverageProvider`
/// (WatchCoverageProvider.swift), which queries HealthKit and classifies
/// workout sources behind `WorkoutSourceClassifier`. Tests inject a stub
/// returning fixed windows -- the simulator cannot fake a watch source, so
/// this seam is exactly where test-plan.md §2.3 says injection happens.
nonisolated public protocol WatchCoverageProviding: Sendable {
    nonisolated func watchWorkoutWindows(start: Date, end: Date) async throws -> [WatchCoverageWindow]
}
