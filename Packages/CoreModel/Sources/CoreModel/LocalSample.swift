// LocalSample.swift
// CoreModel
//
// The ONLY local mirror of health data HealthLoom keeps — and only for types HealthKit
// cannot accept a write for (architecture.md D2: ECG, Active Zone Minutes, Active
// Minutes, Irregular Rhythm Notifications — i.e. `GoogleDataType.writability == .localOnly`).
// Everything HealthKit-writable flows straight through to HealthKit; CoreModel never
// mirrors it here.

import Foundation
import SwiftData

/// A normalized, full-fidelity point for a `.localOnly` `GoogleDataType`.
@Model
public final class LocalSample {
    /// Google data-point ID — the idempotency key (architecture.md D4). Re-sync upserts
    /// by this value rather than inserting duplicates.
    @Attribute(.unique) public var externalID: String

    /// `GoogleDataType.filterName` this sample belongs to.
    public var dataType: String

    /// The full normalized point, type-specific shape, encoded as JSON. Kept as opaque
    /// `Data` here so CoreModel doesn't need a payload schema per type — SyncKit encodes
    /// and CoachKit/UI decode using shapes they own.
    public var payloadJSON: Data

    public var start: Date
    public var end: Date

    /// Human-readable device/source label (e.g. "Fitbit Air"), for in-app display.
    public var source: String

    /// Set by WP-12b's `ConflictResolver` when a Fitbit exercise session defers to an
    /// overlapping Apple Watch workout (architecture.md D13.2) — links this supplement
    /// record to the `HKWorkout`'s UUID so the Activities view can consolidate them into
    /// one entry instead of showing two.
    public var linkedWatchWorkoutUUID: UUID?

    public init(
        externalID: String,
        dataType: String,
        payloadJSON: Data,
        start: Date,
        end: Date,
        source: String,
        linkedWatchWorkoutUUID: UUID? = nil
    ) {
        self.externalID = externalID
        self.dataType = dataType
        self.payloadJSON = payloadJSON
        self.start = start
        self.end = end
        self.source = source
        self.linkedWatchWorkoutUUID = linkedWatchWorkoutUUID
    }
}

extension LocalSample {
    /// The numeric `values` the point carried (the payload's top-level
    /// `values` dictionary, written by SyncKit's `SharedLocalPayload`) --
    /// `minutes` for Active Zone Minutes and Active Minutes. Empty when the
    /// payload has none or can't be read. The one decode of that field,
    /// shared by the Data tab's trends and CoachKit's knowledge derivation.
    public var payloadValues: [String: Double] {
        guard let envelope = try? JSONSerialization.jsonObject(with: payloadJSON) as? [String: Any],
              let values = envelope["values"] as? [String: Any]
        else { return [:] }
        return values.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }
}
