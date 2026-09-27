// HealthKitWriterTypes.swift
//
// WP-08 (implementation-plan.md) / architecture.md §4 D2, D4, D13.
//
// HealthKit-import-free per the pure/impure split WP-06/WP-07 established
// (HealthKitIdentifierClassifier vs. HealthKitObjectTypeResolver;
// MappedDecision vs. MappedObject): this file's error and report types carry
// no `HK*` type anywhere in their public surface (identifiers are plain
// `String`s — `HKObjectType.identifier`/`HKSampleType`'s own rawValue-style
// string, read once by the HealthKit-only layer in HealthKitWriter.swift), so
// they're usable — and unit-testable — from any code, on any platform,
// without importing HealthKit at all. Only `HealthStoreProtocol.swift` and
// `HealthKitWriter.swift` (which actually name `HK*` types) live behind
// `#if canImport(HealthKit)`.

import Foundation

/// Error surface for `HealthKitWriter` and the `HealthStoreProtocol`
/// implementations it drives. Mirrors `HealthKitAuthError`'s posture
/// (WP-06/HealthKitAuthTypes.swift): every underlying `HKHealthStore` failure
/// is surfaced with a string description (architecture.md D11's redaction
/// rule — no health values, no tokens; there are none to leak here regardless,
/// but the convention is kept consistent across this package), never silently
/// swallowed into an empty result.
public enum HealthKitWriterError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The underlying `HKHealthStore`/`HKWorkoutBuilder` call itself failed
    /// (e.g. authorization not granted, an object failed HealthKit's own
    /// validation). Carries only the error's string description. As of
    /// WP-12, this also covers every `HKWorkoutBuilder` step
    /// (`saveWorkout(_:)`, HealthKitWriter.swift) — the WP-08 stub's
    /// dedicated `.workoutsNotYetImplemented` case was removed once the real
    /// implementation landed, per that case's own original doc comment
    /// ("never remove this without replacing it with a real
    /// implementation").
    case underlying(String)

    /// HealthKit refused because the device is locked: protected health
    /// data is readable only while it's unlocked (WP-52 -- a background
    /// wake on a locked phone logged "Protected health data is
    /// inaccessible" as a red error for every type). A pause, not a
    /// failure: `SyncEngine` stops the run like a cancellation and the next
    /// run retries. Classified where HealthKit errors are wrapped
    /// (`init(wrapping:)`, HealthStoreProtocol.swift), never by callers
    /// parsing `underlying`'s text.
    case protectedDataUnavailable

    public var description: String {
        switch self {
        case .underlying(let message):
            return "HealthKitWriterError.underlying(\(message))"
        case .protectedDataUnavailable:
            return "HealthKitWriterError.protectedDataUnavailable"
        }
    }
}

/// One app-written HealthKit object's identity + interval, as returned by
/// `HealthStoreProtocol.appWrittenSampleRecords(ofType:start:end:)` (WP-12b /
/// architecture.md D13.4). Retroactive conflict cleanup needs both the
/// external ID (to delete by, same machinery as D4) *and* the sample's own
/// interval (to test against the current coverage index) -- `existingExternalIDs`
/// deliberately returns only the ID set, so this richer record type exists
/// alongside it rather than widening that hot-path method. HealthKit-free
/// (plain `String`/`Date`), per this file's header.
nonisolated public struct AppWrittenSampleRecord: Sendable, Hashable {
    /// `HKMetadataKeyExternalUUID` value -- the Google data-point ID.
    public var externalID: String
    public var start: Date
    public var end: Date

    public init(externalID: String, start: Date, end: Date) {
        self.externalID = externalID
        self.start = start
        self.end = end
    }
}

/// Per-type outcome of `HealthKitWriter.deleteAllAppData(types:)`
/// (architecture.md D4 "disconnect & wipe" / WP-35's delete-by-source flow).
///
/// Deliberately generic: `HealthKitWriter` never hardcodes which HealthKit
/// types this app might have written (today's four P0 types — steps, heart
/// rate, weight, sleep — are just what WP-11/12/13 haven't broadened yet), so
/// this report is keyed by whatever `HKObjectType.identifier` strings the
/// *caller* asked to sweep, one entry per requested type (including types
/// where nothing was deleted, so a caller can render true "per-type progress"
/// per WP-35's brief, not just the types that happened to have data).
public struct AppDataWipeReport: Sendable, Hashable {
    /// `HKObjectType.identifier` (e.g. `"HKQuantityTypeIdentifierStepCount"`)
    /// -> number of objects of that type deleted.
    public var deletedCounts: [String: Int]

    public init(deletedCounts: [String: Int]) {
        self.deletedCounts = deletedCounts
    }

    /// Total objects deleted across every type swept.
    public var total: Int {
        deletedCounts.values.reduce(0, +)
    }
}
