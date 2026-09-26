// ActivitiesProvider.swift
//
// WP-12b (implementation-plan.md) step 5: the one HealthKit-touching piece
// of the Activities view -- reads recent workouts (all sources, so watch
// workouts recorded by any app are first-class, architecture.md D13.1's
// "any app" posture carried into the UI) and reduces them to the pure
// `WorkoutSummary` shape `ActivityConsolidator` (ActivitiesModels.swift)
// consumes. Same completion-handler bridging as SyncKit's `HealthKitStore`/
// `HealthKitWatchCoverageProvider`, for the same reasons.
//
// Error/empty posture: any query failure (including HealthKit read
// authorization never granted -- reads never reveal denial, WP-06's rule)
// returns `[]`; the view then renders whatever `LocalSample` sessions exist
// standalone, so the screen degrades to "Fitbit activities only" rather
// than erroring.

import Foundation
import HealthKit

@MainActor
final class ActivitiesProvider {
    private let healthStore: HKHealthStore

    init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    func recentWorkouts(daysBack: Int = 30, now: Date = Date()) async -> [WorkoutSummary] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        let start = now.addingTimeInterval(-Double(daysBack) * 24 * 3600)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: [])

        let samples: [HKSample]
        do {
            samples = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKSample], Error>) in
                let query = HKSampleQuery(
                    sampleType: .workoutType(),
                    predicate: predicate,
                    limit: HKObjectQueryNoLimit,
                    sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
                ) { _, samples, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: samples ?? [])
                    }
                }
                healthStore.execute(query)
            }
        } catch {
            return [] // degrade -- see this file's header
        }

        return samples.compactMap { sample in
            guard let workout = sample as? HKWorkout else { return nil }
            let isHealthLoomImport = workout.metadata?["healthloom.externalID"] != nil
            // Same device-not-app classification rule as SyncKit's
            // `ProductTypeWorkoutSourceClassifier` (Conflict/
            // WatchCoverageProvider.swift) -- kept in lockstep by eye; the
            // resolver's copy is the load-bearing one.
            let isAppleWatch = (workout.sourceRevision.productType?.hasPrefix("Watch") ?? false)
                || (workout.device?.model.map { $0.contains("Watch") } ?? false)
            let kind = Self.kind(workout.workoutActivityType)
            return WorkoutSummary(
                uuid: workout.uuid,
                activityName: kind.name,
                family: kind.family,
                start: workout.startDate,
                end: workout.endDate,
                sourceName: workout.sourceRevision.source.name,
                isHealthLoomImport: isHealthLoomImport,
                isAppleWatch: isAppleWatch,
                distanceMeters: Self.distanceMeters(workout),
                averageHeartRate: workout.statistics(for: HKQuantityType(.heartRate))?
                    .averageQuantity()?
                    .doubleValue(for: .count().unitDivided(by: .minute())),
                swimLocation: Self.swimLocation(workout)
            )
        }
    }

    /// Display name and family for the activity types this app itself maps
    /// (TypeMapper's WP-12 table) plus a generic default -- deliberately not
    /// an exhaustive ~80-case `HKWorkoutActivityType` catalog. Name and
    /// family come from ONE switch so they can't disagree.
    private static func kind(_ type: HKWorkoutActivityType) -> (name: String, family: ActivityFamily) {
        switch type {
        case .running: return ("Run", .onFoot)
        case .walking: return ("Walk", .onFoot)
        case .hiking: return ("Hike", .onFoot)
        case .swimming: return ("Swim", .water)
        case .cycling: return ("Ride", .endurance)
        case .rowing: return ("Rowing", .endurance)
        case .elliptical: return ("Elliptical", .endurance)
        case .stairClimbing: return ("Stair Climbing", .endurance)
        case .traditionalStrengthTraining: return ("Strength Training", .training)
        case .yoga: return ("Yoga", .training)
        case .highIntensityIntervalTraining: return ("HIIT", .training)
        case .coreTraining: return ("Core Training", .training)
        default: return ("Workout", .training)
        }
    }

    /// The workout's own recorded distance, whichever distance type it
    /// logged (a run logs walking+running, a swim swimming, ...). Nil when
    /// it recorded none -- the badge is omitted, never shown as 0.
    private static func distanceMeters(_ workout: HKWorkout) -> Double? {
        let types: [HKQuantityTypeIdentifier] = [
            .distanceWalkingRunning, .distanceSwimming, .distanceCycling, .distanceRowing,
        ]
        for identifier in types {
            if let sum = workout.statistics(for: HKQuantityType(identifier))?.sumQuantity() {
                return sum.doubleValue(for: .meter())
            }
        }
        return nil
    }

    private static func swimLocation(_ workout: HKWorkout) -> SwimLocation? {
        guard let raw = workout.metadata?[HKMetadataKeySwimmingLocationType] as? NSNumber,
              let location = HKWorkoutSwimmingLocationType(rawValue: raw.intValue) else { return nil }
        switch location {
        case .pool: return .pool
        case .openWater: return .openWater
        case .unknown: return nil
        @unknown default: return nil
        }
    }
}
