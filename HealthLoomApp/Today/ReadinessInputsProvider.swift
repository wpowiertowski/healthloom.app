// ReadinessInputsProvider.swift
//
// WP-33 (implementation-plan.md) step 1's remainder: "readiness hero <-
// `ReadinessEngine`". The engine is deterministic and pure
// (`ReadinessEngine.score(inputs:recentScores:)`); this provider is the one
// HealthKit-touching piece that assembles its inputs, mirroring
// `TodayMetricsProvider`'s conventions (continuation-bridged queries,
// failure→nil posture so the hero degrades to its pending/insufficient
// states instead of erroring):
//   - HRV ratio: latest SDNN sample vs its 30-day average baseline;
//   - resting-HR delta: latest resting HR vs its 30-day average baseline;
//   - sleep hours + efficiency: last night's asleep-stage total (same
//     6 pm-yesterday window and asleep-value set as the metric provider)
//     and asleep ÷ in-bed span;
//   - prior-day strain: yesterday's workout energy, mapped to 0...1 at
//     800 kcal = maximal (a documented heuristic, not physiology — the
//     engine treats it as recovery demand, and the mapping is the one
//     place to wire a real load model in).
//
// `assemble(_:)` is pure so `TodayReadinessTests` pins the math without
// HealthKit; `ReadinessScoreHistory` (UserDefaults, last-30 ring) feeds
// `recentScores`, giving the "+N vs 30-day average" caption after days of
// use and `nil` (no delta clause) before that. Zero usable signals maps
// to `.pending` — the engine's all-nil fallback (score 50, 0 signals) must
// never render as a real score.

import CoachKit
import Foundation
import HealthKit

/// Fetched aggregates; every field optional, assembled purely below.
struct ReadinessAggregates: Equatable {
    var hrvLatestMs: Double?
    var hrvBaselineMs: Double?
    var restingHRLatestBpm: Double?
    var restingHRBaselineBpm: Double?
    var sleepSeconds: Double?
    var sleepEfficiency: Double?
    var priorDayWorkoutKcal: Double?
}

@MainActor
final class ReadinessInputsProvider {
    private let healthStore: HKHealthStore
    private let calendar: Calendar

    init(healthStore: HKHealthStore = HKHealthStore(), calendar: Calendar = .current) {
        self.healthStore = healthStore
        self.calendar = calendar
    }

    /// Assembles engine inputs from fetched aggregates. Pure.
    static func assemble(_ aggregates: ReadinessAggregates) -> ReadinessInputs {
        var inputs = ReadinessInputs()
        if let latest = aggregates.hrvLatestMs,
           let baseline = aggregates.hrvBaselineMs, baseline > 0
        {
            inputs.hrvRatio = latest / baseline
        }
        if let latest = aggregates.restingHRLatestBpm,
           let baseline = aggregates.restingHRBaselineBpm
        {
            inputs.restingHRDeltaBeatsPerMinute = latest - baseline
        }
        if let seconds = aggregates.sleepSeconds {
            inputs.sleepHours = seconds / 3600
        }
        inputs.sleepEfficiency = aggregates.sleepEfficiency
        if let kcal = aggregates.priorDayWorkoutKcal {
            inputs.priorDayStrain = min(max(kcal / 800, 0), 1)
        }
        return inputs
    }

    /// Maps an engine result onto the hero's display states. Pure: zero
    /// usable signals is `.pending` (never the engine's all-nil 50), and
    /// a missing delta passes through as nil (H1) — the hero renders
    /// "based on N of 4 signals", never an uncomputed "+0 average".
    static func display(_ readiness: Readiness) -> ReadinessDisplay {
        guard readiness.signalsUsed > 0 else { return .pending }
        return .scored(
            score: readiness.score,
            deltaVsBaseline: readiness.deltaVsAverage,
            signalsUsed: readiness.signalsUsed
        )
    }

    func aggregates(now: Date = Date()) async -> ReadinessAggregates {
        guard HKHealthStore.isHealthDataAvailable() else { return ReadinessAggregates() }
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        async let hrvLatest = latestQuantity(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli))
        async let hrvBaseline = averageQuantity(
            .heartRateVariabilitySDNN, unit: .secondUnit(with: .milli),
            from: thirtyDaysAgo, to: now
        )
        async let rhrLatest = latestQuantity(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()))
        async let rhrBaseline = averageQuantity(
            .restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()),
            from: thirtyDaysAgo, to: now
        )
        async let sleep = lastNightSleep(now: now)
        async let strain = yesterdayWorkoutKcal(now: now)
        let slept = await sleep
        return ReadinessAggregates(
            hrvLatestMs: await hrvLatest,
            hrvBaselineMs: await hrvBaseline,
            restingHRLatestBpm: await rhrLatest,
            restingHRBaselineBpm: await rhrBaseline,
            sleepSeconds: slept?.asleep,
            sleepEfficiency: slept?.efficiency,
            priorDayWorkoutKcal: await strain
        )
    }

    // MARK: - Query shapes (same bridging as TodayMetricsProvider)

    /// Latest sample within the past 7 days (L3): a watch unworn for
    /// months still holds ancient HRV/RHR samples, and scoring those as
    /// current would render a stale-data score as fresh. Older than 7 days
    /// reads as no data — the hero degrades to pending/insufficient.
    private func latestQuantity(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit) async -> Double? {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return nil }
        let cutoff = calendar.date(byAdding: .day, value: -7, to: Date())
        let predicate = cutoff.map { HKQuery.predicateForSamples(withStart: $0, end: nil, options: []) }
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: 1,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            ) { _, samples, _ in
                guard let sample = samples?.first as? HKQuantitySample else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: sample.quantity.doubleValue(for: unit))
            }
            healthStore.execute(query)
        }
    }

    private func averageQuantity(
        _ identifier: HKQuantityTypeIdentifier, unit: HKUnit, from start: Date, to end: Date
    ) async -> Double? {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .discreteAverage
            ) { _, statistics, _ in
                guard let average = statistics?.averageQuantity() else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: average.doubleValue(for: unit))
            }
            healthStore.execute(query)
        }
    }

    private func lastNightSleep(now: Date) async -> (asleep: Double, efficiency: Double?)? {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
        let startOfDay = calendar.startOfDay(for: now)
        let windowStart = startOfDay.addingTimeInterval(-6 * 3600)
        // Window ends at noon (L3), not now: a 2pm nap is not "last
        // night". Morning wake-ups still fall inside 6pm..noon, so only
        // post-noon samples — naps — are excluded.
        let noon = startOfDay.addingTimeInterval(12 * 3600)
        let predicate = HKQuery.predicateForSamples(withStart: windowStart, end: min(now, noon), options: [])
        let asleepValues: Set<Int> = [1, 3, 4, 5]
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, _ in
                let category = (samples ?? []).compactMap { $0 as? HKCategorySample }
                guard !category.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                let asleep = category
                    .filter { asleepValues.contains($0.value) }
                    .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
                guard asleep > 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                // In-bed span: first sample start to last sample end across
                // all stages (in-bed/awake included) — efficiency is
                // asleep ÷ span, clamped to a fraction.
                let spanStart = category.map(\.startDate).min()!
                let spanEnd = category.map(\.endDate).max()!
                let span = spanEnd.timeIntervalSince(spanStart)
                let efficiency = span > 0 ? min(max(asleep / span, 0), 1) : nil
                continuation.resume(returning: (asleep, efficiency))
            }
            healthStore.execute(query)
        }
    }

    private func yesterdayWorkoutKcal(now: Date) async -> Double? {
        let startOfDay = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfDay) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: yesterday, end: startOfDay, options: [])
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, _ in
                let workouts = (samples ?? []).compactMap { $0 as? HKWorkout }
                guard !workouts.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                let energyType = HKQuantityType(.activeEnergyBurned)
                let total = workouts.reduce(0.0) {
                    $0 + ($1.statistics(for: energyType)?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0)
                }
                continuation.resume(returning: total)
            }
            healthStore.execute(query)
        }
    }
}

// MARK: - Score history (UserDefaults ring for the delta caption)

/// The last-30 scored mornings, day-stamped so a same-day refresh replaces
/// instead of duplicating. Mirrors `TodayMetricPreferences`' conventions
/// (DI'd defaults, pure load/record logic testable without them).
@MainActor
struct ReadinessScoreHistory {
    private static let defaultsKey = "com.healthloom.settings.readinessScores"
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Scores for the engine's `recentScores` (today excluded — the delta
    /// compares against prior mornings, not itself).
    func recentScores(today: Date = Date()) -> [Int] {
        Self.load(from: defaults).filter { $0.day != Self.dayString(today) }.map(\.score)
    }

    func record(score: Int, today: Date = Date()) {
        var entries = Self.load(from: defaults).filter { $0.day != Self.dayString(today) }
        entries.append(Entry(day: Self.dayString(today), score: score))
        defaults.set(Array(entries.suffix(30)).map { [$0.day, String($0.score)] }, forKey: Self.defaultsKey)
    }

    private struct Entry: Equatable {
        var day: String
        var score: Int
    }

    private static func dayString(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private static func load(from defaults: UserDefaults) -> [Entry] {
        guard let raw = defaults.array(forKey: defaultsKey) as? [[String]] else { return [] }
        return raw.compactMap { pair in
            guard pair.count == 2, let score = Int(pair[1]) else { return nil }
            return Entry(day: pair[0], score: score)
        }
    }
}
