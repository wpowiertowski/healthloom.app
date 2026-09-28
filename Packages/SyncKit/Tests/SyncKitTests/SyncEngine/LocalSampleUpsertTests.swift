// LocalSampleUpsertTests.swift
//
// WP-68: in-app samples upsert as a batch, and an unchanged row is left
// alone -- each sync re-pulls ~4,300 per-minute Active Minutes rows, and
// rewriting them all held the app's own screen queries up mid-sync.

#if canImport(HealthKit)
import CoreModel
import Foundation
import GoogleHealthClient
import SwiftData
import Testing
@testable import SyncKit

@Suite struct LocalSampleUpsertTests {
    static let start = Date(timeIntervalSince1970: 1_790_467_200)

    static func point(_ index: Int, minutes: Double = 1) -> GoogleDataPoint {
        GoogleDataPoint(
            id: "am-\(index)",
            dataType: .activeMinutes,
            start: start.addingTimeInterval(Double(index) * 60),
            end: start.addingTimeInterval(Double(index) * 60 + 60),
            source: DataSource(platform: "IOS", deviceDisplayName: "Fitbit Air", recordingMethod: "AUTOMATICALLY_RECORDED"),
            values: ["minutes": minutes]
        )
    }

    static func rows(_ container: ModelContainer) throws -> [LocalSample] {
        try ModelContext(container).fetch(FetchDescriptor<LocalSample>())
    }

    // catches: every re-pulled, unchanged row rewritten on each sync (the
    // store churn that stalled the screens mid-sync).
    @Test func reUpsertingUnchangedPointsChangesNothing() throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let points = (0..<50).map { Self.point($0) }
        try PagePipeline.upsertLocalSamples(points, context: context)
        try context.save()

        try PagePipeline.upsertLocalSamples(points, context: context)
        #expect(!context.hasChanges)
    }

    // catches: skipping a row whose payload really changed (Google revised
    // a minute), or inserting a second row for it.
    @Test func aChangedPointUpdatesItsRow() throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let context = ModelContext(container)
        try PagePipeline.upsertLocalSamples([Self.point(1, minutes: 1)], context: context)
        try context.save()

        try PagePipeline.upsertLocalSamples([Self.point(1, minutes: 0)], context: context)
        #expect(context.hasChanges)
        try context.save()
        let rows = try Self.rows(container)
        #expect(rows.count == 1)
        #expect(rows.first?.payloadValues["minutes"] == 0)
    }

    // catches: one ID twice in a batch inserting two rows (the in-batch
    // map missing its own inserts), and batches past one fetch slice
    // missing existing rows -- re-inserted on the second pass. (The store's
    // unique constraint would merge either at save, hiding the churn, so
    // the checks are on what the batch hands the store.)
    @Test func batchesDedupeAcrossRepeatsAndSlices() throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let count = PagePipeline.upsertFetchSlice * 2 + 7
        let points = (0..<count).map { Self.point($0) } + [Self.point(0, minutes: 2)]
        try PagePipeline.upsertLocalSamples(points, context: context)
        #expect(context.insertedModelsArray.count == count)
        try context.save()
        try PagePipeline.upsertLocalSamples(points, context: context)
        #expect(context.insertedModelsArray.isEmpty)
        try context.save()

        let rows = try Self.rows(container)
        #expect(rows.count == count)
        #expect(rows.first { $0.externalID == "am-0" }?.payloadValues["minutes"] == 2)
    }
}
#endif
