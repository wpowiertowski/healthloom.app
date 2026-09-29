// DataTrend.swift
//
// WP-56: what the Data tab's rows show instead of a raw count. The count
// beside Heart Rate (373,285) was the number of readings ever synced -- it
// read as a heart rate and meant nothing at a glance. Each row now shows the
// last 7 days' average and how it compares with the last 30 days'.
//
// Pure: day-keyed values in, averages and display strings out. The one
// HealthKit adapter is DataTrendProvider.swift; the local-only rows feed
// their `LocalSample`s through `dailySums` here.

import CoreModel
import Foundation
import SyncKit

/// The last 7 days' average against the last 30 days'.
///
/// `nonisolated` (WP-57): pure math that HealthKit's result handlers call on
/// HealthKit's own queues. Under the target's default MainActor isolation
/// its closures carried a main-actor check, and build 21 crashed at launch
/// the first time a real night of sleep reached one.
nonisolated struct RollingTrend: Equatable {
    static let weekDays = 7
    static let monthDays = 30

    let weekAverage: Double
    let monthAverage: Double
    var delta: Double { weekAverage - monthAverage }

    /// `daily` maps the start of a day to that day's value; days without data
    /// are absent, never zero (a day the watch sat in a drawer isn't a
    /// 0-step day). Only completed days count -- a half-finished today would
    /// drag every daily total down -- so the week is the 7 days before
    /// `now`'s day, the month the 30 before it. `nil` when the week holds no
    /// data.
    static func from(daily: [Date: Double], now: Date, calendar: Calendar) -> RollingTrend? {
        let today = calendar.startOfDay(for: now)
        guard let weekStart = calendar.date(byAdding: .day, value: -weekDays, to: today),
              let monthStart = calendar.date(byAdding: .day, value: -monthDays, to: today)
        else { return nil }
        let week = daily.filter { $0.key >= weekStart && $0.key < today }.map(\.value)
        let month = daily.filter { $0.key >= monthStart && $0.key < today }.map(\.value)
        guard !week.isEmpty else { return nil }
        return RollingTrend(
            weekAverage: week.reduce(0, +) / Double(week.count),
            monthAverage: month.reduce(0, +) / Double(month.count)
        )
    }

    /// Sums `values` into the day each one's date falls on.
    static func dailySums(_ values: [(date: Date, value: Double)], calendar: Calendar) -> [Date: Double] {
        values.reduce(into: [:]) { sums, item in
            sums[calendar.startOfDay(for: item.date), default: 0] += item.value
        }
    }

    /// Asleep time per night, keyed by the day the night began: a sample is
    /// filed 12 hours earlier, so 23:00 and 02:00 land on the same evening
    /// and last night counts as a completed day. Overlapping intervals are
    /// merged first, so overlaps within the night's winning source count once
    /// (`DataTrendProvider` picks that source per night, WP-60).
    static func nightlyAsleep(_ intervals: [DateInterval], calendar: Calendar) -> [Date: Double] {
        AsleepTime.merged(intervals).reduce(into: [:]) { nights, interval in
            nights[SleepSourceSelection.night(of: interval.start, calendar: calendar), default: 0] += interval.duration
        }
    }
}

/// Asleep time from HealthKit sleep samples, shared by the Today panel's
/// last night and the Data tab's nightly average. `nonisolated` for the
/// same reason as `RollingTrend`: it runs inside HealthKit's callbacks.
nonisolated enum AsleepTime {
    /// Asleep-stage raw values (HKCategoryValueSleepAnalysis):
    /// asleepUnspecified = 1, asleepCore = 3, asleepDeep = 4, asleepREM = 5
    /// -- inBed (0) and awake (2) never count. Same literal set SyncKit's
    /// MappedSleepStage pins (and cross-checks against the real enum in its
    /// own tests).
    static let categoryValues: Set<Int> = [1, 3, 4, 5]

    /// `intervals` with every overlap collapsed, sorted by start: an Apple
    /// Watch and a Fitbit both recording one night count it once.
    static func merged(_ intervals: [DateInterval]) -> [DateInterval] {
        var merged: [DateInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    /// Total asleep seconds across `intervals`, overlaps counted once.
    static func total(_ intervals: [DateInterval]) -> TimeInterval {
        merged(intervals).reduce(0) { $0 + $1.duration }
    }
}

/// How one Data-tab row reads its trend: the metric it averages, and how the
/// values print.
nonisolated enum DataTrendMetric: Equatable {
    /// Formatted by the Today panel's own rules (units, metric/imperial).
    case today(TodayMetricKind)
    /// Minutes per day, from local-only samples' `minutes` value.
    case minutesPerDay

    /// The metric for a Data-tab type, or `nil` for a type with no trend
    /// (ECG and irregular-rhythm notifications are events, counted instead).
    init?(_ type: GoogleDataType) {
        switch type {
        case .steps: self = .today(.steps)
        case .heartRate: self = .today(.heart)
        case .weight: self = .today(.weight)
        case .sleep: self = .today(.sleep)
        case .activeZoneMinutes, .activeMinutes: self = .minutesPerDay
        default: return nil
        }
    }
}

/// The strings a row renders for its trend.
struct DataTrendText: Equatable {
    /// "62 bpm", "8,240", "7h 12m", "34 min"; "No recent data" when empty.
    let value: String
    /// "7d avg · +3 vs 30d"; nil when there's no trend.
    let comparison: String?

    static let empty = DataTrendText(value: "No recent data", comparison: nil)

    static func make(
        _ trend: RollingTrend?,
        metric: DataTrendMetric,
        locale: Locale,
        units: UnitPreferences
    ) -> DataTrendText {
        guard let trend else { return .empty }
        let average = format(trend.weekAverage, metric: metric, locale: locale, units: units)
        let change = format(abs(trend.delta), metric: metric, locale: locale, units: units)
        let zero = format(0, metric: metric, locale: locale, units: units)
        let comparison: String
        if change == zero {
            comparison = "7d avg · same as 30d"
        } else {
            comparison = "7d avg · \(trend.delta > 0 ? "+" : "−")\(change) vs 30d"
        }
        return DataTrendText(value: average, comparison: comparison)
    }

    /// Counted events (ECG recordings, irregular-rhythm notifications) in
    /// the last 30 days -- an average of those means nothing.
    static func events(count: Int, noun: (one: String, many: String)) -> DataTrendText {
        DataTrendText(
            value: count == 0 ? "None" : "\(count) \(count == 1 ? noun.one : noun.many)",
            comparison: "last \(RollingTrend.monthDays) days"
        )
    }

    /// A local-only row's trend, from its `LocalSample`s: minutes per day
    /// for Active Zone Minutes and Active Minutes, a 30-day event count for
    /// ECG and irregular-rhythm notifications.
    /// A local-only row's trend from its off-main summary (WP-67,
    /// `LocalRowSummarizer`): minutes per day, or an event count.
    static func local(
        type: GoogleDataType,
        summary: LocalRowSummary,
        locale: Locale,
        units: UnitPreferences
    ) -> DataTrendText {
        guard let metric = DataTrendMetric(type) else {
            let noun = type == .electrocardiogram ? ("recording", "recordings") : ("notification", "notifications")
            return events(count: summary.recentCount, noun: noun)
        }
        return make(summary.trend, metric: metric, locale: locale, units: units)
    }

    /// The value key GoogleHealthClient's schema writes Active Zone Minutes
    /// and Active Minutes under (`GoogleDataTypeSchema`, `value("minutes", ...)`).
    nonisolated static let minutesKey = "minutes"

    private static func format(
        _ value: Double,
        metric: DataTrendMetric,
        locale: Locale,
        units: UnitPreferences
    ) -> String {
        switch metric {
        case .today(let kind):
            let display = TodayMetricFormatter.display(
                kind: kind,
                reading: TodayMetricReading(value: value, date: nil),
                locale: locale,
                units: units
            )
            return [display.value, display.unit].compactMap { $0 }.joined(separator: " ")
        case .minutesPerDay:
            return "\(TodayMetricFormatter.groupedCount(value.rounded(), locale: locale)) min"
        }
    }
}
