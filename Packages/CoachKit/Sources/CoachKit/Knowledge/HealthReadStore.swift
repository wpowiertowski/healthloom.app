// HealthReadStore.swift
//
// WP-19 (implementation-plan.md) step 1 / architecture.md D7, §2 ("CoachKit
// reads health data only through KnowledgeStore -- HealthKit queries +
// LocalSample -- never through GoogleHealthClient").
//
// Same protocol-seam shape SyncKit established for its own HealthKit access
// (`HealthStoreProtocol`/`HealthKitStore`, HealthKitWriter/HealthStoreProtocol
// .swift): `HealthReadStore` describes *what* KnowledgeDerivation needs (daily
// steps, resting-HR/HRV series, sleep segments, workouts) as plain value
// types (HealthReadTypes.swift), never raw `HKSample`/`HKStatistics` --
// `HealthKitReadStore` (below) is the only place real HealthKit queries are
// built; `MockHealthReadStore` (test target) implements the same protocol
// over in-memory arrays with no HealthKit entitlement.
//
// This is deliberately a *different* protocol from SyncKit's
// `HealthStoreProtocol` rather than a shared one: that protocol's shape is
// existence-diff/delete-by-ID, built for SyncEngine's write pipeline; nothing
// here writes, and every query here is a read-and-summarize over a date
// window, a fundamentally different access pattern that would only strain a
// shared abstraction.
//
// Read-denial posture (HealthKitAuth.swift's documented rule, unchanged
// here): HealthKit never reveals whether the user denied *read* access, so
// every method below degrades to an empty result on any query failure --
// including "authorization never requested" and "authorization denied" --
// never throws. KnowledgeDerivation's pure functions already treat empty
// input as "insufficient signal," so this degrades gracefully all the way to
// the profile's "based on N of 4 signals" language (architecture.md D6),
// exactly like `TodayMetricsProvider`/`ActivitiesProvider`'s established
// posture (WP-33/WP-12b).

import Foundation

/// Abstracts every HealthKit read `KnowledgeStore` needs. See this file's
/// header for why this is a separate seam from SyncKit's `HealthStoreProtocol`.
public protocol HealthReadStore: Sendable {
    /// Daily step totals, source-merged (architecture.md D13.3 -- watch and
    /// Fitbit-imported steps compose honestly), one entry per day that has
    /// any data, for `[start, end]`.
    func dailySteps(from start: Date, to end: Date) async -> [DailyQuantityValue]

    /// Daily resting-heart-rate averages (bpm), source-merged, for `[start, end]`.
    func dailyRestingHeartRate(from start: Date, to end: Date) async -> [QuantityReading]

    /// Daily heart-rate-variability (SDNN, ms) averages, source-merged, for
    /// `[start, end]`.
    func dailyHeartRateVariability(from start: Date, to end: Date) async -> [QuantityReading]

    /// Individual asleep-stage segments (never `inBed`/`awake`) for `[start, end]`,
    /// across every source -- callers bucket into nights themselves.
    func sleepStageSegments(from start: Date, to end: Date) async -> [SleepStageSegment]

    /// Every workout (any source -- Apple Watch first-class, per architecture.md
    /// D13.6) whose start falls in `[start, end]`.
    func workouts(from start: Date, to end: Date) async -> [WorkoutRecord]
}

#if canImport(HealthKit)
import HealthKit

/// The real `HealthReadStore` adapter. Every method is a thin, direct
/// translation into `HKStatisticsCollectionQuery`/`HKSampleQuery`, bridged to
/// async/await via checked continuations -- same style as SyncKit's
/// `HealthKitStore` and the app target's `TodayMetricsProvider`/
/// `ActivitiesProvider`. Zero derivation logic lives here; that is
/// `KnowledgeDerivation`'s job.
///
/// `nonisolated` (code review 2026-08-28 finding #15): without it,
/// CoachKit's package-wide `.defaultIsolation(MainActor.self)` silently
/// makes every method below MainActor-isolated -- it still satisfies
/// `HealthReadStore`'s nonisolated-async requirements via an implicit hop,
/// so it compiles either way, but that hop forces every `async let` read in
/// `KnowledgeStore.refresh()` to serialize its setup through MainActor
/// before reaching its first suspension point, defeating the concurrency
/// those `async let`s are written to express. Safe here exactly like
/// `HealthReadTypes.swift`'s value types (same precedent, SyncKit's
/// `MappedMetadata` et al.): every stored property is an immutable `let`.
nonisolated public final class HealthKitReadStore: HealthReadStore, Sendable {
    private let healthStore: HKHealthStore
    private let calendar: Calendar

    /// `HKHealthStore` is `Sendable`; shared with `HealthKitAuth`'s "one
    /// store per app" posture (HealthKitAuth.swift) is left to the caller --
    /// this type takes its own store by default for standalone testability,
    /// mirroring `HealthKitStore`'s init.
    public init(healthStore: HKHealthStore = HKHealthStore(), calendar: Calendar = .current) {
        self.healthStore = healthStore
        self.calendar = calendar
    }

    public func dailySteps(from start: Date, to end: Date) async -> [DailyQuantityValue] {
        await dailyCollection(.stepCount, unit: .count(), options: .cumulativeSum, from: start, to: end)
    }

    public func dailyRestingHeartRate(from start: Date, to end: Date) async -> [QuantityReading] {
        await dailyCollection(
            .restingHeartRate,
            unit: HKUnit.count().unitDivided(by: .minute()),
            options: .discreteAverage,
            from: start,
            to: end
        ).map { QuantityReading(date: $0.day, value: $0.value) }
    }

    public func dailyHeartRateVariability(from start: Date, to end: Date) async -> [QuantityReading] {
        await dailyCollection(
            .heartRateVariabilitySDNN,
            unit: .secondUnit(with: .milli),
            options: .discreteAverage,
            from: start,
            to: end
        ).map { QuantityReading(date: $0.day, value: $0.value) }
    }

    public func sleepStageSegments(from start: Date, to end: Date) async -> [SleepStageSegment] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        // `.strictStartDate` (code review 2026-08-28 finding #7): without it,
        // HealthKit's default predicate matches on *any* overlap with
        // `[start, end]`, diverging from this method's own documented "for
        // [start, end]" contract (start-date windowing) and from
        // `MockHealthReadStore`'s test-double semantics (`$0.start >= start
        // && $0.start <= end`) -- production would silently include a
        // segment that starts before the window but extends into it, which
        // no test built against the mock could ever catch.
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate])
        let samples = await querySamples(ofType: type, matching: predicate)
        return samples.compactMap { sample -> SleepStageSegment? in
            guard let category = sample as? HKCategorySample,
                  let stage = Self.sleepStage(forRawValue: category.value) else { return nil }
            return SleepStageSegment(start: category.startDate, end: category.endDate, stage: stage)
        }
    }

    public func workouts(from start: Date, to end: Date) async -> [WorkoutRecord] {
        // `.strictStartDate` -- see `sleepStageSegments`'s identical note
        // (code review 2026-08-28 finding #7); this method's own doc comment
        // ("whose start falls in [start, end]") already documents exactly
        // this semantics.
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate])
        let samples = await querySamples(ofType: HKObjectType.workoutType(), matching: predicate)
        return samples.compactMap { sample -> WorkoutRecord? in
            guard let workout = sample as? HKWorkout else { return nil }
            let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)
            let energy = energyType.flatMap { workout.allStatistics[$0]?.sumQuantity() }
            let distance = Self.distance(for: workout)
            return WorkoutRecord(
                id: workout.uuid,
                start: workout.startDate,
                end: workout.endDate,
                activityName: Self.displayName(for: workout.workoutActivityType),
                totalEnergyKilocalories: energy?.doubleValue(for: .kilocalorie()),
                totalDistanceMeters: distance?.doubleValue(for: .meter())
            )
        }
    }

    // MARK: - Private

    /// Code review (2026-08-28) finding #6: a workout's distance is recorded
    /// under whichever activity-specific quantity type matches it (cycling
    /// under `distanceCycling`, swimming under `distanceSwimming`, ...) --
    /// `distanceWalkingRunning` alone silently drops every other activity's
    /// distance.
    private static let distanceQuantityTypeIdentifiers: [HKQuantityTypeIdentifier] = [
        .distanceWalkingRunning,
        .distanceCycling,
        .distanceSwimming,
        .distanceWheelchair,
        .distanceDownhillSnowSports,
        .distanceCrossCountrySkiing,
        .distancePaddleSports,
        .distanceRowing,
        .distanceSkatingSports,
    ]

    /// Code review (2026-09-01): a *single-sport* workout populates at most
    /// one of these, but a multisport workout (e.g. a triathlon `HKWorkout`)
    /// populates several simultaneously -- returning only the first present
    /// (as this used to) silently dropped every other leg's distance. Sum
    /// whichever of these are actually present instead of assuming they're
    /// mutually exclusive.
    private static func distance(for workout: HKWorkout) -> HKQuantity? {
        let quantities = distanceQuantityTypeIdentifiers.compactMap { identifier -> HKQuantity? in
            guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
            return workout.allStatistics[type]?.sumQuantity()
        }
        guard !quantities.isEmpty else { return nil }
        let totalMeters = quantities.reduce(0.0) { $0 + $1.doubleValue(for: .meter()) }
        return HKQuantity(unit: .meter(), doubleValue: totalMeters)
    }

    /// `HKCategoryValueSleepAnalysis` raw values -- inBed = 0, asleepUnspecified = 1,
    /// awake = 2, asleepCore = 3, asleepDeep = 4, asleepREM = 5 (the same
    /// literal set `TodayMetricsProvider`/`MappedSleepStage` pin). `inBed`/
    /// `awake` map to `nil` -- excluded, never a "stage."
    private static func sleepStage(forRawValue rawValue: Int) -> SleepStageKind? {
        switch rawValue {
        case 1: return .unspecified
        case 3: return .core
        case 4: return .deep
        case 5: return .rem
        default: return nil
        }
    }

    /// The ~13 `HKWorkoutActivityType` cases `TypeMapper.makeHKWorkoutActivityType()`
    /// maps Google Exercise types onto (MappedObject.swift) get their exact
    /// display name; anything else (any other watch-recorded activity type)
    /// falls back to a generic label rather than an exhaustive ~80-case switch.
    private static func displayName(for activityType: HKWorkoutActivityType) -> String {
        switch activityType {
        case .running: return "Running"
        case .walking: return "Walking"
        case .cycling: return "Cycling"
        case .swimming: return "Swimming"
        case .hiking: return "Hiking"
        case .traditionalStrengthTraining: return "Strength Training"
        case .yoga: return "Yoga"
        case .elliptical: return "Elliptical"
        case .rowing: return "Rowing"
        case .highIntensityIntervalTraining: return "HIIT"
        case .stairClimbing: return "Stair Climbing"
        case .coreTraining: return "Core Training"
        default: return "Workout"
        }
    }

    private func dailyCollection(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        options: HKStatisticsOptions,
        from start: Date,
        to end: Date
    ) async -> [DailyQuantityValue] {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return [] }
        var intervalComponents = DateComponents()
        intervalComponents.day = 1
        let anchor = calendar.startOfDay(for: start)
        // `.strictStartDate` (code review 2026-08-28 finding #7's fix,
        // applied here 2026-09-01): this method had the identical bug left
        // unpatched -- default any-overlap matching diverges from both this
        // method's own start-date windowing and `MockHealthReadStore`'s
        // test-double semantics, the same reasoning `sleepStageSegments`/
        // `workouts` already document.
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate])

        return await withCheckedContinuation { (continuation: CheckedContinuation<[DailyQuantityValue], Never>) in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: options,
                anchorDate: anchor,
                intervalComponents: intervalComponents
            )
            query.initialResultsHandler = { [calendar] _, collection, error in
                guard error == nil, let collection else {
                    continuation.resume(returning: [])
                    return
                }
                var values: [DailyQuantityValue] = []
                collection.enumerateStatistics(from: start, to: end) { statistics, _ in
                    // Code review (2026-09-01): the buckets are anchored at
                    // `start`'s calendar-day midnight so every *later* bucket
                    // is a full day, but the very first bucket -- unless
                    // `start` itself is already midnight -- spans midnight to
                    // `end`, while `quantitySamplePredicate` still only
                    // counts samples from the exact `start` instant onward.
                    // That bucket's total is therefore a genuinely partial
                    // day, yet averaging code downstream (`stepsField`/
                    // `vitalsField`) counts every returned day equally,
                    // systematically biasing the average low. Drop it rather
                    // than let a partial day masquerade as a full one.
                    guard statistics.startDate >= start else { return }
                    let quantity = options.contains(.cumulativeSum)
                        ? statistics.sumQuantity()
                        : statistics.averageQuantity()
                    guard let quantity else { return }
                    let day = calendar.startOfDay(for: statistics.startDate)
                    values.append(DailyQuantityValue(day: day, value: quantity.doubleValue(for: unit)))
                }
                continuation.resume(returning: values)
            }
            healthStore.execute(query)
        }
    }

    private func querySamples(ofType sampleType: HKSampleType, matching predicate: NSPredicate) async -> [HKSample] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[HKSample], Never>) in
            let query = HKSampleQuery(
                sampleType: sampleType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                guard error == nil else {
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(returning: samples ?? [])
            }
            healthStore.execute(query)
        }
    }
}
#endif
