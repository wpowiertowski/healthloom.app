// MetricFormatting.swift
// CoreModel
//
// The one shared home for user-facing number/duration formatting (code
// review finding: `KnowledgeDerivation` in CoachKit and
// `TodayMetricFormatter` in the app target each carried a byte-identical
// `groupedCount`, and `duration` existed twice with only one copy holding
// the negative-input clamp -- the next fix would have landed once and
// fixed half the surfaces). Both call sites delegate here; this file owns
// the implementations. Pure, locale-injectable, dependency-free -- and
// explicitly `nonisolated` (this target defaults to MainActor isolation;
// a formatter touching nothing but its arguments must not demand an actor
// hop from off-main callers).

import Foundation

/// Shared metric formatting. Both implementations delegate here so copy or
/// edge-case fixes land once.
nonisolated public enum MetricFormatting {
    /// `NumberFormatter` setup is ICU work in the tens of microseconds --
    /// worth caching now that this is the single hot path for both the
    /// Today dashboard (per row, per body evaluation) and CoachKit's
    /// profile derivation (per field, per rebuild). One formatter per
    /// locale; guarded by `lock` (formatters are not thread-safe, so both
    /// lookup AND use serialize on it).
    private static let lock = NSLock()
    nonisolated(unsafe) private static var formatters: [String: NumberFormatter] = [:]

    /// Grouped integer -- "8,240" (in the given locale). One lock
    /// acquisition per call covering lookup AND use (formatters aren't
    /// thread-safe, so both serialize on it).
    public static func groupedCount(_ value: Double, locale: Locale) -> String {
        lock.withLock {
            let formatter: NumberFormatter
            if let cached = formatters[locale.identifier] {
                formatter = cached
            } else {
                let fresh = NumberFormatter()
                fresh.locale = locale
                fresh.numberStyle = .decimal
                fresh.maximumFractionDigits = 0
                formatters[locale.identifier] = fresh
                formatter = fresh
            }
            return formatter.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value.rounded()))"
        }
    }

    /// "7h 12m" from seconds; sub-hour durations render "42m". Clamped to
    /// 0 -- a clock-skewed sample with `end < start` would otherwise flow
    /// through Swift's truncating `/`/`%` on a negative dividend and render
    /// nonsense like "-1h -5m".
    public static func duration(seconds: Double) -> String {
        let totalMinutes = max(Int((seconds / 60).rounded()), 0)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}
