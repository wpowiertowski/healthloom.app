// WatchCoverageProvider.swift
//
// WP-12b (implementation-plan.md) step 1 / architecture.md D13.1: the real,
// HealthKit-backed `WatchCoverageProviding` -- queries HealthKit for
// workouts in a window, drops the ones HealthLoom wrote, tags each of the
// rest with whether an injected `WorkoutSourceClassifier` says an Apple
// Watch recorded it (any recording app, not just Apple's Workout app;
// everything else is `.otherApp` since WP-55), and returns their unpadded
// spans as `WatchCoverageWindow`s
// (padding is `WatchCoverageIndex`'s job -- see WatchCoverage.swift).
//
// Guarded `#if canImport(HealthKit)` per the WP-06/07/08 platform boundary.
// The classifier is a protocol seam because the simulator cannot fabricate a
// workout with an Apple Watch source (`HKSource`/`HKSourceRevision` have no
// public initializers a test could use) -- unit tests inject coverage
// windows directly through `WatchCoverageProviding` instead and never reach
// this file; this classifier's own logic is a two-line predicate reviewed by
// eye and exercised on-device (test-plan.md §7's dual-wear manual scripts).
#if canImport(HealthKit)
import Foundation
import HealthKit

/// Decides whether one `HKWorkout` was recorded by an Apple Watch
/// (architecture.md D13.1: "workouts whose source device is an Apple Watch
/// (any app, not just Apple's Workout app)").
nonisolated public protocol WorkoutSourceClassifier: Sendable {
    nonisolated func isAppleWatchWorkout(_ workout: HKWorkout) -> Bool
}

/// Production classifier: an Apple Watch source reports a
/// `sourceRevision.productType` beginning with `"Watch"` (e.g. `"Watch7,1"`)
/// -- the device-model identifier namespace Apple uses for every Apple Watch
/// -- and/or an `HKDevice.model` of `"Watch"`. Either signal suffices; both
/// are per-*device*, not per-app, exactly D13.1's "any app" requirement.
nonisolated public struct ProductTypeWorkoutSourceClassifier: WorkoutSourceClassifier {
    public init() {}

    public nonisolated func isAppleWatchWorkout(_ workout: HKWorkout) -> Bool {
        if let productType = workout.sourceRevision.productType, productType.hasPrefix("Watch") {
            return true
        }
        if let model = workout.device?.model, model.contains("Watch") {
            return true
        }
        return false
    }
}

/// The real `WatchCoverageProviding`: one `HKSampleQuery` over
/// `HKObjectType.workoutType()` per call (`WatchConflictResolver` calls it
/// once per sync run -- "cache per sync run" lives in the resolver, not
/// here). Same `Sendable`-final-class + completion-handler-bridging shape as
/// `HealthKitStore` (HealthStoreProtocol.swift), for the same reasons.
public final class HealthKitWatchCoverageProvider: WatchCoverageProviding, Sendable {
    private let healthStore: HKHealthStore
    private let classifier: any WorkoutSourceClassifier

    /// Pass the same `HKHealthStore` instance the app's other HealthKit
    /// types hold where one is in scope (HealthKitAuth.swift's one-store-
    /// per-app note); defaults to a fresh store for convenience.
    public init(
        healthStore: HKHealthStore = HKHealthStore(),
        classifier: any WorkoutSourceClassifier = ProductTypeWorkoutSourceClassifier()
    ) {
        self.healthStore = healthStore
        self.classifier = classifier
    }

    public func watchWorkoutWindows(start: Date, end: Date) async throws -> [WatchCoverageWindow] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let samples = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKSample], Error>) in
            let query = HKSampleQuery(
                sampleType: .workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            healthStore.execute(query)
        }

        return samples.compactMap { sample in
            guard let workout = sample as? HKWorkout else { return nil }
            // Never treat this app's own imported (Fitbit-sourced) workouts
            // as coverage -- they carry HealthLoom's external-ID stamp
            // (architecture.md D4). Load-bearing since WP-55: every non-watch
            // workout now covers as `.otherApp`, so without this check an
            // imported session would defer to itself and retroactive cleanup
            // would delete it.
            guard workout.metadata?[MappedMetadata.externalIDKey] == nil else { return nil }
            // WP-55: every other workout covers too. One saved straight to
            // Apple Health by another app (a Hydrow rower) already records
            // the session the Fitbit logged alongside it, so it wins the
            // session; only a watch also wins the streams.
            return WatchCoverageWindow(
                workoutUUID: workout.uuid,
                start: workout.startDate,
                end: workout.endDate,
                source: classifier.isAppleWatchWorkout(workout) ? .appleWatch : .otherApp
            )
        }
    }
}
#endif
