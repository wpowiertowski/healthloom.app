// HRVHealthKitMigrationTests.swift
//
// WP-62: the one-time HRV move -- history restarted, in-app rows deleted,
// once, and only after both succeed.

import CoreModel
import Foundation
import SwiftData
import Testing
@testable import HealthLoom

@Suite("HRV to Apple Health migration")
@MainActor
struct HRVHealthKitMigrationTests {
    private struct Refused: Error {}

    // catches: deleting another type's in-app rows (ECG, zone minutes are
    // still local-only) along with HRV's.
    @Test func onlyHRVRowsAreDeleted() throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let context = ModelContext(container)
        for (id, type) in [("hrv-1", GoogleDataType.heartRateVariability), ("hrv-2", .heartRateVariability), ("ecg-1", .electrocardiogram)] {
            context.insert(LocalSample(externalID: id, dataType: type.rawValue, payloadJSON: Data(), start: .now, end: .now, source: "Fitbit"))
        }
        try context.save()

        #expect(try HRVHealthKitMigration.deleteLocalRows(in: container) == 2)
        let left = try ModelContext(container).fetch(FetchDescriptor<LocalSample>())
        #expect(left.map(\.dataType) == [GoogleDataType.electrocardiogram.rawValue])
    }

    // catches: marking the move done when the history restart failed (the
    // past nights would never reach Apple Health), or re-running it on
    // every foreground.
    @Test func runsUntilItSucceedsThenNeverAgain() async throws {
        let ephemeral = try EphemeralDefaults(prefix: "hrvmigration")
        var restarts = 0
        await HRVHealthKitMigration.runIfNeeded(
            defaults: ephemeral.defaults,
            restartHistory: { restarts += 1; throw Refused() },
            deleteLocalRows: { 0 }
        )
        await HRVHealthKitMigration.runIfNeeded(
            defaults: ephemeral.defaults,
            restartHistory: { restarts += 1 },
            deleteLocalRows: { 0 }
        )
        await HRVHealthKitMigration.runIfNeeded(
            defaults: ephemeral.defaults,
            restartHistory: { restarts += 1 },
            deleteLocalRows: { 0 }
        )
        #expect(restarts == 2)
    }
}
