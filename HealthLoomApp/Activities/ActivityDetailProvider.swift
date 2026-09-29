// ActivityDetailProvider.swift
//
// WP-73: reads everything recorded during one activity -- every HealthKit
// quantity in `ActivityMetric`'s catalog, from any device, plus Fitbit's
// in-app per-minute rows -- and the workout's route when it has one.
// Thin adapter: it only reads and reduces to `ActivitySample`s; the
// series logic is ActivitySeries.swift's, and tested there.
//
// Error/empty posture matches ActivitiesProvider: a failed or unauthorized
// query contributes nothing (reads never reveal denial), so the screen
// shows whatever did come back.

import CoreLocation
import CoreModel
import Foundation
import HealthKit
import SwiftData
import SyncKit

/// What the detail screen shows below the summary.
nonisolated struct ActivityDetail: Equatable, Sendable {
    var series: [ActivityMetricSeries]
    var route: ActivityRoute?
}

@MainActor
final class ActivityDetailProvider {
    private let healthStore: HKHealthStore
    private let healthKitAuth: HealthKitAuth
    private let modelContainer: ModelContainer
    /// UI tests never see the system permission sheet (it would block them).
    private let requestsAuthorization: Bool

    init(
        healthKitAuth: HealthKitAuth,
        modelContainer: ModelContainer,
        requestsAuthorization: Bool,
        healthStore: HKHealthStore = HKHealthStore()
    ) {
        self.healthKitAuth = healthKitAuth
        self.modelContainer = modelContainer
        self.requestsAuthorization = requestsAuthorization
        self.healthStore = healthStore
    }

    /// The types this screen reads beyond onboarding's set: asked for the
    /// first time a detail opens; HealthKit prompts only for new ones.
    nonisolated static var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>(ActivityMetric.allCases.compactMap { healthKitType(for: $0) }.map { HKQuantityType($0.identifier) })
        types.insert(HKSeriesType.workoutRoute())
        types.insert(HKObjectType.workoutType())
        return types
    }

    func detail(for entry: ActivityEntry) async -> ActivityDetail {
        if requestsAuthorization {
            try? await healthKitAuth.requestRead(objectTypes: Self.readTypes)
        }
        let start = entry.start
        let end = entry.end
        let store = healthStore
        var samples = await withTaskGroup(of: [ActivitySample].self) { group in
            for metric in ActivityMetric.allCases {
                guard let type = Self.healthKitType(for: metric) else { continue }
                group.addTask { await Self.quantitySamples(metric: metric, type: type, start: start, end: end, store: store) }
            }
            var all: [ActivitySample] = []
            for await batch in group { all.append(contentsOf: batch) }
            return all
        }
        let local = try? await ActivityLocalSampleReader(modelContainer: modelContainer).samples(from: start, to: end)
        samples.append(contentsOf: local ?? [])

        var route: ActivityRoute?
        if case .workout(let workout) = entry.kind {
            route = await Self.route(workoutUUID: workout.uuid, store: store)
        }
        return ActivityDetail(series: ActivitySeriesBuilder.series(samples, from: start, to: end), route: route)
    }

    /// Each HealthKit-backed metric's type and the canonical unit
    /// `ActivityMetric.displayValue` expects; nil for the in-app metrics.
    /// Exhaustive, so a new metric can't be added without deciding.
    nonisolated static func healthKitType(for metric: ActivityMetric) -> (identifier: HKQuantityTypeIdentifier, unit: HKUnit)? {
        let perMinute = HKUnit.count().unitDivided(by: .minute())
        switch metric {
        case .heartRate: return (.heartRate, perMinute)
        case .activeEnergy: return (.activeEnergyBurned, .kilocalorie())
        case .distance: return (.distanceWalkingRunning, .meter())
        case .cyclingDistance: return (.distanceCycling, .meter())
        case .swimmingDistance: return (.distanceSwimming, .meter())
        case .steps: return (.stepCount, .count())
        case .runningSpeed: return (.runningSpeed, .meter().unitDivided(by: .second()))
        case .runningPower: return (.runningPower, .watt())
        case .runningStrideLength: return (.runningStrideLength, .meter())
        case .runningVerticalOscillation: return (.runningVerticalOscillation, .meterUnit(with: .centi))
        case .runningGroundContactTime: return (.runningGroundContactTime, .secondUnit(with: .milli))
        case .cyclingSpeed: return (.cyclingSpeed, .meter().unitDivided(by: .second()))
        case .cyclingPower: return (.cyclingPower, .watt())
        case .cyclingCadence: return (.cyclingCadence, perMinute)
        case .swimmingStrokes: return (.swimmingStrokeCount, .count())
        case .flightsClimbed: return (.flightsClimbed, .count())
        case .respiratoryRate: return (.respiratoryRate, perMinute)
        case .oxygenSaturation: return (.oxygenSaturation, .percent())
        case .activeZoneMinutes, .activeMinutes: return nil
        }
    }

    // MARK: - HealthKit reads (nonisolated: they complete in HealthKit's handlers)

    nonisolated private static func quantitySamples(
        metric: ActivityMetric,
        type: (identifier: HKQuantityTypeIdentifier, unit: HKUnit),
        start: Date,
        end: Date,
        store: HKHealthStore
    ) async -> [ActivitySample] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKQuantityType(type.identifier), predicate: predicate,
                limit: HKObjectQueryNoLimit, sortDescriptors: nil
            ) { _, samples, _ in
                let reduced = (samples ?? []).compactMap { $0 as? HKQuantitySample }.map { sample in
                    ActivitySample(
                        metric: metric, start: sample.startDate, end: sample.endDate,
                        value: sample.quantity.doubleValue(for: type.unit),
                        origin: SleepSourceSelection.origin(of: sample)
                    )
                }
                continuation.resume(returning: reduced)
            }
            store.execute(query)
        }
    }

    nonisolated private static func route(workoutUUID: UUID, store: HKHealthStore) async -> ActivityRoute? {
        guard let workout = await workout(uuid: workoutUUID, store: store) else { return nil }
        let routes: [HKWorkoutRoute] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKSeriesType.workoutRoute(), predicate: HKQuery.predicateForObjects(from: workout),
                limit: HKObjectQueryNoLimit, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, _ in
                continuation.resume(returning: (samples ?? []).compactMap { $0 as? HKWorkoutRoute })
            }
            store.execute(query)
        }
        var coordinates: [CLLocationCoordinate2D] = []
        for route in routes {
            coordinates.append(contentsOf: await locations(of: route, store: store))
        }
        return ActivityRoute(coordinates: coordinates)
    }

    nonisolated private static func workout(uuid: UUID, store: HKHealthStore) async -> HKWorkout? {
        await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: .workoutType(), predicate: HKQuery.predicateForObject(with: uuid),
                limit: 1, sortDescriptors: nil
            ) { _, samples, _ in
                continuation.resume(returning: samples?.first as? HKWorkout)
            }
            store.execute(query)
        }
    }

    /// A route's locations; HealthKit delivers them in batches on one
    /// serial callback until `done`.
    nonisolated private static func locations(of route: HKWorkoutRoute, store: HKHealthStore) async -> [CLLocationCoordinate2D] {
        await withCheckedContinuation { continuation in
            let collected = CoordinateBox()
            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                collected.coordinates.append(contentsOf: (locations ?? []).map(\.coordinate))
                if done || error != nil {
                    continuation.resume(returning: collected.coordinates)
                }
            }
            store.execute(query)
        }
    }
}

/// Accumulates a route query's batches. `@unchecked Sendable`: HealthKit
/// calls the one query's handler serially, so there's no concurrent access.
nonisolated private final class CoordinateBox: @unchecked Sendable {
    var coordinates: [CLLocationCoordinate2D] = []
}

/// Fitbit's per-minute in-app rows inside an activity, read off the main
/// actor (a long session is hundreds of rows).
@ModelActor
actor ActivityLocalSampleReader {
    /// The in-app types the detail plots and the metric each becomes.
    static let metrics: [(type: GoogleDataType, metric: ActivityMetric)] = [
        (.activeZoneMinutes, .activeZoneMinutes),
        (.activeMinutes, .activeMinutes),
    ]

    func samples(from start: Date, to end: Date) throws -> [ActivitySample] {
        var samples: [ActivitySample] = []
        for (type, metric) in Self.metrics {
            let key = type.rawValue
            let rows = try modelContext.fetch(FetchDescriptor<LocalSample>(
                predicate: #Predicate { $0.dataType == key && $0.start >= start && $0.start < end }
            ))
            samples.append(contentsOf: rows.compactMap { row in
                row.payloadValues[DataTrendText.minutesKey].map {
                    ActivitySample(metric: metric, start: row.start, end: row.end, value: $0, origin: .fitbit)
                }
            })
        }
        return samples
    }
}
