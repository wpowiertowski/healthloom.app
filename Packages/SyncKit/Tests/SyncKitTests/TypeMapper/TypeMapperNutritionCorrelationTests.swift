// TypeMapperNutritionCorrelationTests.swift
//
// WP-13 (implementation-plan.md) "Tests:" line: "golden meal with all
// nutrients; meal missing macros; correlation dedupe." This file covers the
// first two (HealthKit-free, exercising `TypeMapper.decide(_:)` only, same
// split WP-12's `TypeMapperExerciseTests.swift` established for a new sample
// kind); the real-`HKCorrelation` object checks live in the extension to
// `TypeMapperHealthKitMappingTests.swift`, and the dedupe requirement lives
// in `NutritionCorrelationSavingTests.swift` -- mirroring WP-12's own
// three-way split (`TypeMapperExerciseTests.swift` /
// `TypeMapperHealthKitMappingTests.swift` extension / `WorkoutSavingTests
// .swift`) exactly.

import CoreModel
import Foundation
import GoogleHealthClient
import Testing
@testable import SyncKit

@Suite struct TypeMapperNutritionCorrelationTests {
    /// `nutrition-log.json`'s `nutrition-0001` point: full macro set (650
    /// kcal, 35g protein, 70g carbs, 22g fat) -> one `.correlation` decision
    /// with all four constituents, each carrying the meal's own external ID
    /// (WP-13: "meal grouping key = Google log entry ID" -- see
    /// `MappedNutritionCorrelation`'s doc comment, MappedTypes.swift, for why
    /// that's just `point.id` under this mapper's one-point-per-meal
    /// assumption).
    @Test func fullMacroMealGolden() {
        guard case .correlation(let meal) = TypeMapper.decide(TypeMapperFixtures.nutritionLogPoint()) else {
            Issue.record("expected .correlation")
            return
        }
        #expect(meal.healthKitIdentifier == "HKCorrelationTypeIdentifierFood")
        #expect(meal.start == TypeMapperFixtures.date("2026-07-01T12:15:00Z"))
        #expect(meal.end == TypeMapperFixtures.date("2026-07-01T12:15:00Z"))
        #expect(meal.constituents.count == 4)
        #expect(meal.metadata.externalUUID == "nutrition-0001#meal") // round-7 item 3: derived UUID
        #expect(meal.metadata.externalID == "nutrition-0001")
        #expect(meal.metadata.sourceDevice == "Fitbit Air")

        func constituent(_ identifier: String) -> MappedQuantitySample? {
            meal.constituents.first { $0.healthKitIdentifier == identifier }
        }

        let energy = constituent("HKQuantityTypeIdentifierDietaryEnergyConsumed")
        #expect(energy?.unit == .kilocalorie)
        #expect(energy?.value == 650)

        let protein = constituent("HKQuantityTypeIdentifierDietaryProtein")
        #expect(protein?.unit == .gram)
        #expect(protein?.value == 35)

        let carbs = constituent("HKQuantityTypeIdentifierDietaryCarbohydrates")
        #expect(carbs?.unit == .gram)
        #expect(carbs?.value == 70)

        let fat = constituent("HKQuantityTypeIdentifierDietaryFatTotal")
        #expect(fat?.unit == .gram)
        #expect(fat?.value == 22)

        // Every constituent carries its own field-named UUID (round-7
        // item 3) — sharing one UUID across the meal made HealthKit
        // reject the batch.
        let uuids = Set(meal.constituents.map(\.metadata.externalUUID))
        #expect(uuids.count == meal.constituents.count)
        for sample in meal.constituents {
            #expect(sample.metadata.externalUUID.hasPrefix("nutrition-0001#"))
            #expect(sample.start == meal.start)
            #expect(sample.end == meal.end)
        }
    }

    /// `nutrition-log-partial.json`'s `nutrition-0002` point: only energy +
    /// protein reported -- WP-13's explicit "partial nutrient sets allowed"
    /// requirement. Must still produce a `.correlation`, with exactly the
    /// two present macros as constituents -- never `.skip`, and never a
    /// fabricated zero for the missing carbs/fat.
    @Test func partialMacroMealGolden() {
        let point = TypeMapperFixtures.nutritionLogPoint(
            id: "nutrition-0002",
            start: TypeMapperFixtures.date("2026-07-01T08:00:00Z"),
            end: TypeMapperFixtures.date("2026-07-01T08:00:00Z"),
            energyKcal: 120,
            proteinGrams: 18,
            carbsGrams: nil,
            fatGrams: nil
        )
        guard case .correlation(let meal) = TypeMapper.decide(point) else {
            Issue.record("expected .correlation")
            return
        }
        #expect(meal.constituents.count == 2)
        let identifiers = Set(meal.constituents.map(\.healthKitIdentifier))
        #expect(identifiers == [
            "HKQuantityTypeIdentifierDietaryEnergyConsumed",
            "HKQuantityTypeIdentifierDietaryProtein",
        ])
        #expect(!identifiers.contains("HKQuantityTypeIdentifierDietaryCarbohydrates"))
        #expect(!identifiers.contains("HKQuantityTypeIdentifierDietaryFatTotal"))
    }

    /// A meal reporting exactly one macro (the most extreme "partial" case)
    /// still produces a one-constituent correlation, not `.skip`.
    @Test func singleMacroMealStillProducesACorrelation() {
        let point = TypeMapperFixtures.nutritionLogPoint(
            energyKcal: 90, proteinGrams: nil, carbsGrams: nil, fatGrams: nil
        )
        guard case .correlation(let meal) = TypeMapper.decide(point) else {
            Issue.record("expected .correlation")
            return
        }
        #expect(meal.constituents.count == 1)
        #expect(meal.constituents[0].healthKitIdentifier == "HKQuantityTypeIdentifierDietaryEnergyConsumed")
    }

    /// A meal reporting *no* macros at all has nothing to correlate --
    /// `.skip`, never an empty `HKCorrelation` (same "never emit a
    /// degenerate empty result" rule `decideSleep`'s all-segments-dropped
    /// case already established, WP-07).
    @Test func mealWithNoMacrosAtAllRoutesToSkip() {
        let point = TypeMapperFixtures.nutritionLogPoint(
            energyKcal: nil, proteinGrams: nil, carbsGrams: nil, fatGrams: nil
        )
        #expect(TypeMapper.decide(point) == .skip)
    }

    /// Zero is an ordinary reading for any macro (e.g. 0g protein logged for
    /// a black coffee) -- kept, not dropped, matching every other WP-07/11
    /// "count >= 0" guard.
    @Test func zeroValuedMacroIsAccepted() {
        let point = TypeMapperFixtures.nutritionLogPoint(
            energyKcal: 0, proteinGrams: 0, carbsGrams: nil, fatGrams: nil
        )
        guard case .correlation(let meal) = TypeMapper.decide(point) else {
            Issue.record("expected .correlation")
            return
        }
        #expect(meal.constituents.count == 2)
        #expect(meal.constituents.allSatisfy { $0.value == 0 })
    }

    /// A negative macro reading is dropped *per field*, not the whole meal
    /// (same "drop just the bad field" philosophy `decideExercise`'s
    /// distance/energy handling established, WP-12) -- a single implausible
    /// value doesn't invalidate an otherwise-valid partial meal.
    @Test func negativeMacroIsDroppedButOthersSurvive() {
        let point = TypeMapperFixtures.nutritionLogPoint(
            energyKcal: 500, proteinGrams: -5, carbsGrams: 60, fatGrams: nil
        )
        guard case .correlation(let meal) = TypeMapper.decide(point) else {
            Issue.record("expected .correlation")
            return
        }
        let identifiers = Set(meal.constituents.map(\.healthKitIdentifier))
        #expect(identifiers == [
            "HKQuantityTypeIdentifierDietaryEnergyConsumed",
            "HKQuantityTypeIdentifierDietaryCarbohydrates",
        ])
        #expect(!identifiers.contains("HKQuantityTypeIdentifierDietaryProtein"))
    }

    /// If *every* reported macro happens to be negative, the meal has
    /// nothing left to correlate once each is dropped -- `.skip`, exactly
    /// like the "no macros at all" case above, not a crash or an empty
    /// correlation.
    @Test func allNegativeMacrosRoutesToSkip() {
        let point = TypeMapperFixtures.nutritionLogPoint(
            energyKcal: -1, proteinGrams: -1, carbsGrams: -1, fatGrams: -1
        )
        #expect(TypeMapper.decide(point) == .skip)
    }

    /// A reversed window drops the whole point before any macro is even
    /// inspected -- same up-front guard every other `decide*` function in
    /// this package applies.
    @Test func reversedWindowIsDropped() {
        let point = TypeMapperFixtures.nutritionLogPoint(
            start: TypeMapperFixtures.date("2026-07-01T01:00:00Z"),
            end: TypeMapperFixtures.date("2026-07-01T00:00:00Z")
        )
        #expect(TypeMapper.decide(point) == .skip)
    }

    /// Missing `values` entirely (no macro fields decoded at all) never
    /// crashes -- routes to `.skip`, same as the "no macros at all" case.
    @Test func missingValuesDictionaryRoutesToSkip() {
        let point = GoogleDataPoint(
            id: "nutrition-missing", dataType: .nutritionLog,
            start: TypeMapperFixtures.date("2026-07-01T12:00:00Z"),
            end: TypeMapperFixtures.date("2026-07-01T12:00:00Z"),
            source: DataSource(platform: nil, deviceDisplayName: nil, recordingMethod: nil),
            values: [:]
        )
        #expect(TypeMapper.decide(point) == .skip)
    }
}
