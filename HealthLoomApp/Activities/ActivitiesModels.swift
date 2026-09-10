// ActivitiesModels.swift
//
// WP-12b (implementation-plan.md) step 5 / architecture.md D13.2: the pure
// data shapes + consolidation logic behind the Activities view -- one entry
// per real-world activity: a watch workout is primary with its linked
// Fitbit session's fields inline as a supplement ("supplement, never
// duplicate"), a Fitbit-only workout (imported by HealthLoom as an
// `HKWorkout`) is a full entry of its own, and a deferred Fitbit session
// whose watch workout isn't readable (read access denied, or the workout
// was deleted from Apple Health after deferral) still renders standalone
// rather than vanishing.
//
// Everything in this file is HealthKit-free on purpose: `WorkoutSummary` is
// built *from* `HKWorkout` by `ActivitiesProvider` (the one HealthKit-
// touching file in this folder), so `consolidate(_:supplements:)` and the
// `LocalSample` payload decoding are plain-value logic `HealthLoomTests`
// can drive without an HK store -- the same pure/impure split SyncKit uses
// throughout (MappedDecision vs MappedObject, WatchCoverageIndex vs
// WatchCoverageProvider).

import CoreModel
import Foundation

/// One HealthKit workout, reduced to what the Activities view renders.
struct WorkoutSummary: Identifiable, Hashable {
    let uuid: UUID
    let activityName: String
    let start: Date
    let end: Date
    /// `HKSource.name` -- e.g. "Workout" (Apple's watch app), "HealthLoom".
    let sourceName: String
    /// This app wrote it (external-ID metadata present) ⇒ an imported
    /// Fitbit-only activity, not a watch recording.
    let isHealthLoomImport: Bool
    /// Source device is an Apple Watch (same classification rule as
    /// SyncKit's `ProductTypeWorkoutSourceClassifier`).
    let isAppleWatch: Bool

    var id: UUID { uuid }
}

/// One `.exercise` `LocalSample` row (a Fitbit session WP-12b's resolver
/// deferred to a watch workout, architecture.md D13.2), decoded to what the
/// Activities view renders.
struct FitbitActivitySupplement: Identifiable, Hashable {
    let externalID: String
    let start: Date
    let end: Date
    /// Human-readable source label ("Fitbit Air").
    let source: String
    let linkedWatchWorkoutUUID: UUID?
    let activityName: String?
    let distanceMeters: Double?
    let energyKilocalories: Double?

    var id: String { externalID }

    /// Decodes via the shared `LocalSample.decodedExercisePayload` (CoreModel
    /// -- code review 2026-08-28 finding #14: this was a hand-duplicated copy
    /// of the same decode contract CoachKit's `KnowledgeStore` also needs;
    /// both now call the one shared implementation). Every level degrades to
    /// `nil` rather than failing -- the row still renders with dates and
    /// source alone.
    init(sample: LocalSample) {
        self.externalID = sample.externalID
        self.start = sample.start
        self.end = sample.end
        self.source = sample.source
        self.linkedWatchWorkoutUUID = sample.linkedWatchWorkoutUUID

        let fields = sample.decodedExercisePayload
        self.activityName = fields.activityName
        self.distanceMeters = fields.distanceMeters
        self.energyKilocalories = fields.energyKilocalories
    }
}

/// One consolidated Activities-view entry (architecture.md D13.2's "one
/// consolidated activity").
struct ActivityEntry: Identifiable, Hashable {
    enum Kind: Hashable {
        /// A workout read from HealthKit -- watch-recorded, or a Fitbit-only
        /// activity HealthLoom itself imported.
        case workout(WorkoutSummary)
        /// A deferred Fitbit session whose linked watch workout wasn't
        /// among the readable workouts (see this file's header) -- rendered
        /// standalone so the activity never silently disappears.
        case unlinkedFitbitSession
    }

    let id: String
    let kind: Kind
    let title: String
    let start: Date
    let end: Date
    /// "Apple Watch · Workout", "Fitbit Air", ...
    let sourceLabel: String
    /// The linked Fitbit session's fields, shown inline under a watch
    /// workout ("+ 8.0 km · 520 kcal · Fitbit Air") -- D13.2's supplement,
    /// never a second entry.
    let supplement: FitbitActivitySupplement?

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

enum ActivityConsolidator {
    /// One entry per activity: every readable workout becomes an entry, with
    /// any `LocalSample` session linked to its UUID attached as the inline
    /// supplement; sessions linked to no readable workout become standalone
    /// entries. Newest first.
    static func consolidate(
        workouts: [WorkoutSummary],
        supplements: [FitbitActivitySupplement]
    ) -> [ActivityEntry] {
        var supplementsByWorkoutUUID: [UUID: FitbitActivitySupplement] = [:]
        var unlinked: [FitbitActivitySupplement] = []
        for supplement in supplements {
            if let uuid = supplement.linkedWatchWorkoutUUID {
                // One supplement per workout; a duplicate link (shouldn't
                // happen -- external IDs are unique) keeps the first.
                if supplementsByWorkoutUUID[uuid] == nil {
                    supplementsByWorkoutUUID[uuid] = supplement
                } else {
                    unlinked.append(supplement)
                }
            } else {
                unlinked.append(supplement)
            }
        }

        var entries: [ActivityEntry] = workouts.map { workout in
            // Always consume AND always attach: the link is ground truth
            // (the resolver matched this session to a real watch workout
            // by coverage), while `isAppleWatch` is a source-name heuristic
            // that diverges from the classifier whenever `productType` is
            // nil at read time. Gating the attach on the heuristic dropped
            // the "+ 8.0 km" detail row exactly when the link was real.
            let supplement = supplementsByWorkoutUUID.removeValue(forKey: workout.uuid)
            let sourceLabel = workout.isAppleWatch
                ? "Apple Watch \u{00B7} \(workout.sourceName)"
                : workout.sourceName
            return ActivityEntry(
                id: workout.uuid.uuidString,
                kind: .workout(workout),
                title: workout.activityName,
                start: workout.start,
                end: workout.end,
                sourceLabel: sourceLabel,
                supplement: supplement
            )
        }

        // Whatever's left points at a workout we couldn't read -- surface it
        // standalone (header note). Supplements consumed above are gone from
        // the dictionary; ones never consumed join the unlinked list.
        unlinked.append(contentsOf: supplementsByWorkoutUUID.values)
        entries.append(contentsOf: unlinked.map { supplement in
            ActivityEntry(
                id: supplement.externalID,
                kind: .unlinkedFitbitSession,
                title: supplement.activityName ?? "Activity",
                start: supplement.start,
                end: supplement.end,
                sourceLabel: supplement.source,
                supplement: nil
            )
        })

        // Round-7 item 12: deterministic tiebreak. `supplementsByWorkoutUUID`
        // iterates in per-process hash order, so equal-start entries
        // reordered across launches (snapshot flake — the same
        // nondeterminism `KnowledgeStore` sorted away at :359-361).
        // Start dominates; external ID breaks ties, deterministically.
        return entries.sorted {
            if $0.start != $1.start { return $0.start > $1.start }
            return $0.id > $1.id
        }
    }

    /// Chronological day grouping for the view's sections (D13.2's
    /// "chronological, grouped by day"), newest day first.
    static func groupedByDay(
        _ entries: [ActivityEntry],
        calendar: Calendar = .current
    ) -> [(day: Date, entries: [ActivityEntry])] {
        let grouped = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.start) }
        return grouped
            .map { (day: $0.key, entries: $0.value.sorted { $0.start > $1.start }) }
            .sorted { $0.day > $1.day }
    }
}
