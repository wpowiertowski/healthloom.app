// LocalRowSummarizer.swift
//
// WP-67: the Data tab's "Not in Apple Health" rows, summarized off the main
// thread. The tab used to `@Query` every `LocalSample` and recompute each
// row's 30-day trend on every render, decoding every sample's payload JSON.
// Active Minutes arrive per minute (~1,400 rows a sync), so that was tens
// of thousands of rows -- and a sync saving every few seconds re-ran the
// query and the decode on the main thread each time. Switching tabs
// mid-sync then hung the app until the watchdog killed it. Now a background
// context fetches only the last 30 days per type (plus the newest sample),
// and the tab reloads the summaries when a Sync Now starts or finishes,
// like the Apple Health trends beside them.

import CoreModel
import Foundation
import SwiftData

/// What one in-app row shows, as plain values.
nonisolated struct LocalRowSummary: Codable, Sendable, Equatable {
    /// Minutes-per-day trend (Active Zone Minutes, Active Minutes).
    var trend: RollingTrend?
    /// Events in the last 30 days (ECG, irregular-rhythm notifications).
    var recentCount: Int
    var lastSample: Date?

    static let empty = LocalRowSummary(trend: nil, recentCount: 0, lastSample: nil)

    /// From one type's recent samples. Pure, so tests pin the arithmetic.
    static func make(
        type: GoogleDataType,
        recent samples: [LocalSample],
        lastSample: Date?,
        now: Date,
        calendar: Calendar
    ) -> LocalRowSummary {
        let since = calendar.date(byAdding: .day, value: -RollingTrend.monthDays, to: now) ?? now
        guard DataTrendMetric(type) != nil else {
            let count = samples.filter { $0.start >= since && $0.start <= now }.count
            return LocalRowSummary(trend: nil, recentCount: count, lastSample: lastSample)
        }
        let minutes = samples.compactMap { sample in
            sample.payloadValues[DataTrendText.minutesKey].map { (date: sample.start, value: $0) }
        }
        let trend = RollingTrend.from(daily: RollingTrend.dailySums(minutes, calendar: calendar), now: now, calendar: calendar)
        return LocalRowSummary(trend: trend, recentCount: 0, lastSample: lastSample)
    }
}

@ModelActor
actor LocalRowSummarizer {
    /// One summary per type: its samples from the last 31 days (the trend's
    /// 30 completed days plus today) and its newest sample's end.
    func summaries(for types: [GoogleDataType], now: Date, calendar: Calendar) -> [GoogleDataType: LocalRowSummary] {
        let since = calendar.date(byAdding: .day, value: -(RollingTrend.monthDays + 1), to: now) ?? now
        var result: [GoogleDataType: LocalRowSummary] = [:]
        for type in types {
            let key = type.rawValue
            let recent = (try? modelContext.fetch(FetchDescriptor<LocalSample>(
                predicate: #Predicate { $0.dataType == key && $0.start >= since }
            ))) ?? []
            var newest = FetchDescriptor<LocalSample>(
                predicate: #Predicate { $0.dataType == key },
                sortBy: [SortDescriptor(\.end, order: .reverse)]
            )
            newest.fetchLimit = 1
            let lastSample = (try? modelContext.fetch(newest))?.first?.end
            result[type] = LocalRowSummary.make(type: type, recent: recent, lastSample: lastSample, now: now, calendar: calendar)
        }
        return result
    }
}
