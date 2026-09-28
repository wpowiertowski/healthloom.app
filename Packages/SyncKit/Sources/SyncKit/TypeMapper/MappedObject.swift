// MappedObject.swift
//
// WP-07 (implementation-plan.md) step 1's required public shape:
// `enum MappedObject { case quantity(HKQuantitySample); case
// category([HKCategorySample]); case localOnly; case skip }`. The
// HealthKit-touching cases are guarded `#if canImport(HealthKit)` per the
// brief's explicit instruction; `TypeMapper.decide(_:) -> MappedDecision`
// (TypeMapper.swift) is the always-compiled, HealthKit-free layer this file
// wraps -- see MappedTypes.swift's header for the full pure/impure split
// rationale (mirrors WP-06's HealthKitIdentifierClassifier/
// HealthKitObjectTypeResolver split).
//
// On this repo's current toolchain HealthKit is importable even on the
// macOS test host (WP-06's HealthKitObjectTypeResolver.swift made the same
// observation, and it still holds here), so in practice this file's #if
// branch is always active in this workspace and the four P0 golden tests
// construct and inspect real HKQuantitySample/HKCategorySample objects
// directly -- no HKHealthStore, no entitlement, no simulator needed,
// matching this WP's "Done when" bar ("golden-file tests pass for all four
// types" via plain `swift test`).

import CoreModel
import GoogleHealthClient

#if canImport(HealthKit)
import HealthKit
#endif

public enum MappedObject: Sendable {
#if canImport(HealthKit)
    case quantity(HKQuantitySample)
    case category([HKCategorySample])
    /// WP-13: a real `HKCorrelation(.food)`, built directly here -- unlike
    /// `.workout` below, `HKCorrelation` has a non-deprecated, synchronous
    /// factory initializer (see `MappedNutritionCorrelation
    /// .makeHKCorrelation()` at the bottom of this file), so it follows the
    /// same "construct it right here" precedent as `.quantity`/`.category`.
    case correlation(HKCorrelation)
    /// WP-12b: several `HKQuantitySample`s standing in for **one** Google
    /// data point -- produced **only** by `WatchConflictResolver` when a
    /// cumulative stream sample (steps / distance / active energy) is split
    /// at watch-coverage edges with its value pro-rated (architecture.md
    /// D13.3; test-plan.md §2.3). `TypeMapper.map(_:)` itself never emits
    /// this case. All samples share the originating point's external-ID
    /// metadata -- exactly the same one-point-many-samples precedent
    /// `.category`'s sleep-stage segments established in WP-07, so the
    /// existence diff and delete-by-external-ID (D4) treat the split parts
    /// as one unit.
    case quantities([HKQuantitySample])
#endif
    /// WP-12: carries the pure `MappedWorkout` decision forward rather than
    /// a real `HKWorkout` -- unlike `.quantity`/`.category`, a real
    /// `HKWorkout` cannot be constructed synchronously here (its own
    /// initializers are deprecated in favor of `HKWorkoutBuilder`'s async,
    /// store-backed `beginCollection -> add -> endCollection ->
    /// finishWorkout` flow, which needs a real `HKHealthStore`).
    /// `HealthKitWriter.saveWorkout(_:)` (HealthKitWriter.swift) is where
    /// that flow actually runs. This case needs no `#if canImport(HealthKit)`
    /// guard -- `MappedWorkout` itself is HealthKit-free (MappedTypes.swift)
    /// -- so `TypeMapper.map(_:)` remains a total, always-compiling function
    /// on every platform, even ones without HealthKit.
    case workout(MappedWorkout)
    case localOnly
    case skip
}

extension TypeMapper {
    /// Build the real HealthKit object(s) for `point`'s mapping decision.
    /// Thin wrapper over `decide(_:)` -- see that function (TypeMapper.swift)
    /// for the actual mapping/dropping rules; this function only translates
    /// an already-made decision into concrete `HK*` objects.
    public static func map(_ point: GoogleDataPoint) -> MappedObject {
        switch decide(point) {
        case .localOnly:
            return .localOnly
        case .skip:
            return .skip
        case .workout(let workout):
            // Pure pass-through -- see `MappedObject.workout`'s doc comment
            // for why this isn't turned into a real `HKWorkout` here.
            return .workout(workout)
        case .correlation(let meal):
#if canImport(HealthKit)
            guard let correlation = meal.makeHKCorrelation() else { return .skip }
            return .correlation(correlation)
#else
            return .skip
#endif
        case .quantity(let sample):
#if canImport(HealthKit)
            guard let hkSample = sample.makeHKQuantitySample() else { return .skip }
            return .quantity(hkSample)
#else
            return .skip
#endif
        case .category(let segments):
#if canImport(HealthKit)
            let hkSamples = segments.compactMap { $0.makeHKCategorySample() }
            // Every element of `segments` carries a `healthKitIdentifier`
            // TypeMapper itself produced (never user/network-supplied), so a
            // resolution failure here would mean this file's identifier
            // string is wrong, not a data problem -- drop the whole session
            // rather than emit a partial one if that ever happens.
            guard hkSamples.count == segments.count else { return .skip }
            return .category(hkSamples)
#else
            return .skip
#endif
        }
    }
}

#if canImport(HealthKit)
extension MappedMetadata {
    /// Internal (not `fileprivate`, as of WP-12) rather than `public`: this
    /// is an implementation detail of turning a `Mapped*` decision into a
    /// real HealthKit metadata dictionary, needed both here (for
    /// `HKQuantitySample`/`HKCategorySample`) and from
    /// `HealthKitWriter.saveWorkout(_:)` (HealthKitWriter.swift, a different
    /// file in this same module) for the workout's own metadata and its
    /// attached distance/energy samples -- so it can no longer stay
    /// file-private, but there's no reason for it to be public API either.
    nonisolated func makeHKMetadataDictionary() -> [String: Any] {
        var result: [String: Any] = [
            HKMetadataKeyExternalUUID: externalUUID,
            Self.externalIDKey: externalID,
        ]
        if let sourceDevice {
            result[Self.sourceDeviceKey] = sourceDevice
        }
        if let hrvStatistic {
            result[Self.hrvStatisticKey] = hrvStatistic.rawValue
        }
        return result
    }
}

extension MappedWorkoutActivityType {
    /// Maps to the real, **named** `HKWorkoutActivityType` case (not a raw
    /// `Int`/`UInt` literal -- see `MappedWorkoutActivityType`'s own doc
    /// comment, MappedTypes.swift, for why). Verified against the real SDK
    /// header (`HealthKit.framework/Headers/HKWorkout.h`) before being
    /// written here -- see progress.md's WP-12 entry for the exact
    /// verification performed.
    func makeHKWorkoutActivityType() -> HKWorkoutActivityType {
        switch self {
        case .running: return .running
        case .walking: return .walking
        case .cycling: return .cycling
        case .swimming: return .swimming
        case .hiking: return .hiking
        case .traditionalStrengthTraining: return .traditionalStrengthTraining
        case .yoga: return .yoga
        case .elliptical: return .elliptical
        case .rowing: return .rowing
        case .highIntensityIntervalTraining: return .highIntensityIntervalTraining
        case .stairClimbing: return .stairClimbing
        case .coreTraining: return .coreTraining
        case .other: return .other
        }
    }
}

extension MappedQuantitySample {
    /// WP-11 additions verified against the real `HKUnit` factory methods
    /// (`HKUnit.h`, iOS 26.4 SDK) via a scratch `swiftc -typecheck` before
    /// being written here -- see MappedTypes.swift's `MappedUnit` doc
    /// comment and progress.md's WP-11 entry.
    nonisolated fileprivate func makeHKUnit() -> HKUnit {
        switch unit {
        case .count:
            return .count()
        case .countPerMinute:
            return HKUnit.count().unitDivided(by: .minute())
        case .kilogram:
            return .gramUnit(with: .kilo)
        case .meter:
            return .meter()
        case .kilocalorie:
            return .kilocalorie()
        case .fraction:
            return .percent()
        case .degreeCelsius:
            return .degreeCelsius()
        case .liter:
            return .liter()
        case .gram:
            return .gram()
        case .milligramsPerDeciliter:
            return HKUnit.gramUnit(with: .milli).unitDivided(by: HKUnit.literUnit(with: .deci))
        case .millimolesPerLiter:
            return HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose)
                .unitDivided(by: .liter())
        case .vo2MaxUnit:
            return HKUnit.literUnit(with: .milli)
                .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        case .millisecond:
            return .secondUnit(with: .milli)
        }
    }

    nonisolated func makeHKQuantitySample() -> HKQuantitySample? {
        guard
            let type = HKObjectType.quantityType(
                forIdentifier: HKQuantityTypeIdentifier(rawValue: healthKitIdentifier)
            )
        else { return nil }
        let quantity = HKQuantity(unit: makeHKUnit(), doubleValue: value)
        return HKQuantitySample(
            type: type,
            quantity: quantity,
            start: start,
            end: end,
            metadata: metadata.makeHKMetadataDictionary()
        )
    }
}

extension MappedCategorySample {
    func makeHKCategorySample() -> HKCategorySample? {
        guard
            let type = HKObjectType.categoryType(
                forIdentifier: HKCategoryTypeIdentifier(rawValue: healthKitIdentifier)
            )
        else { return nil }
        return HKCategorySample(
            type: type,
            value: stage.rawValue,
            start: start,
            end: end,
            metadata: metadata.makeHKMetadataDictionary()
        )
    }
}

extension MappedNutritionCorrelation {
    /// WP-13: builds a real `HKCorrelation(.food)` directly -- no
    /// builder/store round-trip needed (see `MappedDecision.correlation`'s
    /// doc comment, MappedTypes.swift, for why this differs from
    /// `.workout`). Mirrors `makeHKQuantitySample()`/`makeHKCategorySample()`
    /// above: a direct `HKObjectType.correlationType(forIdentifier:)` lookup
    /// from this struct's own `healthKitIdentifier` string, not a re-derived
    /// literal, and `nil` (never a crash) on any resolution failure --
    /// WP-07 step 5's "never crash" rule applied to this new sample kind
    /// too.
    ///
    /// Constituents are built by reusing `MappedQuantitySample
    /// .makeHKQuantitySample()` verbatim (one call per macro already present
    /// in `constituents`) rather than hand-rolling a second
    /// `HKQuantitySample` construction path -- this is also why a
    /// constituent-type resolution failure (a `healthKitIdentifier` string
    /// this SDK doesn't recognize) drops the *whole* correlation rather than
    /// silently omitting one macro: exactly the same "TypeMapper's own
    /// identifier string is wrong, not a data problem" reasoning
    /// `makeHKQuantitySample`'s caller (`map(_:)`'s `.category` arm) already
    /// applies to a partial sleep-segment resolution failure.
    func makeHKCorrelation() -> HKCorrelation? {
        guard
            let type = HKObjectType.correlationType(
                forIdentifier: HKCorrelationTypeIdentifier(rawValue: healthKitIdentifier)
            )
        else { return nil }

        let hkConstituents: [HKSample] = constituents.compactMap { $0.makeHKQuantitySample() }
        guard hkConstituents.count == constituents.count, !hkConstituents.isEmpty else { return nil }

        return HKCorrelation(
            type: type,
            start: start,
            end: end,
            objects: Set(hkConstituents),
            metadata: metadata.makeHKMetadataDictionary()
        )
    }
}
#endif
