// LastNightSleep.swift
//
// WP-59: "last night" for the Today sleep row and the readiness score --
// one window, one summary. The two used to keep their own copies (the row
// ran to `now`, readiness stopped at noon), so after an afternoon nap the
// same screen showed two different nights. Everything here runs inside
// HealthKit result handlers, off the main actor, hence `nonisolated`.

import Foundation
import HealthKit

/// One sleep-analysis sample, reduced to what the sleep math reads.
nonisolated struct SleepStageSample: Equatable, Sendable {
    /// `HKCategoryValueSleepAnalysis` raw value.
    var value: Int
    var interval: DateInterval

    /// A sleep-analysis query's results; anything but a category sample is
    /// dropped.
    static func from(_ samples: [HKSample]?) -> [SleepStageSample] {
        (samples ?? []).compactMap { sample in
            guard let category = sample as? HKCategorySample else { return nil }
            return SleepStageSample(
                value: category.value,
                interval: DateInterval(start: category.startDate, end: category.endDate)
            )
        }
    }
}

nonisolated enum LastNightSleep {
    struct Summary: Equatable {
        /// Asleep seconds inside the window, overlaps counted once.
        var asleep: Double
        /// Asleep ÷ the span from the first to the last sample (in-bed and
        /// awake included), or nil for a zero-length span.
        var efficiency: Double?
        /// When the last asleep stretch ended.
        var wokeAt: Date
    }

    /// 6 pm yesterday to noon today, or to `now` before noon: wide enough
    /// for any real bedtime, and a nap after noon isn't last night. Built
    /// from wall-clock hours, so a daylight-saving change overnight doesn't
    /// shift either edge by an hour.
    static func window(now: Date, calendar: Calendar) -> DateInterval? {
        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
              let start = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: yesterday),
              let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: today)
        else { return nil }
        let end = min(now, noon)
        guard end > start else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// The night inside `window`, or nil with no asleep time there. Samples
    /// are clipped to the window first: an evening nap that began before
    /// 6 pm counts only its part inside, and doesn't stretch the span.
    static func summary(of samples: [SleepStageSample], in window: DateInterval) -> Summary? {
        let clipped = samples.compactMap { sample -> SleepStageSample? in
            guard let inside = sample.interval.intersection(with: window), inside.duration > 0 else { return nil }
            return SleepStageSample(value: sample.value, interval: inside)
        }
        let asleepIntervals = clipped.filter { AsleepTime.categoryValues.contains($0.value) }.map(\.interval)
        let asleep = AsleepTime.total(asleepIntervals)
        guard asleep > 0,
              let wokeAt = asleepIntervals.map(\.end).max(),
              let spanStart = clipped.map(\.interval.start).min(),
              let spanEnd = clipped.map(\.interval.end).max()
        else { return nil }
        let span = spanEnd.timeIntervalSince(spanStart)
        let efficiency = span > 0 ? min(max(asleep / span, 0), 1) : nil
        return Summary(asleep: asleep, efficiency: efficiency, wokeAt: wokeAt)
    }
}
