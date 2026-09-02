// LocalSamplePayloadDecoding.swift
//
// WP-19 (implementation-plan.md) step 1: `LocalSample` (AZM; clinical types
// only produce `isClinical` fields) + architecture.md D13.6 (merge linked
// Fitbit supplements, never describing both copies of one activity).
//
// `LocalSample.payloadJSON`'s wire shape has no shared/public schema
// (CoreModel deliberately keeps it opaque `Data` -- LocalSample.swift's own
// header). `SyncEngine`/`BackfillCoordinator` each encode it via a private,
// file-local `Codable` struct (`{id, dataType, start, end, values,
// sessionPayload, sourcePlatform, sourceDeviceDisplayName,
// sourceRecordingMethod}` -- `SyncEngine.swift`'s `SyncEngineLocalPayload`).
//
// Code review (2026-08-28) finding #14: the *decode* side (as opposed to the
// unavoidably-duplicated encode side) has one shared implementation now --
// `LocalSample.decodedExercisePayload` (CoreModel) -- rather than a second,
// independently-maintained copy of the app target's `ActivitiesModels
// .FitbitActivitySupplement`'s decoder for the identical wire shape.

import CoreModel
import Foundation

/// A `.exercise`-type `LocalSample`'s decoded Fitbit fields -- a session
/// WP-12b's resolver deferred to a linked Apple Watch workout (architecture.md
/// D13.2). `nil` `activityName`/`distanceMeters`/`energyKilocalories` means
/// decoding didn't find that field; the sample still identifies which workout
/// it supplements via `linkedWatchWorkoutUUID`.
public struct ExerciseSupplement {
    public let externalID: String
    public let linkedWatchWorkoutUUID: UUID?
    /// The sample's own start date -- code review (2026-08-28) finding #4:
    /// callers must be able to window-filter supplements by date themselves
    /// (`KnowledgeStore.refresh()`'s 30-day workouts window,
    /// `workoutsSummary(days:)`'s re-sliced window) without a second lookup
    /// back into the `LocalSample` array that produced this value.
    public let start: Date
    /// The sample's device/source label (e.g. "Fitbit Air") -- code review
    /// (2026-08-28) finding #11: an unlinked supplement's device attribution
    /// in coach-facing text must come from here, never a hardcoded literal.
    public let source: String
    public let activityName: String?
    public let distanceMeters: Double?
    public let energyKilocalories: Double?

    /// Direct memberwise construction -- used by pure-derivation tests
    /// (`KnowledgeDerivation.workoutsField`'s "Tests" line: synthetic arrays,
    /// no `LocalSample`/JSON round trip needed) and available to any future
    /// caller that already has these fields from elsewhere.
    public init(
        externalID: String,
        linkedWatchWorkoutUUID: UUID?,
        start: Date,
        source: String,
        activityName: String?,
        distanceMeters: Double?,
        energyKilocalories: Double?
    ) {
        self.externalID = externalID
        self.linkedWatchWorkoutUUID = linkedWatchWorkoutUUID
        self.start = start
        self.source = source
        self.activityName = activityName
        self.distanceMeters = distanceMeters
        self.energyKilocalories = energyKilocalories
    }

    /// Decodes `sample.payloadJSON` via the shared `decodedExercisePayload`
    /// (CoreModel) -- see this file's header.
    public init(sample: LocalSample) {
        let fields = sample.decodedExercisePayload
        self.init(
            externalID: sample.externalID,
            linkedWatchWorkoutUUID: sample.linkedWatchWorkoutUUID,
            start: sample.start,
            source: sample.source,
            activityName: fields.activityName,
            distanceMeters: fields.distanceMeters,
            energyKilocalories: fields.energyKilocalories
        )
    }
}

/// Sums every numeric entry in a `LocalSample.payloadJSON`'s top-level
/// `values` dictionary (the raw `GoogleDataPoint.values` Google returned,
/// per `SyncEngineLocalPayload`'s `values: [String: Double]` field).
///
/// **Judgment call (no fixture exists for `active_zone_minutes`, base-
/// knowledge.md §3 has no worked example for it):** rather than guess a
/// specific key name and risk silently reading zero from a real payload
/// keyed differently, this sums *every* value present. Active Zone Minutes
/// is documented (base-knowledge.md §5) as a single-field interval type ("I"
/// in §3's cadence column, one minutes-count per point), so summing the
/// dict's values is equivalent to reading that one field regardless of its
/// exact key -- and degrades to `0` (not a crash) if a future payload shape
/// adds unrelated numeric fields, which would only overcount, never throw.
/// Flagged in progress.md for correction once a real payload is observed.
func sumPayloadValues(_ sample: LocalSample) -> Double {
    guard let envelope = try? JSONSerialization.jsonObject(with: sample.payloadJSON) as? [String: Any],
          let values = envelope["values"] as? [String: Any] else {
        return 0
    }
    return values.values.reduce(into: 0.0) { total, value in
        if let number = value as? NSNumber {
            total += number.doubleValue
        }
    }
}
