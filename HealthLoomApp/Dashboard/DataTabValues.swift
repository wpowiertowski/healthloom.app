// DataTabValues.swift
//
// WP-81: the Data tab's last known numbers, kept across launches. The rows'
// 7-day averages come from Apple Health queries (and a local-sample fetch)
// that take a few seconds, and the tab opened on "No recent data" in every
// row until they returned. Now the last values computed show at once, and
// fresh ones replace them when the queries finish.
//
// Raw averages and counts, not display strings: a unit or locale change
// reformats them like fresh values. Kept in the app's defaults, which the
// wipe flow erases with everything else (`WipeFlowView`'s resetDefaults),
// and never written once a wipe has latched -- a refresh landing after the
// wipe must not put them back.

import CoreModel
import Foundation
import Observation

/// What the Data tab's rows show, as plain values.
nonisolated struct DataTabSnapshot: Codable, Equatable, Sendable {
    /// Apple Health trends, per P0 row (`DataTrendProvider`).
    var trends: [GoogleDataType: RollingTrend]
    /// The in-app rows' summaries (`LocalRowSummarizer`).
    var localSummaries: [GoogleDataType: LocalRowSummary]

    static let empty = DataTabSnapshot(trends: [:], localSummaries: [:])
}

/// The values the Data tab shows: the last known ones until a refresh
/// lands, then that refresh's.
@MainActor
@Observable
final class DataTabValues {
    static let defaultsKey = "dataTab.lastKnown"

    private let defaults: UserDefaults?
    private let isQuiesced: () -> Bool
    private(set) var snapshot: DataTabSnapshot

    /// `defaults` nil keeps the values in memory only: UI-test launches
    /// must not open on the numbers an earlier launch left behind.
    init(defaults: UserDefaults? = .standard, isQuiesced: @escaping () -> Bool = { WipeQuiesce.isLatched }) {
        self.defaults = defaults
        self.isQuiesced = isQuiesced
        self.snapshot = defaults?.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(DataTabSnapshot.self, from: $0) } ?? .empty
    }

    /// Shows `fresh` and keeps it for the next launch.
    func update(_ fresh: DataTabSnapshot) {
        guard !isQuiesced(), fresh != snapshot else { return }
        snapshot = fresh
        if let data = try? JSONEncoder().encode(fresh) {
            defaults?.set(data, forKey: Self.defaultsKey)
        }
    }
}
