// TodayMetricsProvider.swift
//
// WP-33 (implementation-plan.md) step 1: "metric rows <- HealthKit ...
// today-values." The one HealthKit-touching piece of the Today screen --
// KnowledgeStore (WP-19, P2) will later own richer derivations; this
// provider reads only the simple per-kind "today" facts the instrument
// panel renders:
//   - cumulative sums since local midnight (steps, distance, active
//     energy) via `HKStatisticsQuery(.cumulativeSum)` -- which merges
//     sources honestly, so watch-recorded workout segments and
//     Fitbit-imported baseline compose per architecture.md D13.3;
//   - the latest sample (heart rate, blood oxygen, weight) via a
//     limit-1 descending `HKSampleQuery`;
//   - last night's asleep total (sleep) -- asleep-stage category samples
//     (unspecified/core/deep/REM, never inBed/awake) between 6 pm
//     yesterday and now, summed.
//
// Error/empty posture, same as `ActivitiesProvider`: any per-kind query
// failure (including read authorization never granted -- reads never
// reveal denial, WP-06's rule) yields no reading for that kind, and the
// row renders its "No data yet" empty state (WP-33 step 4) -- the screen
// never errors.

import Foundation
import HealthKit

@MainActor
final class TodayMetricsProvider {
    private let healthStore: HKHealthStore
    private let calendar: Calendar

    init(healthStore: HKHealthStore = HKHealthStore(), calendar: Calendar = .current) {
        self.healthStore = healthStore
        self.calendar = calendar
    }

    func readings(for kinds: [TodayMetricKind], now: Date = Date()) async -> [TodayMetricKind: TodayMetricReading] {
        guard HKHealthStore.isHealthDataAvailable() else { return [:] }
        var readings: [TodayMetricKind: TodayMetricReading] = [:]
        for kind in kinds {
            if let reading = await reading(for: kind, now: now) {
                readings[kind] = reading
            }
        }
        return readings
    }

    private func reading(for kind: TodayMetricKind, now: Date) async -> TodayMetricReading? {
        let startOfDay = calendar.startOfDay(for: now)
        switch kind {
        case .steps:
            return await todaySum(.stepCount, unit: .count(), from: startOfDay, to: now)
        case .distance:
            return await todaySum(.distanceWalkingRunning, unit: .meter(), from: startOfDay, to: now)
        case .activeEnergy:
            return await todaySum(.activeEnergyBurned, unit: .kilocalorie(), from: startOfDay, to: now)
        case .heart:
            return await latestSample(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), now: now)
        case .bloodOxygen:
            return await latestSample(.oxygenSaturation, unit: .percent(), now: now)
        case .weight:
            return await latestSample(.bodyMass, unit: .gramUnit(with: .kilo), now: now)
        case .sleep:
            return await lastNightAsleepSeconds(now: now, startOfDay: startOfDay)
        }
    }

    // MARK: - Query shapes

    private func todaySum(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        from start: Date,
        to end: Date
    ) async -> TodayMetricReading? {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        return await withCheckedContinuation { (continuation: CheckedContinuation<TodayMetricReading?, Never>) in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, statistics, _ in
                guard let sum = statistics?.sumQuantity() else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: TodayMetricReading(value: sum.doubleValue(for: unit), date: end))
            }
            healthStore.execute(query)
        }
    }

    /// A reading counts as current only inside this window (round-10
    /// item 4): without a bound, a months-old HR/SpO2/weight sample
    /// renders as a fresh "Latest" reading. Older samples yield no
    /// reading, so the row shows its "No data yet" empty state — a
    /// stale UI state, never a fresh-looking number.
    nonisolated static let latestSampleRecency: TimeInterval = 7 * 24 * 3600

    /// Testable recency rule (the query predicate below enforces the
    /// same bound — HealthKit predicates aren't unit-observable without
    /// a store, so the Swift-side check carries the pin).
    nonisolated static func isFresh(_ reading: TodayMetricReading, now: Date) -> Bool {
        guard let date = reading.date else { return false }
        return now.timeIntervalSince(date) <= latestSampleRecency
    }

    private func latestSample(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, now: Date) async -> TodayMetricReading? {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(
            withStart: now.addingTimeInterval(-Self.latestSampleRecency),
            end: now,
            options: []
        )
        return await withCheckedContinuation { (continuation: CheckedContinuation<TodayMetricReading?, Never>) in
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
                let reading = TodayMetricReading(
                    value: sample.quantity.doubleValue(for: unit),
                    date: sample.endDate
                )
                continuation.resume(returning: Self.isFresh(reading, now: now) ? reading : nil)
            }
            healthStore.execute(query)
        }
    }

    private func lastNightAsleepSeconds(now: Date, startOfDay: Date) async -> TodayMetricReading? {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
        // "Last night" = 6 pm yesterday .. now: wide enough for any real
        // bedtime, narrow enough to exclude the previous night.
        let windowStart = startOfDay.addingTimeInterval(-6 * 3600)
        let predicate = HKQuery.predicateForSamples(withStart: windowStart, end: now, options: [])
        // Asleep-stage raw values (HKCategoryValueSleepAnalysis):
        // asleepUnspecified = 1, asleepCore = 3, asleepDeep = 4,
        // asleepREM = 5 -- inBed (0) and awake (2) are excluded from the
        // total. Same literal set SyncKit's MappedSleepStage pins (and
        // cross-checks against the real enum in its own tests).
        let asleepValues: Set<Int> = [1, 3, 4, 5]
        return await withCheckedContinuation { (continuation: CheckedContinuation<TodayMetricReading?, Never>) in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, _ in
                let categorySamples = (samples ?? []).compactMap { $0 as? HKCategorySample }
                let asleep = categorySamples.filter { asleepValues.contains($0.value) }
                guard !asleep.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                let total = asleep.reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
                let latestEnd = asleep.map(\.endDate).max()
                continuation.resume(returning: TodayMetricReading(value: total, date: latestEnd))
            }
            healthStore.execute(query)
        }
    }
}
