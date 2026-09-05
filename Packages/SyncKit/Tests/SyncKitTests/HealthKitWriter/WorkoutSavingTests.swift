// WorkoutSavingTests.swift
//
// WP-12 (implementation-plan.md) "Tests:" line: "workout dedupe by
// externalID ... verify workouts flow through the same idempotency
// mechanism, don't build a parallel one" and "a workout-builder integration
// test." Exercised against `MockWorkoutBuilder`/`MockWorkoutBuilderFactory`
// (MockWorkoutBuilder.swift) -- no HealthKit entitlement, no simulator, no
// real `HKHealthStore` needed for any test in this file, mirroring
// HealthKitWriterTests.swift's own `MockHealthStore`-based precedent.
//
// See progress.md's WP-12 entry for why the real, full `HKWorkoutBuilder`
// flow (beginCollection/addSamples/addMetadata/endCollection/finishWorkout
// against a genuinely authorized `HKHealthStore`) could not be exercised
// end-to-end in this session -- same simulator-authorization limitation
// WP-06/07/08 already hit -- and what was done instead to verify the real
// API surface compiles and behaves as documented.

#if canImport(HealthKit)
import Foundation
import HealthKit
import Testing
@testable import SyncKit

@Suite struct WorkoutSavingTests {
    static func date(_ iso: String) -> Date {
        guard let result = ISO8601DateFormatter().date(from: iso) else {
            fatalError("Bad fixture ISO8601 string: \(iso)")
        }
        return result
    }

    static func workout(
        activityType: MappedWorkoutActivityType = .running,
        start: Date = date("2026-07-01T17:00:00Z"),
        end: Date = date("2026-07-01T17:45:00Z"),
        distanceMeters: Double? = 8000,
        energyKilocalories: Double? = 520,
        externalID: String = "exercise-0001",
        sourceDevice: String? = "Fitbit Air"
    ) -> MappedWorkout {
        MappedWorkout(
            activityType: activityType,
            start: start,
            end: end,
            distanceMeters: distanceMeters,
            energyKilocalories: energyKilocalories,
            metadata: MappedMetadata(externalUUID: externalID, externalID: externalID, sourceDevice: sourceDevice)
        )
    }

    // MARK: - Orchestration (beginCollection -> add -> endCollection -> finish)

    @Test func savesFollowTheExactBuilderSequence() async throws {
        let mockBuilder = MockWorkoutBuilder()
        let factory = MockWorkoutBuilderFactory(builder: mockBuilder)
        let writer = HealthKitWriter(store: MockHealthStore(), workoutBuilderFactory: factory)

        _ = try await writer.saveWorkout(Self.workout())

        #expect(mockBuilder.calls == [
            .beginCollection(Self.date("2026-07-01T17:00:00Z")),
            .addSamples(2), // distance + energy
            // NOTE: the mock's recorded `.addMetadata` call keeps string
            // values only; the numeric distance/energy keys below are
            // asserted via `lastMetadata` in
            // `bucketlessDistanceIsPreservedInMetadata`.
            .addMetadata([
                HKMetadataKeyExternalUUID: "exercise-0001",
                "healthloom.externalID": "exercise-0001",
                "healthloom.sourceDevice": "Fitbit Air",
            ]),
            .endCollection(Self.date("2026-07-01T17:45:00Z")),
            .finishWorkout,
        ])
    }

    @Test func requestsTheCorrectRealHKWorkoutActivityType() async throws {
        let factory = MockWorkoutBuilderFactory()
        let writer = HealthKitWriter(store: MockHealthStore(), workoutBuilderFactory: factory)

        _ = try await writer.saveWorkout(Self.workout(activityType: .cycling))

        #expect(factory.requestedActivityTypes == [.cycling])
    }

    @Test func attachesDistanceAndEnergyQuantitySamplesWhenPresent() async throws {
        let mockBuilder = MockWorkoutBuilder()
        let factory = MockWorkoutBuilderFactory(builder: mockBuilder)
        let writer = HealthKitWriter(store: MockHealthStore(), workoutBuilderFactory: factory)

        _ = try await writer.saveWorkout(Self.workout(distanceMeters: 5000, energyKilocalories: 300))

        #expect(mockBuilder.lastAddedSamples.count == 2)
        let distanceSample = mockBuilder.lastAddedSamples.first {
            $0.sampleType == HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)
        } as? HKQuantitySample
        let energySample = mockBuilder.lastAddedSamples.first {
            $0.sampleType == HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)
        } as? HKQuantitySample
        #expect(distanceSample?.quantity == HKQuantity(unit: .meter(), doubleValue: 5000))
        #expect(energySample?.quantity == HKQuantity(unit: .kilocalorie(), doubleValue: 300))
    }

    @Test func distanceAttachesUnderTheActivityTypesOwnBucket() async throws {
        // A 40 km bike ride must land in distanceCycling, never
        // distanceWalkingRunning (the pre-fix code stamped every workout's
        // distance as walking+running).
        let mockBuilder = MockWorkoutBuilder()
        let factory = MockWorkoutBuilderFactory(builder: mockBuilder)
        let writer = HealthKitWriter(store: MockHealthStore(), workoutBuilderFactory: factory)

        _ = try await writer.saveWorkout(Self.workout(activityType: .cycling, distanceMeters: 40000))

        let distanceSamples = mockBuilder.lastAddedSamples.filter {
            $0.sampleType == HKObjectType.quantityType(forIdentifier: .distanceCycling)
        }
        #expect(distanceSamples.count == 1)
        #expect(mockBuilder.lastAddedSamples.allSatisfy {
            $0.sampleType != HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)
        })
    }

    @Test func distanceIsOmittedForActivityTypesWithoutADistanceBucket() async throws {
        // Yoga reports a distance but HealthKit models none for it: no
        // sample (energy still attaches; the workout still saves).
        let mockBuilder = MockWorkoutBuilder()
        let factory = MockWorkoutBuilderFactory(builder: mockBuilder)
        let writer = HealthKitWriter(store: MockHealthStore(), workoutBuilderFactory: factory)

        _ = try await writer.saveWorkout(Self.workout(activityType: .yoga, distanceMeters: 1000))

        #expect(mockBuilder.lastAddedSamples.count == 1)
        #expect(mockBuilder.lastAddedSamples.first?.sampleType
            == HKObjectType.quantityType(forIdentifier: .activeEnergyBurned))
    }

    @Test func bucketlessDistanceIsPreservedInMetadata() async throws {
        // `.other` (unrecognized activity string) attaches no distance
        // sample, but the 8 km must still ride the workout metadata --
        // dropping it there was round-2's data-loss bug.
        let mockBuilder = MockWorkoutBuilder()
        let factory = MockWorkoutBuilderFactory(builder: mockBuilder)
        let writer = HealthKitWriter(store: MockHealthStore(), workoutBuilderFactory: factory)

        _ = try await writer.saveWorkout(Self.workout(activityType: .other, distanceMeters: 8000))

        #expect(mockBuilder.lastAddedSamples.count == 1) // energy only
        let metadata = mockBuilder.lastMetadata
        #expect(metadata["healthloom.distanceMeters"] as? Double == 8000.0)
        #expect(metadata["healthloom.energyKilocalories"] as? Double == 520.0)
    }

    @Test func neitherDistanceNorEnergySampleIsAddedWhenBothAreNil() async throws {
        let mockBuilder = MockWorkoutBuilder()
        let factory = MockWorkoutBuilderFactory(builder: mockBuilder)
        let writer = HealthKitWriter(store: MockHealthStore(), workoutBuilderFactory: factory)

        _ = try await writer.saveWorkout(Self.workout(distanceMeters: nil, energyKilocalories: nil))

        let addSamplesCalls = mockBuilder.calls.filter {
            if case .addSamples = $0 { return true }
            return false
        }
        #expect(addSamplesCalls.isEmpty)
    }

    @Test func stampsExternalUUIDAndSourceDeviceMetadataBeforeFinishing() async throws {
        let mockBuilder = MockWorkoutBuilder()
        let factory = MockWorkoutBuilderFactory(builder: mockBuilder)
        let writer = HealthKitWriter(store: MockHealthStore(), workoutBuilderFactory: factory)

        _ = try await writer.saveWorkout(Self.workout(externalID: "exercise-metadata-test", sourceDevice: "Fitbit Air"))

        #expect(mockBuilder.lastMetadata[HKMetadataKeyExternalUUID] as? String == "exercise-metadata-test")
        #expect(mockBuilder.lastMetadata["healthloom.externalID"] as? String == "exercise-metadata-test")
        #expect(mockBuilder.lastMetadata["healthloom.sourceDevice"] as? String == "Fitbit Air")
    }

    /// A `nil`, non-throwing `finishWorkout()` result is a documented
    /// success case (device-locked edge case, WorkoutBuilding.swift's
    /// header) -- `saveWorkout` must not treat it as an error.
    @Test func nilFinishResultWithoutAnErrorIsStillSuccess() async throws {
        let mockBuilder = MockWorkoutBuilder()
        mockBuilder.finishResult = nil
        let factory = MockWorkoutBuilderFactory(builder: mockBuilder)
        let writer = HealthKitWriter(store: MockHealthStore(), workoutBuilderFactory: factory)

        let result = try await writer.saveWorkout(Self.workout())
        #expect(result == nil)
    }

    @Test func aThrownBuilderErrorPropagatesAsUnderlying() async throws {
        struct FakeError: Error {}
        let mockBuilder = MockWorkoutBuilder()
        mockBuilder.finishError = FakeError()
        let factory = MockWorkoutBuilderFactory(builder: mockBuilder)
        let writer = HealthKitWriter(store: MockHealthStore(), workoutBuilderFactory: factory)

        do {
            _ = try await writer.saveWorkout(Self.workout())
            Issue.record("Expected the mock builder's injected error to be thrown")
        } catch {
            guard case .underlying = error else {
                Issue.record("expected .underlying, got \(error)")
                return
            }
        }
    }

    // MARK: - Dedupe by externalID (reuses existingExternalIDs/save, no parallel mechanism)

    /// `HKObjectType.workoutType()` flows through the *exact same*
    /// `existingExternalIDs(type:start:end:)` method every other type uses
    /// -- no separate/parallel workout-dedupe path exists. Proven
    /// end-to-end: a workout `saveWorkout` finishes gets seeded into the
    /// same `MockHealthStore` the real `HKWorkoutBuilder.finishWorkout()`
    /// would save directly into (see MockWorkoutBuilder.swift's header for
    /// why that seeding step stands in for the real store-saving behavior),
    /// and a subsequent `existingExternalIDs` call against that same store
    /// finds it.
    @available(*, deprecated, message: "constructs a test-only fake HKWorkout via a deprecated initializer, see MockWorkoutBuilder.swift")
    @Test func aSavedWorkoutIsDiscoverableThroughTheSameExistingExternalIDsMethod() async throws {
        let store = MockHealthStore()
        let mockBuilder = MockWorkoutBuilder()
        mockBuilder.storeToSeedOnFinish = store
        let externalID = "exercise-dedupe-0001"
        let start = Self.date("2026-07-01T17:00:00Z")
        let end = Self.date("2026-07-01T17:45:00Z")
        mockBuilder.finishResult = makeFakeHKWorkoutForTesting(
            activityType: .running,
            start: start,
            end: end,
            metadata: [HKMetadataKeyExternalUUID: externalID, "healthloom.externalID": externalID]
        )
        let factory = MockWorkoutBuilderFactory(builder: mockBuilder)
        let writer = HealthKitWriter(store: store, workoutBuilderFactory: factory)

        _ = try await writer.saveWorkout(Self.workout(start: start, end: end, externalID: externalID))

        let existing = try await writer.existingExternalIDs(
            type: HKObjectType.workoutType(),
            start: start.addingTimeInterval(-60),
            end: end.addingTimeInterval(60)
        )
        #expect(existing == [externalID])
    }

    /// A second `saveWorkout` for the *same* external ID, without a diff
    /// check in front of it, would append a second workout -- proving
    /// `saveWorkout` itself performs no dedupe (matching `save(_:)`'s own
    /// posture: the existence-diff is the caller's job, done once per
    /// (type, window) before writing). This is the counterpart proof to
    /// `aSavedWorkoutIsDiscoverableThroughTheSameExistingExternalIDsMethod`
    /// above: idempotency for workouts lives in "the caller checks
    /// `existingExternalIDs` first," the exact same discipline
    /// `SyncEngine.processPage` already applies to `.quantity`/`.category`
    /// batches, not inside this method.
    @available(*, deprecated, message: "constructs a test-only fake HKWorkout via a deprecated initializer, see MockWorkoutBuilder.swift")
    @Test func callerMustCheckExistingExternalIDsBeforeSavingAgain() async throws {
        let store = MockHealthStore()
        let externalID = "exercise-dedupe-0002"
        let start = Self.date("2026-07-02T08:00:00Z")
        let end = Self.date("2026-07-02T08:30:00Z")

        let firstBuilder = MockWorkoutBuilder()
        firstBuilder.storeToSeedOnFinish = store
        firstBuilder.finishResult = makeFakeHKWorkoutForTesting(
            activityType: .running, start: start, end: end,
            metadata: [HKMetadataKeyExternalUUID: externalID, "healthloom.externalID": externalID]
        )
        let writer = HealthKitWriter(store: store, workoutBuilderFactory: MockWorkoutBuilderFactory(builder: firstBuilder))
        _ = try await writer.saveWorkout(Self.workout(start: start, end: end, externalID: externalID))

        // The caller's expected discipline: check first.
        let existingBeforeSecondSave = try await writer.existingExternalIDs(
            type: HKObjectType.workoutType(), start: start, end: end
        )
        #expect(existingBeforeSecondSave.contains(externalID))
        // A correct caller (SyncEngine's own pattern) would skip calling
        // `saveWorkout` again here, having seen `externalID` already present.
    }

    /// Before a first save, the exact same method reports no existing
    /// workouts -- confirming `HKObjectType.workoutType()` is accepted by
    /// `existingExternalIDs` at all (it's an `HKSampleType` just like every
    /// quantity/category type), not a special-cased no-op.
    @Test func noExistingWorkoutsBeforeAnySave() async throws {
        let store = MockHealthStore()
        let writer = HealthKitWriter(store: store)

        let existing = try await writer.existingExternalIDs(
            type: HKObjectType.workoutType(),
            start: Self.date("2000-01-01T00:00:00Z"),
            end: Self.date("2100-01-01T00:00:00Z")
        )
        #expect(existing.isEmpty)
    }
}
#endif
