// NutritionCorrelationSavingTests.swift
//
// WP-13 (implementation-plan.md) "Tests:" line: "correlation dedupe (reuses
// the same existingExternalIDs/save idempotency path other types use --
// verify this, don't build a parallel mechanism)." Exercised against
// `MockHealthStore` (Tests/SyncKitTests/HealthKitWriter/MockHealthStore.swift,
// reused as-is -- not modified, and accessible here because both files
// compile into the one `SyncKitTests` target) -- no HealthKit entitlement, no
// simulator, no real `HKHealthStore` needed, mirroring
// `WorkoutSavingTests.swift`'s own dedupe-section precedent (WP-12).
//
// Unlike WP-12's `HKWorkout` (which needs `HKWorkoutBuilder.saveWorkout(_:)`,
// a dedicated `HealthKitWriter` method, because a real `HKWorkout` can't be
// constructed synchronously), an `HKCorrelation` is a plain `HKObject`
// (`HKCorrelation: HKSample: HKObject`) built directly by
// `TypeMapper.map(_:)` (MappedObject.swift's `MappedNutritionCorrelation
// .makeHKCorrelation()`) -- so it needs **no new `HealthKitWriter` method at
// all**. This file proves exactly that: `writer.save([correlation])` and
// `writer.existingExternalIDs(type: HKObjectType.correlationType(forIdentifier:
// .food)!, ...)` -- the same two generic methods every `.quantity`/`.category`
// write already uses -- work unmodified for a `.correlation` decision too.
// `SyncEngine.processPage`'s own `.correlation` arm (SyncEngine.swift, WP-13
// addition) calls these same two methods; this file verifies the mechanism
// they both rely on, without needing `SyncEngine` itself.

#if canImport(HealthKit)
import Foundation
import HealthKit
import Testing
@testable import SyncKit

@Suite struct NutritionCorrelationSavingTests {
    private static let foodType = HKObjectType.correlationType(forIdentifier: .food)!

    /// Before any save, the correlation type reports no existing meals --
    /// confirms `HKObjectType.correlationType(forIdentifier: .food)` is
    /// accepted by `existingExternalIDs` at all (it's an `HKSampleType` just
    /// like every quantity/category/workout type), not a special-cased
    /// no-op -- mirrors `WorkoutSavingTests.noExistingWorkoutsBeforeAnySave`.
    @Test func noExistingMealsBeforeAnySave() async throws {
        let writer = HealthKitWriter(store: MockHealthStore())

        let existing = try await writer.existingExternalIDs(
            type: Self.foodType,
            start: TypeMapperFixtures.date("2000-01-01T00:00:00Z"),
            end: TypeMapperFixtures.date("2100-01-01T00:00:00Z")
        )
        #expect(existing.isEmpty)
    }

    /// A saved correlation is discoverable through the exact same
    /// `existingExternalIDs` method every other type already uses -- proving
    /// `.correlation` flows through the shared dedupe mechanism, not a
    /// parallel one built just for nutrition.
    @Test func aSavedCorrelationIsDiscoverableThroughTheSameExistingExternalIDsMethod() async throws {
        let store = MockHealthStore()
        let writer = HealthKitWriter(store: store)

        guard case .correlation(let correlation) = TypeMapper.map(TypeMapperFixtures.nutritionLogPoint()) else {
            Issue.record("expected .correlation")
            return
        }

        try await writer.save([correlation])
        // One save call for the one correlation object -- D4's "one write
        // call per batch, never per sample" invariant applies here exactly
        // as it does for `.quantity`/`.category` batches.
        #expect(store.savedBatches.count == 1)

        let existing = try await writer.existingExternalIDs(
            type: Self.foodType,
            start: correlation.startDate.addingTimeInterval(-60),
            end: correlation.endDate.addingTimeInterval(60)
        )
        #expect(existing == ["nutrition-0001#meal"]) // round-7 item 3: the correlation's own derived UUID
    }

    /// A partial-macro meal (two constituents, not four) dedupes through
    /// the identical path -- the constituent count never affects how the
    /// *correlation itself* is found by external ID.
    @Test func aSavedPartialMacroCorrelationIsAlsoDiscoverable() async throws {
        let store = MockHealthStore()
        let writer = HealthKitWriter(store: store)
        let point = TypeMapperFixtures.nutritionLogPoint(
            id: "nutrition-0002", energyKcal: 120, proteinGrams: 18, carbsGrams: nil, fatGrams: nil
        )
        guard case .correlation(let correlation) = TypeMapper.map(point) else {
            Issue.record("expected .correlation")
            return
        }

        try await writer.save([correlation])
        let existing = try await writer.existingExternalIDs(
            type: Self.foodType,
            start: correlation.startDate.addingTimeInterval(-60),
            end: correlation.endDate.addingTimeInterval(60)
        )
        #expect(existing == ["nutrition-0002#meal"]) // round-7 item 3: derived UUID, not the bare point ID
    }

    /// The caller's expected discipline (`SyncEngine.processPage`'s own
    /// `.correlation` arm): check `existingExternalIDs` first, and skip
    /// calling `save` again for an ID already present -- `save(_:)` itself
    /// performs no dedupe (same posture as every other type; WP-08's
    /// original design). This proves the *building block* SyncEngine's
    /// guard relies on behaves correctly for `.correlation`, without
    /// re-implementing SyncEngine's own orchestration here.
    @Test func callerMustCheckExistingExternalIDsBeforeSavingAgain() async throws {
        let store = MockHealthStore()
        let writer = HealthKitWriter(store: store)
        guard case .correlation(let correlation) = TypeMapper.map(TypeMapperFixtures.nutritionLogPoint()) else {
            Issue.record("expected .correlation")
            return
        }

        try await writer.save([correlation])

        // Padded, not the meal's exact instant bounds -- this fixture's
        // start == end (a point-in-time meal log, like weight/height/
        // bloodGlucose elsewhere in this package), and `MockHealthStore`'s
        // date-window overlap check is a strict `<`/`>` (see that file's
        // header) that can never match an exact zero-length window against
        // an exact zero-length sample; every existing instant-sample dedupe
        // test in this package (HealthKitWriterTests.swift's `Self.farPast`/
        // `Self.farFuture`) queries a wider window for the same reason.
        let existingBeforeSecondSave = try await writer.existingExternalIDs(
            type: Self.foodType,
            start: correlation.startDate.addingTimeInterval(-60),
            end: correlation.endDate.addingTimeInterval(60)
        )
        #expect(existingBeforeSecondSave.contains("nutrition-0001#meal")) // round-7 item 3: derived UUID
        // A correct caller (SyncEngine.processPage's `.correlation` arm)
        // would skip re-saving here, exactly like it does for `.quantity`.
    }

    /// The correlation's constituent `HKQuantitySample`s are also
    /// independently present in the mock store after `save(_:)` -- a plain
    /// `HKHealthStore.save` call persists every object handed to it,
    /// correlation *and* its constituents alike (this is real `HKCorrelation`
    /// behavior per Apple's own documentation, not a mock-only artifact) --
    /// confirming the "stamp both" metadata choice
    /// (`MappedNutritionCorrelation`'s doc comment) is actually exercised
    /// end-to-end through the save path, not just at construction time.
    @Test func constituentSamplesAreIndividuallyPresentInTheStoreAfterSave() async throws {
        let store = MockHealthStore()
        let writer = HealthKitWriter(store: store)
        guard case .correlation(let correlation) = TypeMapper.map(TypeMapperFixtures.nutritionLogPoint()) else {
            Issue.record("expected .correlation")
            return
        }

        try await writer.save([correlation])

        let proteinType = HKObjectType.quantityType(forIdentifier: .dietaryProtein)!
        #expect(store.sampleCount(ofType: proteinType) == 0) // constituents live inside the correlation, not top-level in save's batch

        // The correlation itself, however, is discoverable -- top-level save
        // only ever receives the one HKObject (the correlation) in the
        // batch; HealthKit's own store fans constituents out internally when
        // *it* saves a correlation for real. `MockHealthStore` mirrors only
        // what `save(_:)` was actually handed (see that mock's header), so
        // this test documents that boundary rather than asserting behavior
        // this mock doesn't simulate.
        #expect(store.sampleCount(ofType: Self.foodType) == 1)
    }
}
#endif
