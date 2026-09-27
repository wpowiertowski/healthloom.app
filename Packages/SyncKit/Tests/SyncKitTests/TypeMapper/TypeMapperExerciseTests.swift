// TypeMapperExerciseTests.swift
//
// WP-12 (implementation-plan.md) "Tests:" line: "golden per exercise type
// incl. unknown-type default." Exercises `TypeMapper.decide(_:)` -- the
// HealthKit-free decision layer (MappedTypes.swift/TypeMapper.swift) -- so
// these run identically on any platform `swift test` targets, same posture
// as `TypeMapperGoldenTests.swift`. `TypeMapperHealthKitMappingTests.swift`
// additionally confirms `TypeMapper.map(_:)`/`MappedWorkoutActivityType
// .makeHKWorkoutActivityType()` wrap these same decisions into the correct
// real `HKWorkoutActivityType` (that file is `#if canImport(HealthKit)`-
// guarded; this one is not, since `MappedWorkout`/`MappedWorkoutActivityType`
// are HealthKit-free by design -- see MappedTypes.swift's header).

import CoreModel
import Foundation
import GoogleHealthClient
import Testing
@testable import SyncKit

@Suite struct TypeMapperExerciseTests {
    /// Golden rows over the published `Exercise.ExerciseType` enum (WP-51):
    /// at least one value per workout bucket, plus the variants most likely
    /// in real Fitbit/Pixel data, each pinned to its documented bucket.
    @Test(
        arguments: [
            ("RUNNING", MappedWorkoutActivityType.running),
            ("TRAIL_RUN", .running),
            ("TREADMILL", .running),
            ("WALKING", .walking),
            ("POWER_WALKING", .walking),
            ("BIKING", .cycling),
            ("STATIONARY_BIKE", .cycling),
            ("SPINNING", .cycling),
            ("SWIMMING", .swimming),
            ("SWIMMING_OPEN_WATER", .swimming),
            ("HIKING", .hiking),
            ("WEIGHTS", .traditionalStrengthTraining),
            ("STRENGTH_TRAINING", .traditionalStrengthTraining),
            ("YOGA", .yoga),
            ("YOGA_VINYASA", .yoga),
            ("ELLIPTICAL", .elliptical),
            ("ROWING_MACHINE", .rowing),
            ("HIIT", .highIntensityIntervalTraining),
            ("STAIRCLIMBER", .stairClimbing),
            ("CORE_TRAINING", .coreTraining),
            ("TENNIS", .other),
            ("OTHER", .other),
        ]
    )
    func recognizedActivityTypeGolden(wireValue: String, expected: MappedWorkoutActivityType) {
        let point = TypeMapperFixtures.exercisePoint(wireActivityType: wireValue)
        guard case .workout(let workout) = TypeMapper.decide(point) else {
            Issue.record("expected .workout for wire activity type \"\(wireValue)\"")
            return
        }
        #expect(workout.activityType == expected)
    }

    /// WP-12's explicit "default bucket .other for anything unrecognized" --
    /// a wire string genuinely absent from the table (distinct from
    /// "workout" above, which is itself an explicit table entry that also
    /// targets `.other`) still decides successfully, just bucketed to
    /// `.other` via the table lookup's `?? .other` fallback.
    @Test func unrecognizedActivityTypeDefaultsToOther() {
        let point = TypeMapperFixtures.exercisePoint(wireActivityType: "SOME_FUTURE_EXERCISE_TYPE")
        guard case .workout(let workout) = TypeMapper.decide(point) else {
            Issue.record("expected .workout")
            return
        }
        #expect(workout.activityType == .other)
    }

    /// Full golden check on one recognized type: activity type, start/end
    /// (session bounds -- duration is derived, not a separate wire field),
    /// distance, energy, and metadata all exactly as expected.
    @Test func fullGoldenIncludesDistanceEnergyAndMetadata() {
        let point = TypeMapperFixtures.exercisePoint(
            id: "exercise-0001",
            wireActivityType: "RUNNING",
            distanceMeters: 8000.0,
            energyKilocalories: 520.0
        )
        guard case .workout(let workout) = TypeMapper.decide(point) else {
            Issue.record("expected .workout")
            return
        }
        #expect(workout.activityType == .running)
        #expect(workout.start == TypeMapperFixtures.date("2026-07-01T17:00:00Z"))
        #expect(workout.end == TypeMapperFixtures.date("2026-07-01T17:45:00Z"))
        #expect(workout.distanceMeters == 8000.0)
        #expect(workout.energyKilocalories == 520.0)
        #expect(workout.metadata.externalUUID == "exercise-0001")
        #expect(workout.metadata.externalID == "exercise-0001")
        #expect(workout.metadata.sourceDevice == "Fitbit Air")
    }

    /// Distance/energy are optional -- a session that reports neither still
    /// maps to a valid workout with both `nil`.
    @Test func missingDistanceAndEnergyStayNil() {
        let point = TypeMapperFixtures.exercisePoint(distanceMeters: nil, energyKilocalories: nil)
        guard case .workout(let workout) = TypeMapper.decide(point) else {
            Issue.record("expected .workout")
            return
        }
        #expect(workout.distanceMeters == nil)
        #expect(workout.energyKilocalories == nil)
    }

    /// A negative distance/energy reading is dropped (nil'd), not force-kept
    /// as garbage data -- the workout itself is still emitted (unlike, say,
    /// out-of-range heart rate, an implausible *auxiliary* attachment
    /// doesn't invalidate the whole session -- see
    /// `TypeMapper.decideExercise`'s doc comment).
    @Test func negativeDistanceAndEnergyAreDroppedNotKept() {
        let point = TypeMapperFixtures.exercisePoint(distanceMeters: -5.0, energyKilocalories: -1.0)
        guard case .workout(let workout) = TypeMapper.decide(point) else {
            Issue.record("expected .workout")
            return
        }
        #expect(workout.distanceMeters == nil)
        #expect(workout.energyKilocalories == nil)
    }

    /// No `sessionPayload` at all (e.g. a malformed upstream decode) never
    /// crashes -- drops the whole session, matching Sleep's precedent
    /// (SleepSessionDecoding/`TypeMapper.decideSleep`).
    @Test func missingSessionPayloadRoutesToSkip() {
        let point = GoogleDataPoint(
            id: "exercise-missing-payload",
            dataType: .exercise,
            start: TypeMapperFixtures.date("2026-07-01T17:00:00Z"),
            end: TypeMapperFixtures.date("2026-07-01T17:45:00Z"),
            source: DataSource(platform: nil, deviceDisplayName: nil, recordingMethod: nil),
            values: [:]
        )
        #expect(TypeMapper.decide(point) == .skip)
    }

    /// catches: a session without `exerciseType` being dropped. Google's
    /// enum has an explicit `EXERCISE_TYPE_UNSPECIFIED`, and a real, timed
    /// session is better recorded as an Other workout than lost (WP-51; it
    /// was a skip under the invented pre-WP-51 shape).
    @Test func payloadMissingActivityTypeIsAnOtherWorkout() {
        let payload = try! JSONSerialization.data(withJSONObject: ["metricsSummary": ["distanceMillimeters": 100_000.0]], options: [])
        let point = GoogleDataPoint(
            id: "exercise-no-type",
            dataType: .exercise,
            start: TypeMapperFixtures.date("2026-07-01T17:00:00Z"),
            end: TypeMapperFixtures.date("2026-07-01T17:45:00Z"),
            source: DataSource(platform: nil, deviceDisplayName: nil, recordingMethod: nil),
            values: [:],
            sessionPayload: payload
        )
        guard case .workout(let workout) = TypeMapper.decide(point) else {
            Issue.record("expected an .other workout")
            return
        }
        #expect(workout.activityType == .other)
        #expect(workout.distanceMeters == 100)
    }

    /// A reversed window (`end < start`) is dropped, same invariant as every
    /// other type (TypeMapperPropertyTests.swift).
    @Test func reversedWindowRoutesToSkip() {
        let point = TypeMapperFixtures.exercisePoint(
            start: TypeMapperFixtures.date("2026-07-01T17:45:00Z"),
            end: TypeMapperFixtures.date("2026-07-01T17:00:00Z")
        )
        #expect(TypeMapper.decide(point) == .skip)
    }

    /// A missing device display name is carried through as `nil`, same
    /// precedent every other type in this package establishes
    /// (TypeMapperGoldenTests.swift's `missingDeviceDisplayNameStaysNil`).
    @Test func missingDeviceDisplayNameStaysNil() {
        let point = TypeMapperFixtures.exercisePoint(deviceDisplayName: nil)
        guard case .workout(let workout) = TypeMapper.decide(point) else {
            Issue.record("expected .workout")
            return
        }
        #expect(workout.metadata.sourceDevice == nil)
    }
}
