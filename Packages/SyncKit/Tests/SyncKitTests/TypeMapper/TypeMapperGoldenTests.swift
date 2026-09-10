// TypeMapperGoldenTests.swift
//
// WP-07 (implementation-plan.md) "Done when: golden-file tests pass for all
// four types." No HealthKit import -- these exercise `TypeMapper.decide(_:)`
// (TypeMapper.swift), the HealthKit-free decision layer, so they run
// identically on any platform `swift test` targets, per MappedTypes.swift's
// header. `TypeMapperHealthKitMappingTests.swift` (HealthKit/) additionally
// confirms `TypeMapper.map(_:)` wraps these same decisions into correct real
// `HKQuantitySample`/`HKCategorySample` objects.

import CoreModel
import Foundation
import GoogleHealthClient
import Testing
@testable import SyncKit

@Suite struct TypeMapperGoldenTests {
    /// steps.json's `steps-0001` -> `HKQuantityTypeIdentifierStepCount`,
    /// `.count`, value 482, exact dates, exact metadata.
    @Test func stepsGolden() {
        let point = TypeMapperFixtures.stepsPoint()
        guard case .quantity(let sample) = TypeMapper.decide(point) else {
            Issue.record("expected .quantity")
            return
        }
        #expect(sample.healthKitIdentifier == "HKQuantityTypeIdentifierStepCount")
        #expect(sample.unit == .count)
        #expect(sample.value == 482)
        #expect(sample.start == TypeMapperFixtures.date("2026-07-01T00:00:00Z"))
        #expect(sample.end == TypeMapperFixtures.date("2026-07-01T01:00:00Z"))
        #expect(sample.metadata.externalUUID == "steps-0001")
        #expect(sample.metadata.externalID == "steps-0001")
        #expect(sample.metadata.sourceDevice == "Fitbit Air")
    }

    /// heart-rate.json's `hr-0001` -> `HKQuantityTypeIdentifierHeartRate`,
    /// `.countPerMinute`, value 58, exact instant, exact metadata.
    @Test func heartRateGolden() {
        let point = TypeMapperFixtures.heartRatePoint()
        guard case .quantity(let sample) = TypeMapper.decide(point) else {
            Issue.record("expected .quantity")
            return
        }
        #expect(sample.healthKitIdentifier == "HKQuantityTypeIdentifierHeartRate")
        #expect(sample.unit == .countPerMinute)
        #expect(sample.value == 58)
        #expect(sample.start == TypeMapperFixtures.date("2026-07-01T07:30:00Z"))
        #expect(sample.end == TypeMapperFixtures.date("2026-07-01T07:30:00Z"))
        #expect(sample.metadata.externalUUID == "hr-0001")
        #expect(sample.metadata.externalID == "hr-0001")
        #expect(sample.metadata.sourceDevice == "Fitbit Air")
    }

    /// weight.json's `weight-0001` -> `HKQuantityTypeIdentifierBodyMass`,
    /// `.kilogram`, value 70.5 (fixture's documented kg assumption -- see
    /// TypeMapper.swift's `decideWeight` doc comment), exact instant, exact
    /// metadata (including the "Fitbit Aria Air" device name and manual-entry
    /// source, distinct from the other three fixtures' Fitbit Air/automatic).
    @Test func weightGolden() {
        let point = TypeMapperFixtures.weightPoint()
        guard case .quantity(let sample) = TypeMapper.decide(point) else {
            Issue.record("expected .quantity")
            return
        }
        #expect(sample.healthKitIdentifier == "HKQuantityTypeIdentifierBodyMass")
        #expect(sample.unit == .kilogram)
        #expect(sample.value == 70.5)
        #expect(sample.start == TypeMapperFixtures.date("2026-07-01T06:45:00Z"))
        #expect(sample.end == TypeMapperFixtures.date("2026-07-01T06:45:00Z"))
        #expect(sample.metadata.externalUUID == "weight-0001")
        #expect(sample.metadata.externalID == "weight-0001")
        #expect(sample.metadata.sourceDevice == "Fitbit Aria Air")
    }

    /// sleep.json's `sleep-0001`: five contiguous segments that already sit
    /// exactly on the session bounds, so no clamping/dropping should occur --
    /// exact 1:1 pass-through into five `HKCategoryTypeIdentifierSleepAnalysis`
    /// segments with the WP-07 step 3 stage map applied and shared session
    /// metadata on every segment.
    @Test func sleepGolden() {
        let point = TypeMapperFixtures.sleepPoint()
        guard case .category(let segments) = TypeMapper.decide(point) else {
            Issue.record("expected .category")
            return
        }
        #expect(segments.count == 5)
        let expected: [(MappedSleepStage, String, String)] = [
            (.awake, "2026-07-08T23:15:00Z", "2026-07-08T23:40:00Z"),
            (.asleepCore, "2026-07-08T23:40:00Z", "2026-07-09T01:10:00Z"),
            (.asleepDeep, "2026-07-09T01:10:00Z", "2026-07-09T02:00:00Z"),
            (.asleepREM, "2026-07-09T02:00:00Z", "2026-07-09T03:30:00Z"),
            (.asleepCore, "2026-07-09T03:30:00Z", "2026-07-09T06:45:00Z"),
        ]
        for (index, (segment, (stage, start, end))) in zip(segments, expected).enumerated() {
            #expect(segment.healthKitIdentifier == "HKCategoryTypeIdentifierSleepAnalysis")
            #expect(segment.stage == stage)
            #expect(segment.start == TypeMapperFixtures.date(start))
            #expect(segment.end == TypeMapperFixtures.date(end))
            // Round-7 item 3: per-segment derived UUIDs (stable index
            // roles); the bare point ID survives as externalID.
            #expect(segment.metadata.externalUUID == "sleep-0001#sleep-\(index)")
            #expect(segment.metadata.externalID == "sleep-0001")
            #expect(segment.metadata.sourceDevice == "Fitbit Air")
        }
    }

    // MARK: - WP-11: full TypeMapper table golden tests

    /// distance.json's `distance-0001` -> `HKQuantityTypeIdentifierDistanceWalkingRunning`,
    /// `.meter`, value 15.0 (already mm->m normalized upstream by
    /// GoogleHealthClient's `UnitNormalizer`).
    @Test func distanceGolden() {
        let point = TypeMapperFixtures.distancePoint()
        guard case .quantity(let sample) = TypeMapper.decide(point) else {
            Issue.record("expected .quantity")
            return
        }
        #expect(sample.healthKitIdentifier == "HKQuantityTypeIdentifierDistanceWalkingRunning")
        #expect(sample.unit == .meter)
        #expect(sample.value == 15.0)
        #expect(sample.start == TypeMapperFixtures.date("2026-07-01T07:00:00Z"))
        #expect(sample.end == TypeMapperFixtures.date("2026-07-01T07:20:00Z"))
        #expect(sample.metadata.externalUUID == "distance-0001")
    }

    /// floors.json's `floors-0001` -> `HKQuantityTypeIdentifierFlightsClimbed`,
    /// `.count`, value 6.
    @Test func floorsGolden() {
        let point = TypeMapperFixtures.floorsPoint()
        guard case .quantity(let sample) = TypeMapper.decide(point) else {
            Issue.record("expected .quantity")
            return
        }
        #expect(sample.healthKitIdentifier == "HKQuantityTypeIdentifierFlightsClimbed")
        #expect(sample.unit == .count)
        #expect(sample.value == 6)
        #expect(sample.metadata.externalUUID == "floors-0001")
    }

    /// active-energy-burned.json's `aeb-0001` -> `HKQuantityTypeIdentifierActiveEnergyBurned`,
    /// `.kilocalorie`, value 312.5 -- Google's single total mapped straight
    /// to active energy, no basal split invented (WP-11).
    @Test func activeEnergyBurnedGolden() {
        let point = TypeMapperFixtures.activeEnergyBurnedPoint()
        guard case .quantity(let sample) = TypeMapper.decide(point) else {
            Issue.record("expected .quantity")
            return
        }
        #expect(sample.healthKitIdentifier == "HKQuantityTypeIdentifierActiveEnergyBurned")
        #expect(sample.unit == .kilocalorie)
        #expect(sample.value == 312.5)
        #expect(sample.metadata.externalUUID == "aeb-0001")
    }

    /// daily-resting-heart-rate.json's `drhr-0001` -> `HKQuantityTypeIdentifierRestingHeartRate`,
    /// `.countPerMinute`, value 52, full-day interval.
    @Test func restingHeartRateGolden() {
        let point = TypeMapperFixtures.restingHeartRatePoint()
        guard case .quantity(let sample) = TypeMapper.decide(point) else {
            Issue.record("expected .quantity")
            return
        }
        #expect(sample.healthKitIdentifier == "HKQuantityTypeIdentifierRestingHeartRate")
        #expect(sample.unit == .countPerMinute)
        #expect(sample.value == 52)
        #expect(sample.start == TypeMapperFixtures.date("2026-07-01T00:00:00Z"))
        #expect(sample.end == TypeMapperFixtures.date("2026-07-02T00:00:00Z"))
    }

    /// heart-rate-variability.json's `hrv-0001` -> `.localOnly`, **not**
    /// `HKQuantityTypeIdentifierHeartRateVariabilitySDNN` -- WP-11's pinned
    /// decision (base-knowledge.md gives no way to confirm Google's HRV
    /// metric is SDNN rather than RMSSD; see `decideHeartRateVariability`'s
    /// doc comment in TypeMapper.swift for the full reasoning). This is the
    /// one row in this suite where CoreModel's writability table names an
    /// available HealthKit target (`GoogleDataType.heartRateVariability
    /// .writability`) that `TypeMapper` deliberately never uses.
    @Test func heartRateVariabilityRoutesToLocalOnlyNotSDNN() {
        let point = TypeMapperFixtures.heartRateVariabilityPoint()
        #expect(TypeMapper.decide(point) == .localOnly)
        // Confirms the writability table *does* declare an available
        // target -- this test is asserting TypeMapper's deliberate
        // override of that availability, not a routing bug upstream.
        if case .healthKit(let identifier) = GoogleDataType.heartRateVariability.writability {
            #expect(identifier == "HKQuantityTypeIdentifierHeartRateVariabilitySDNN")
        } else {
            Issue.record("expected CoreModel's writability table to still declare a healthKit target")
        }
    }

    /// oxygen-saturation.json's `spo2-0001` -> `HKQuantityTypeIdentifierOxygenSaturation`,
    /// `.fraction`, wire `97`% converted to `0.97` (WP-11: "SpO2 fraction
    /// 0-1 in HK!").
    @Test func oxygenSaturationGoldenConvertsPercentToFraction() {
        let point = TypeMapperFixtures.oxygenSaturationPoint(percentage: 97)
        guard case .quantity(let sample) = TypeMapper.decide(point) else {
            Issue.record("expected .quantity")
            return
        }
        #expect(sample.healthKitIdentifier == "HKQuantityTypeIdentifierOxygenSaturation")
        #expect(sample.unit == .fraction)
        #expect(sample.value == 0.97)
        #expect((0.0...1.0).contains(sample.value))
    }

    /// respiratory-rate.json's `rr-0001` -> `HKQuantityTypeIdentifierRespiratoryRate`,
    /// `.countPerMinute`, value 14.5.
    @Test func respiratoryRateGolden() {
        let point = TypeMapperFixtures.respiratoryRatePoint()
        guard case .quantity(let sample) = TypeMapper.decide(point) else {
            Issue.record("expected .quantity")
            return
        }
        #expect(sample.healthKitIdentifier == "HKQuantityTypeIdentifierRespiratoryRate")
        #expect(sample.unit == .countPerMinute)
        #expect(sample.value == 14.5)
    }

    /// vo2-max.json's `vo2-0001` -> `HKQuantityTypeIdentifierVO2Max`,
    /// `.vo2MaxUnit`, value 42.3.
    @Test func vo2MaxGolden() {
        let point = TypeMapperFixtures.vo2MaxPoint(dataType: .vo2Max)
        guard case .quantity(let sample) = TypeMapper.decide(point) else {
            Issue.record("expected .quantity")
            return
        }
        #expect(sample.healthKitIdentifier == "HKQuantityTypeIdentifierVO2Max")
        #expect(sample.unit == .vo2MaxUnit)
        #expect(sample.value == 42.3)
    }

    /// run-vo2-max.json's `run-vo2-0001` -- a distinct Google type
    /// (`.runVO2Max`) sharing the same HealthKit identifier as plain VO2
    /// Max (base-knowledge.md §5).
    @Test func runVO2MaxGoldenSharesVO2MaxIdentifier() {
        let point = TypeMapperFixtures.vo2MaxPoint(id: "run-vo2-0001", dataType: .runVO2Max, value: 45.1)
        guard case .quantity(let sample) = TypeMapper.decide(point) else {
            Issue.record("expected .quantity")
            return
        }
        #expect(sample.healthKitIdentifier == "HKQuantityTypeIdentifierVO2Max")
        #expect(sample.unit == .vo2MaxUnit)
        #expect(sample.value == 45.1)
        #expect(sample.metadata.externalUUID == "run-vo2-0001")
    }

    /// height.json's `height-0001` -> `HKQuantityTypeIdentifierHeight`,
    /// `.meter`, value 1.78, manual entry.
    @Test func heightGolden() {
        let point = TypeMapperFixtures.heightPoint()
        guard case .quantity(let sample) = TypeMapper.decide(point) else {
            Issue.record("expected .quantity")
            return
        }
        #expect(sample.healthKitIdentifier == "HKQuantityTypeIdentifierHeight")
        #expect(sample.unit == .meter)
        #expect(sample.value == 1.78)
        #expect(sample.metadata.sourceDevice == "Fitbit Aria Air")
    }

    /// body-fat.json's `bf-0001` -> `HKQuantityTypeIdentifierBodyFatPercentage`,
    /// `.fraction`, wire `22`% converted to `0.22` (WP-11: "body fat
    /// fraction in HK").
    @Test func bodyFatGoldenConvertsPercentToFraction() {
        let point = TypeMapperFixtures.bodyFatPoint(percentage: 22)
        guard case .quantity(let sample) = TypeMapper.decide(point) else {
            Issue.record("expected .quantity")
            return
        }
        #expect(sample.healthKitIdentifier == "HKQuantityTypeIdentifierBodyFatPercentage")
        #expect(sample.unit == .fraction)
        #expect(sample.value == 0.22)
        #expect((0.0...1.0).contains(sample.value))
    }

    /// blood-glucose-mgdl.json's `bg-mgdl-0001` -> `HKQuantityTypeIdentifierBloodGlucose`,
    /// `.milligramsPerDeciliter`, value 98 -- the US-conventional unit
    /// fixture variant (WP-11: "unit from payload - mg/dL vs mmol/L, both
    /// fixture variants").
    @Test func bloodGlucoseMgDLGolden() {
        let point = TypeMapperFixtures.bloodGlucoseMgDLPoint()
        guard case .quantity(let sample) = TypeMapper.decide(point) else {
            Issue.record("expected .quantity")
            return
        }
        #expect(sample.healthKitIdentifier == "HKQuantityTypeIdentifierBloodGlucose")
        #expect(sample.unit == .milligramsPerDeciliter)
        #expect(sample.value == 98)
    }

    /// blood-glucose-mmol.json's `bg-mmol-0001` -> `HKQuantityTypeIdentifierBloodGlucose`,
    /// `.millimolesPerLiter`, value 5.4 -- the mmol/L fixture variant. Never
    /// converted against the mg/dL variant above -- each unit is passed
    /// through in its own `MappedUnit`, no cross-unit math performed here.
    @Test func bloodGlucoseMmolLGolden() {
        let point = TypeMapperFixtures.bloodGlucoseMmolLPoint()
        guard case .quantity(let sample) = TypeMapper.decide(point) else {
            Issue.record("expected .quantity")
            return
        }
        #expect(sample.healthKitIdentifier == "HKQuantityTypeIdentifierBloodGlucose")
        #expect(sample.unit == .millimolesPerLiter)
        #expect(sample.value == 5.4)
    }

    /// core-body-temperature.json's `cbt-0001` -> `HKQuantityTypeIdentifierBodyTemperature`,
    /// `.degreeCelsius`, value 37.1.
    @Test func coreBodyTemperatureGolden() {
        let point = TypeMapperFixtures.coreBodyTemperaturePoint()
        guard case .quantity(let sample) = TypeMapper.decide(point) else {
            Issue.record("expected .quantity")
            return
        }
        #expect(sample.healthKitIdentifier == "HKQuantityTypeIdentifierBodyTemperature")
        #expect(sample.unit == .degreeCelsius)
        #expect(sample.value == 37.1)
    }

    /// hydration-log.json's `hydration-0001` -> `HKQuantityTypeIdentifierDietaryWater`,
    /// `.liter`, value 0.5.
    @Test func hydrationGolden() {
        let point = TypeMapperFixtures.hydrationPoint()
        guard case .quantity(let sample) = TypeMapper.decide(point) else {
            Issue.record("expected .quantity")
            return
        }
        #expect(sample.healthKitIdentifier == "HKQuantityTypeIdentifierDietaryWater")
        #expect(sample.unit == .liter)
        #expect(sample.value == 0.5)
    }

    // MARK: - Routing (WP-07 step 5)

    /// ECG/Active Zone Minutes/Active Minutes/Irregular Rhythm Notification
    /// are `.localOnly` in CoreModel's writability table (architecture.md D2)
    /// -- routed there via that table, not a hand-duplicated list.
    @Test func localOnlyTypesRouteToLocalOnly() {
        for dataType in [
            GoogleDataType.electrocardiogram, .activeZoneMinutes,
            .activeMinutes, .irregularRhythmNotification,
        ] {
            let point = GoogleDataPoint(
                id: "x", dataType: dataType,
                start: TypeMapperFixtures.date("2026-07-01T00:00:00Z"),
                end: TypeMapperFixtures.date("2026-07-01T00:00:00Z"),
                source: DataSource(platform: nil, deviceDisplayName: nil, recordingMethod: nil),
                values: [:]
            )
            #expect(TypeMapper.decide(point) == .localOnly)
        }
    }

    /// A `.skip`-writability type (e.g. a redundant daily-rollup duplicate)
    /// never crashes and never emits a sample.
    @Test func skipWritabilityTypeRoutesToSkip() {
        let point = GoogleDataPoint(
            id: "x", dataType: .altitude,
            start: TypeMapperFixtures.date("2026-07-01T00:00:00Z"),
            end: TypeMapperFixtures.date("2026-07-01T00:00:00Z"),
            source: DataSource(platform: nil, deviceDisplayName: nil, recordingMethod: nil),
            values: [:]
        )
        #expect(TypeMapper.decide(point) == .skip)
    }

    /// A `.healthKit`-writability type this package deliberately never
    /// writes falls to `.skip` -- see `decideHealthKitMapped`'s `default`
    /// case doc comment (TypeMapper.swift). (Distance, then Exercise, were
    /// this test's exemplar before WP-11 and WP-12 respectively implemented
    /// them -- see `distanceGolden` below and `TypeMapperExerciseTests
    /// .swift`. WP-13 implements Nutrition Log, the last previously-bare
    /// `.healthKit` row, which retires this test's original premise: every
    /// `.healthKit`-writability `GoogleDataType` now either has a real
    /// mapping or a *documented, deliberate* non-write decision --
    /// `.totalCalories` (see `totalCaloriesRoutesToSkip` above) and `.food`
    /// (this test's new exemplar: base-knowledge.md §3 never marks plain
    /// "Food" ✅-writable, unlike "Nutrition Log", despite CoreModel's
    /// writability table pairing both under the same
    /// `HKCorrelationTypeIdentifierFood` sentinel) are the two remaining
    /// `default`-routed cases, not "not implemented yet" placeholders.
    /// Renamed accordingly so this test keeps testing what its name says.)
    @Test func foodRoutesToSkipDeliberately() {
        let point = GoogleDataPoint(
            id: "x", dataType: .food,
            start: TypeMapperFixtures.date("2026-07-01T00:00:00Z"),
            end: TypeMapperFixtures.date("2026-07-01T01:00:00Z"),
            source: DataSource(platform: nil, deviceDisplayName: nil, recordingMethod: nil),
            values: [:]
        )
        #expect(TypeMapper.decide(point) == .skip)
    }

    /// `.totalCalories` is deliberately never written (WP-11: don't invent a
    /// basal-only split from Google's single total) -- see
    /// `decideHealthKitMapped`'s `default` case doc comment.
    @Test func totalCaloriesRoutesToSkip() {
        let point = GoogleDataPoint(
            id: "x", dataType: .totalCalories,
            start: TypeMapperFixtures.date("2026-07-01T00:00:00Z"),
            end: TypeMapperFixtures.date("2026-07-01T01:00:00Z"),
            source: DataSource(platform: nil, deviceDisplayName: nil, recordingMethod: nil),
            values: ["kcal": 500]
        )
        #expect(TypeMapper.decide(point) == .skip)
    }

    /// Missing the expected scalar field entirely (decode produced no
    /// `values["count"]`) never crashes -- drops instead.
    @Test func missingExpectedFieldRoutesToSkip() {
        let point = GoogleDataPoint(
            id: "steps-missing", dataType: .steps,
            start: TypeMapperFixtures.date("2026-07-01T00:00:00Z"),
            end: TypeMapperFixtures.date("2026-07-01T01:00:00Z"),
            source: DataSource(platform: nil, deviceDisplayName: nil, recordingMethod: nil),
            values: [:]
        )
        #expect(TypeMapper.decide(point) == .skip)
    }

    /// A `nil` device display name (Google didn't report one) is carried
    /// through as `nil`, not coerced into an empty string or a crash.
    @Test func missingDeviceDisplayNameStaysNil() {
        let point = TypeMapperFixtures.stepsPoint(deviceDisplayName: nil)
        guard case .quantity(let sample) = TypeMapper.decide(point) else {
            Issue.record("expected .quantity")
            return
        }
        #expect(sample.metadata.sourceDevice == nil)
    }
}
