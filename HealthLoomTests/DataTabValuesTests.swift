// DataTabValuesTests.swift
//
// WP-81: the Data tab opens on its last known numbers, and a wipe keeps
// them from coming back.

import CoreModel
import Foundation
import Testing
@testable import HealthLoom

@MainActor
@Suite("Data tab values", .serialized)
struct DataTabValuesTests {
    private static let suite = "data-tab-values-tests"

    private static let sample = DataTabSnapshot(
        trends: [.heartRate: RollingTrend(weekAverage: 61.4, monthAverage: 63)],
        localSummaries: [.electrocardiogram: LocalRowSummary(trend: nil, recentCount: 2, lastSample: Date(timeIntervalSince1970: 1_790_000_000))]
    )

    private func freshDefaults() throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: Self.suite))
        defaults.removePersistentDomain(forName: Self.suite)
        return defaults
    }

    // catches: the tab opening on "No recent data" every launch -- values
    // shown but never kept, or kept in a shape the next launch can't read.
    @Test func lastValuesOpenTheNextLaunch() throws {
        let defaults = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: Self.suite) }

        #expect(DataTabValues(defaults: defaults, isQuiesced: { false }).snapshot == .empty)
        DataTabValues(defaults: defaults, isQuiesced: { false }).update(Self.sample)
        #expect(DataTabValues(defaults: defaults, isQuiesced: { false }).snapshot == Self.sample)

        defaults.set(Data("not json".utf8), forKey: DataTabValues.defaultsKey)
        #expect(DataTabValues(defaults: defaults, isQuiesced: { false }).snapshot == .empty)
    }

    // catches: a refresh landing after "Delete all data" writing health
    // numbers back into the defaults the wipe just erased.
    @Test func nothingIsKeptOnceAWipeLatched() throws {
        let defaults = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: Self.suite) }

        DataTabValues(defaults: defaults, isQuiesced: { true }).update(Self.sample)
        #expect(defaults.data(forKey: DataTabValues.defaultsKey) == nil)
    }
}
