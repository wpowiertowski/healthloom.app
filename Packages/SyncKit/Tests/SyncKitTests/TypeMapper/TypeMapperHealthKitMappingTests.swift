// TypeMapperHealthKitMappingTests.swift
//
// WP-07 (implementation-plan.md): the HealthKit-wrapping half of the golden
// tests -- confirms `TypeMapper.map(_:)` (MappedObject.swift) turns the same
// decisions `TypeMapperGoldenTests`/`TypeMapperSleepStageTests` verify at the
// pure `MappedDecision` level into correct real `HKQuantitySample`/
// `HKCategorySample` objects (type, quantity/value, unit, dates, metadata).
//
// Guarded with #if canImport(HealthKit), matching MappedObject.swift itself.
// As WP-06's HealthKitObjectTypeResolverTests.swift notes, HealthKit happens
// to be importable on this repo's macOS test host and constructing sample
// *objects* (as opposed to touching HKHealthStore) needs no entitlement, so
// this suite runs for real here -- no simulator, no store, matching WP-07's
// "Done when" bar.

#if canImport(HealthKit)
import CoreModel
import Foundation
import GoogleHealthClient
import HealthKit
import Testing
@testable import SyncKit

@Suite struct TypeMapperHealthKitMappingTests {
    @Test func stepsMapsToRealQuantitySample() {
        guard case .quantity(let hkSample) = TypeMapper.map(TypeMapperFixtures.stepsPoint()) else {
            Issue.record("expected .quantity")
            return
        }
        #expect(hkSample.quantityType == HKObjectType.quantityType(forIdentifier: .stepCount))
        #expect(hkSample.quantity == HKQuantity(unit: .count(), doubleValue: 482))
        #expect(hkSample.startDate == TypeMapperFixtures.date("2026-07-01T00:00:00Z"))
        #expect(hkSample.endDate == TypeMapperFixtures.date("2026-07-01T01:00:00Z"))
        #expect(hkSample.metadata?[HKMetadataKeyExternalUUID] as? String == "steps-0001")
        #expect(hkSample.metadata?["healthloom.externalID"] as? String == "steps-0001")
        #expect(hkSample.metadata?["healthloom.sourceDevice"] as? String == "Fitbit Air")
    }

    @Test func heartRateMapsToRealQuantitySample() {
        guard case .quantity(let hkSample) = TypeMapper.map(TypeMapperFixtures.heartRatePoint()) else {
            Issue.record("expected .quantity")
            return
        }
        let bpmUnit = HKUnit.count().unitDivided(by: .minute())
        #expect(hkSample.quantityType == HKObjectType.quantityType(forIdentifier: .heartRate))
        #expect(hkSample.quantity == HKQuantity(unit: bpmUnit, doubleValue: 58))
        #expect(hkSample.startDate == hkSample.endDate)
        #expect(hkSample.metadata?[HKMetadataKeyExternalUUID] as? String == "hr-0001")
    }

    @Test func weightMapsToRealQuantitySampleInKilograms() {
        guard case .quantity(let hkSample) = TypeMapper.map(TypeMapperFixtures.weightPoint()) else {
            Issue.record("expected .quantity")
            return
        }
        #expect(hkSample.quantityType == HKObjectType.quantityType(forIdentifier: .bodyMass))
        #expect(hkSample.quantity == HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: 70.5))
        #expect(hkSample.metadata?["healthloom.sourceDevice"] as? String == "Fitbit Aria Air")
    }

    @Test func sleepMapsToRealCategorySamples() {
        guard case .category(let hkSamples) = TypeMapper.map(TypeMapperFixtures.sleepPoint()) else {
            Issue.record("expected .category")
            return
        }
        #expect(hkSamples.count == 5)
        let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
        let expectedValues = [
            HKCategoryValueSleepAnalysis.awake.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
        ]
        for (index, (sample, expectedValue)) in zip(hkSamples, expectedValues).enumerated() {
            #expect(sample.categoryType == sleepType)
            #expect(sample.value == expectedValue)
            // Round-7 item 3: per-segment derived UUIDs.
            #expect(sample.metadata?[HKMetadataKeyExternalUUID] as? String == "sleep-0001#sleep-\(index)")
        }
    }

    /// Cross-checks `MappedSleepStage`'s hardcoded raw `Int` values
    /// (MappedTypes.swift) against the real `HKCategoryValueSleepAnalysis`
    /// enum, so a future HealthKit SDK change to those raw values can't
    /// silently drift the HealthKit-free layer out of sync with reality.
    @Test func mappedSleepStageRawValuesMatchRealHealthKitEnum() {
        #expect(MappedSleepStage.awake.rawValue == HKCategoryValueSleepAnalysis.awake.rawValue)
        #expect(MappedSleepStage.asleepCore.rawValue == HKCategoryValueSleepAnalysis.asleepCore.rawValue)
        #expect(MappedSleepStage.asleepDeep.rawValue == HKCategoryValueSleepAnalysis.asleepDeep.rawValue)
        #expect(MappedSleepStage.asleepREM.rawValue == HKCategoryValueSleepAnalysis.asleepREM.rawValue)
        #expect(MappedSleepStage.asleepUnspecified.rawValue == HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue)
    }

    /// `.localOnly`/`.skip` decisions pass through `map(_:)` unchanged --
    /// confirms the wrapping layer doesn't reinterpret them.
    @Test func localOnlyAndSkipPassThroughMapUnchanged() {
        let localOnlyPoint = GoogleDataPoint(
            id: "x", dataType: .electrocardiogram,
            start: TypeMapperFixtures.date("2026-07-01T00:00:00Z"),
            end: TypeMapperFixtures.date("2026-07-01T00:00:00Z"),
            source: DataSource(platform: nil, deviceDisplayName: nil, recordingMethod: nil),
            values: [:]
        )
        guard case .localOnly = TypeMapper.map(localOnlyPoint) else {
            Issue.record("expected .localOnly")
            return
        }

        let skipPoint = GoogleDataPoint(
            id: "y", dataType: .altitude,
            start: TypeMapperFixtures.date("2026-07-01T00:00:00Z"),
            end: TypeMapperFixtures.date("2026-07-01T00:00:00Z"),
            source: DataSource(platform: nil, deviceDisplayName: nil, recordingMethod: nil),
            values: [:]
        )
        guard case .skip = TypeMapper.map(skipPoint) else {
            Issue.record("expected .skip")
            return
        }
    }

    /// Out-of-range values dropped at the `decide(_:)` layer stay dropped
    /// through `map(_:)` too -- never silently resurrected into a sample.
    @Test func outOfRangeValuesStaySkippedThroughMap() {
        guard case .skip = TypeMapper.map(TypeMapperFixtures.stepsPoint(count: -1)) else {
            Issue.record("expected .skip")
            return
        }
        guard case .skip = TypeMapper.map(TypeMapperFixtures.heartRatePoint(bpm: 400)) else {
            Issue.record("expected .skip")
            return
        }
    }

    // MARK: - WP-11: full TypeMapper table -> real HealthKit objects

    @Test func distanceMapsToRealQuantitySampleInMeters() {
        guard case .quantity(let hkSample) = TypeMapper.map(TypeMapperFixtures.distancePoint()) else {
            Issue.record("expected .quantity")
            return
        }
        #expect(hkSample.quantityType == HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning))
        #expect(hkSample.quantity == HKQuantity(unit: .meter(), doubleValue: 15.0))
    }

    @Test func floorsMapsToRealQuantitySample() {
        guard case .quantity(let hkSample) = TypeMapper.map(TypeMapperFixtures.floorsPoint()) else {
            Issue.record("expected .quantity")
            return
        }
        #expect(hkSample.quantityType == HKObjectType.quantityType(forIdentifier: .flightsClimbed))
        #expect(hkSample.quantity == HKQuantity(unit: .count(), doubleValue: 6))
    }

    @Test func activeEnergyBurnedMapsToRealQuantitySampleInKilocalories() {
        guard case .quantity(let hkSample) = TypeMapper.map(TypeMapperFixtures.activeEnergyBurnedPoint()) else {
            Issue.record("expected .quantity")
            return
        }
        #expect(hkSample.quantityType == HKObjectType.quantityType(forIdentifier: .activeEnergyBurned))
        #expect(hkSample.quantity == HKQuantity(unit: .kilocalorie(), doubleValue: 312.5))
    }

    @Test func restingHeartRateMapsToRealQuantitySample() {
        guard case .quantity(let hkSample) = TypeMapper.map(TypeMapperFixtures.restingHeartRatePoint()) else {
            Issue.record("expected .quantity")
            return
        }
        let bpmUnit = HKUnit.count().unitDivided(by: .minute())
        #expect(hkSample.quantityType == HKObjectType.quantityType(forIdentifier: .restingHeartRate))
        #expect(hkSample.quantity == HKQuantity(unit: bpmUnit, doubleValue: 52))
    }

    /// Confirms HRV maps to `.localOnly` through the real HK-wrapping
    /// `map(_:)`, never to a `heartRateVariabilitySDNN` sample -- the
    /// HealthKit-facing counterpart of `heartRateVariabilityRoutesToLocalOnlyNotSDNN`
    /// (TypeMapperGoldenTests.swift).
    @Test func heartRateVariabilityMapsToLocalOnlyThroughRealHealthKitLayer() {
        guard case .localOnly = TypeMapper.map(TypeMapperFixtures.heartRateVariabilityPoint()) else {
            Issue.record("expected .localOnly")
            return
        }
    }

    @Test func oxygenSaturationMapsToRealQuantitySampleAsFraction() {
        guard case .quantity(let hkSample) = TypeMapper.map(TypeMapperFixtures.oxygenSaturationPoint(percentage: 97)) else {
            Issue.record("expected .quantity")
            return
        }
        #expect(hkSample.quantityType == HKObjectType.quantityType(forIdentifier: .oxygenSaturation))
        #expect(hkSample.quantity == HKQuantity(unit: .percent(), doubleValue: 0.97))
    }

    @Test func respiratoryRateMapsToRealQuantitySample() {
        guard case .quantity(let hkSample) = TypeMapper.map(TypeMapperFixtures.respiratoryRatePoint()) else {
            Issue.record("expected .quantity")
            return
        }
        let breathsPerMinuteUnit = HKUnit.count().unitDivided(by: .minute())
        #expect(hkSample.quantityType == HKObjectType.quantityType(forIdentifier: .respiratoryRate))
        #expect(hkSample.quantity == HKQuantity(unit: breathsPerMinuteUnit, doubleValue: 14.5))
    }

    @Test func vo2MaxMapsToRealQuantitySampleInMLPerKgMin() {
        guard case .quantity(let hkSample) = TypeMapper.map(TypeMapperFixtures.vo2MaxPoint(dataType: .vo2Max)) else {
            Issue.record("expected .quantity")
            return
        }
        let vo2MaxUnit = HKUnit.literUnit(with: .milli)
            .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        #expect(hkSample.quantityType == HKObjectType.quantityType(forIdentifier: .vo2Max))
        #expect(hkSample.quantity == HKQuantity(unit: vo2MaxUnit, doubleValue: 42.3))
    }

    /// Run VO2 Max (a distinct Google type) resolves to the exact same real
    /// `HKQuantityType` as plain VO2 Max.
    @Test func runVO2MaxMapsToTheSameRealVO2MaxType() {
        guard case .quantity(let hkSample) = TypeMapper.map(
            TypeMapperFixtures.vo2MaxPoint(dataType: .runVO2Max, value: 45.1)
        ) else {
            Issue.record("expected .quantity")
            return
        }
        #expect(hkSample.quantityType == HKObjectType.quantityType(forIdentifier: .vo2Max))
    }

    @Test func heightMapsToRealQuantitySampleInMeters() {
        guard case .quantity(let hkSample) = TypeMapper.map(TypeMapperFixtures.heightPoint()) else {
            Issue.record("expected .quantity")
            return
        }
        #expect(hkSample.quantityType == HKObjectType.quantityType(forIdentifier: .height))
        #expect(hkSample.quantity == HKQuantity(unit: .meter(), doubleValue: 1.78))
    }

    @Test func bodyFatMapsToRealQuantitySampleAsFraction() {
        guard case .quantity(let hkSample) = TypeMapper.map(TypeMapperFixtures.bodyFatPoint(percentage: 22)) else {
            Issue.record("expected .quantity")
            return
        }
        #expect(hkSample.quantityType == HKObjectType.quantityType(forIdentifier: .bodyFatPercentage))
        #expect(hkSample.quantity == HKQuantity(unit: .percent(), doubleValue: 0.22))
    }

    @Test func bloodGlucoseMgDLMapsToRealQuantitySample() {
        guard case .quantity(let hkSample) = TypeMapper.map(TypeMapperFixtures.bloodGlucoseMgDLPoint()) else {
            Issue.record("expected .quantity")
            return
        }
        let mgdlUnit = HKUnit.gramUnit(with: .milli).unitDivided(by: HKUnit.literUnit(with: .deci))
        #expect(hkSample.quantityType == HKObjectType.quantityType(forIdentifier: .bloodGlucose))
        #expect(hkSample.quantity == HKQuantity(unit: mgdlUnit, doubleValue: 98))
    }

    @Test func bloodGlucoseMmolLMapsToRealQuantitySample() {
        guard case .quantity(let hkSample) = TypeMapper.map(TypeMapperFixtures.bloodGlucoseMmolLPoint()) else {
            Issue.record("expected .quantity")
            return
        }
        let mmolUnit = HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose)
            .unitDivided(by: .liter())
        #expect(hkSample.quantityType == HKObjectType.quantityType(forIdentifier: .bloodGlucose))
        #expect(hkSample.quantity == HKQuantity(unit: mmolUnit, doubleValue: 5.4))
    }

    @Test func coreBodyTemperatureMapsToRealQuantitySampleInCelsius() {
        guard case .quantity(let hkSample) = TypeMapper.map(TypeMapperFixtures.coreBodyTemperaturePoint()) else {
            Issue.record("expected .quantity")
            return
        }
        #expect(hkSample.quantityType == HKObjectType.quantityType(forIdentifier: .bodyTemperature))
        #expect(hkSample.quantity == HKQuantity(unit: .degreeCelsius(), doubleValue: 37.1))
    }

    @Test func hydrationMapsToRealQuantitySampleInLiters() {
        guard case .quantity(let hkSample) = TypeMapper.map(TypeMapperFixtures.hydrationPoint()) else {
            Issue.record("expected .quantity")
            return
        }
        #expect(hkSample.quantityType == HKObjectType.quantityType(forIdentifier: .dietaryWater))
        #expect(hkSample.quantity == HKQuantity(unit: .liter(), doubleValue: 0.5))
    }

    // MARK: - WP-12: Exercise -> HKWorkoutActivityType (real SDK enum)

    /// Every `MappedWorkoutActivityType` case maps to the real, *named*
    /// `HKWorkoutActivityType` case its own doc comment (MappedTypes.swift)
    /// documents -- exhaustive over `MappedWorkoutActivityType.allCases`, so
    /// this test fails to compile-and-miss a case if a future case is ever
    /// added to the enum without updating the table below, same
    /// tripwire-by-construction style as `TypeMapperPropertyTests`'
    /// deliberately-exhaustive-switch guard.
    @Test func everyMappedWorkoutActivityTypeMapsToItsRealHKWorkoutActivityTypeCase() {
        let expectations: [MappedWorkoutActivityType: HKWorkoutActivityType] = [
            .running: .running,
            .walking: .walking,
            .cycling: .cycling,
            .swimming: .swimming,
            .hiking: .hiking,
            .traditionalStrengthTraining: .traditionalStrengthTraining,
            .yoga: .yoga,
            .elliptical: .elliptical,
            .rowing: .rowing,
            .highIntensityIntervalTraining: .highIntensityIntervalTraining,
            .stairClimbing: .stairClimbing,
            .coreTraining: .coreTraining,
            .other: .other,
        ]
        #expect(expectations.count == MappedWorkoutActivityType.allCases.count)
        for mapped in MappedWorkoutActivityType.allCases {
            #expect(mapped.makeHKWorkoutActivityType() == expectations[mapped])
        }
    }

    /// An Exercise session maps to a `.workout` decision through the real
    /// HK-wrapping `map(_:)` (a pure pass-through of the same `MappedWorkout`
    /// value `TypeMapper.decide(_:)` produced -- see `MappedObject.workout`'s
    /// doc comment for why there's no real `HKWorkout` to construct here).
    @Test func exerciseSessionMapsToAWorkoutDecisionThroughMap() {
        guard case .workout(let workout) = TypeMapper.map(TypeMapperFixtures.exercisePoint(wireActivityType: "bike")) else {
            Issue.record("expected .workout")
            return
        }
        #expect(workout.activityType == .cycling)
        #expect(workout.activityType.makeHKWorkoutActivityType() == .cycling)
    }

    // MARK: - WP-13: Nutrition Log -> real HKCorrelation(.food)

    /// The full-macro meal (`nutrition-log.json`'s `nutrition-0001`) maps
    /// through the real HK-wrapping `map(_:)` to an actual `HKCorrelation`
    /// (built directly -- no builder/store round-trip, see
    /// `MappedDecision.correlation`'s doc comment) with the real
    /// `HKCorrelationType(.food)` and four real constituent
    /// `HKQuantitySample`s at the exact confirmed identifiers/units/values,
    /// with metadata stamped on **both** the correlation itself and every
    /// constituent (WP-13's explicit metadata-placement requirement).
    @Test func fullMacroMealMapsToRealHKCorrelation() {
        guard case .correlation(let correlation) = TypeMapper.map(TypeMapperFixtures.nutritionLogPoint()) else {
            Issue.record("expected .correlation")
            return
        }
        #expect(correlation.correlationType == HKObjectType.correlationType(forIdentifier: .food))
        #expect(correlation.startDate == TypeMapperFixtures.date("2026-07-01T12:15:00Z"))
        #expect(correlation.endDate == TypeMapperFixtures.date("2026-07-01T12:15:00Z"))
        #expect(correlation.objects.count == 4)
        #expect(correlation.metadata?[HKMetadataKeyExternalUUID] as? String == "nutrition-0001#meal") // round-7 item 3
        #expect(correlation.metadata?["healthloom.externalID"] as? String == "nutrition-0001")
        #expect(correlation.metadata?["healthloom.sourceDevice"] as? String == "Fitbit Air")

        let quantitySamples = correlation.objects.compactMap { $0 as? HKQuantitySample }
        #expect(quantitySamples.count == 4)

        func sample(for identifier: HKQuantityTypeIdentifier) -> HKQuantitySample? {
            quantitySamples.first { $0.quantityType == HKObjectType.quantityType(forIdentifier: identifier) }
        }

        let energy = sample(for: .dietaryEnergyConsumed)
        #expect(energy?.quantity == HKQuantity(unit: .kilocalorie(), doubleValue: 650))
        #expect(energy?.metadata?[HKMetadataKeyExternalUUID] as? String == "nutrition-0001#energy_kcal") // round-7 item 3

        let protein = sample(for: .dietaryProtein)
        #expect(protein?.quantity == HKQuantity(unit: .gram(), doubleValue: 35))
        #expect(protein?.metadata?[HKMetadataKeyExternalUUID] as? String == "nutrition-0001#protein_g") // round-7 item 3

        let carbs = sample(for: .dietaryCarbohydrates)
        #expect(carbs?.quantity == HKQuantity(unit: .gram(), doubleValue: 70))

        let fat = sample(for: .dietaryFatTotal)
        #expect(fat?.quantity == HKQuantity(unit: .gram(), doubleValue: 22))
    }

    /// The partial-macro meal (`nutrition-log-partial.json`) maps to a real
    /// `HKCorrelation` with exactly its two present constituents -- WP-13's
    /// "partial nutrient sets allowed" requirement proven at the real
    /// `HKObject` level, not just the pure `MappedDecision` level
    /// (`TypeMapperNutritionCorrelationTests.partialMacroMealGolden`).
    @Test func partialMacroMealMapsToRealHKCorrelationWithTwoConstituents() {
        let point = TypeMapperFixtures.nutritionLogPoint(
            id: "nutrition-0002",
            energyKcal: 120,
            proteinGrams: 18,
            carbsGrams: nil,
            fatGrams: nil
        )
        guard case .correlation(let correlation) = TypeMapper.map(point) else {
            Issue.record("expected .correlation")
            return
        }
        #expect(correlation.correlationType == HKObjectType.correlationType(forIdentifier: .food))
        #expect(correlation.objects.count == 2)
        let quantityTypes = Set(correlation.objects.compactMap { ($0 as? HKQuantitySample)?.quantityType })
        #expect(quantityTypes == [
            HKObjectType.quantityType(forIdentifier: .dietaryEnergyConsumed),
            HKObjectType.quantityType(forIdentifier: .dietaryProtein),
        ])
    }

    /// A meal with no macros at all stays `.skip` through the real
    /// HK-wrapping layer too -- never an empty `HKCorrelation`.
    @Test func mealWithNoMacrosStaysSkippedThroughMap() {
        let point = TypeMapperFixtures.nutritionLogPoint(
            energyKcal: nil, proteinGrams: nil, carbsGrams: nil, fatGrams: nil
        )
        guard case .skip = TypeMapper.map(point) else {
            Issue.record("expected .skip")
            return
        }
    }
}
#endif
