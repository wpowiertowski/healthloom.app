// DataTrendProvider.swift
//
// WP-56: the HealthKit side of the Data tab's 7-day vs 30-day trends -- one
// day-keyed series per Apple Health-backed row, handed to the pure
// `RollingTrend` (DataTrend.swift). Reads Apple Health, not the Google
// feed: HealthKit's statistics merge sources honestly (watch-recorded
// workout segments plus the Fitbit baseline, architecture.md D13.3), so
// the average describes the person, not one device.
//
// Thin adapter, same posture as `TodayMetricsProvider`: a failed or
// unauthorized query yields an empty series, and the row shows "No recent
// data" -- the screen never errors. Not unit-tested (the simulator store
// holds no data a test could rely on); the averaging it feeds is.

import CoreModel
import Foundation
import HealthKit

@MainActor
final class DataTrendProvider {
    private let healthStore: HKHealthStore
    private let calendar: Calendar

    init(healthStore: HKHealthStore = HKHealthStore(), calendar: Calendar = .current) {
        self.healthStore = healthStore
        self.calendar = calendar
    }

    /// Trends for every type in `types` that has one and has data.
    func trends(for types: [GoogleDataType], now: Date = Date()) async -> [GoogleDataType: RollingTrend] {
        guard HKHealthStore.isHealthDataAvailable() else { return [:] }
        var trends: [GoogleDataType: RollingTrend] = [:]
        for type in types {
            let daily = await dailyValues(for: type, now: now)
            if let trend = RollingTrend.from(daily: daily, now: now, calendar: calendar) {
                trends[type] = trend
            }
        }
        return trends
    }

    private func dailyValues(for type: GoogleDataType, now: Date) async -> [Date: Double] {
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -RollingTrend.monthDays, to: today) else { return [:] }
        switch type {
        case .steps:
            return await daily(.stepCount, unit: .count(), options: .cumulativeSum, from: start, to: today)
        case .heartRate:
            return await daily(
                .heartRate, unit: HKUnit.count().unitDivided(by: .minute()),
                options: .discreteAverage, from: start, to: today
            )
        case .weight:
            return await daily(.bodyMass, unit: .gramUnit(with: .kilo), options: .discreteAverage, from: start, to: today)
        case .sleep:
            return await nightlyAsleep(from: start, to: now)
        default:
            return [:]
        }
    }

    /// One statistic per calendar day in `start ..< end`, days without
    /// samples left out.
    private func daily(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        options: HKStatisticsOptions,
        from start: Date,
        to end: Date
    ) async -> [Date: Double] {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return [:] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let calendar = calendar
        return await withCheckedContinuation { (continuation: CheckedContinuation<[Date: Double], Never>) in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: options,
                anchorDate: start,
                intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { _, collection, _ in
                var values: [Date: Double] = [:]
                collection?.enumerateStatistics(from: start, to: end) { statistics, _ in
                    let quantity = options.contains(.cumulativeSum)
                        ? statistics.sumQuantity()
                        : statistics.averageQuantity()
                    if let quantity {
                        values[calendar.startOfDay(for: statistics.startDate)] = quantity.doubleValue(for: unit)
                    }
                }
                continuation.resume(returning: values)
            }
            healthStore.execute(query)
        }
    }

    /// Asleep seconds per night (`RollingTrend.nightlyAsleep`).
    private func nightlyAsleep(from start: Date, to end: Date) async -> [Date: Double] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [:] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let calendar = calendar
        return await withCheckedContinuation { (continuation: CheckedContinuation<[Date: Double], Never>) in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, _ in
                let asleep = (samples ?? [])
                    .compactMap { $0 as? HKCategorySample }
                    .filter { AsleepTime.categoryValues.contains($0.value) }
                    .map { DateInterval(start: $0.startDate, end: $0.endDate) }
                continuation.resume(returning: RollingTrend.nightlyAsleep(asleep, calendar: calendar))
            }
            healthStore.execute(query)
        }
    }
}
