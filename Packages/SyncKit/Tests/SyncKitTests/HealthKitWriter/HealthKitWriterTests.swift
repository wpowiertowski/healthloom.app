// HealthKitWriterTests.swift
//
// WP-08 (implementation-plan.md) "Tests:" line, exercised against
// `MockHealthStore` (MockHealthStore.swift) -- no HealthKit entitlement, no
// simulator, no real `HKHealthStore` needed for any test in this file:
//   - batch composition/grouping (one save call per batch, not per sample)
//   - dedupe-diff logic (existing IDs correctly skipped)
//   - delete-by-externalID targets only the requested IDs and nothing else
//   - deleteAllAppData (delete-by-source) removes only app-written samples
//   - the workouts stub throws rather than silently no-oping
//
// The real-store counterpart of these same behaviors (save -> query finds ->
// re-save skipped -> delete-by-externalID removes only target -> delete-by-
// source removes all app samples and nothing else, per test-plan.md §3) needs
// a real HealthKit entitlement on a device/simulator and could not be run in
// this session -- see progress.md's WP-08 entry for what was done instead
// (real-API compilation verification) and what's flagged as follow-up.

#if canImport(HealthKit)
import Foundation
import HealthKit
import Testing
@testable import SyncKit

@Suite struct HealthKitWriterTests {
    // MARK: - Fixtures

    static let stepsType = HKObjectType.quantityType(forIdentifier: .stepCount)!
    static let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate)!

    static func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        guard let result = formatter.date(from: iso) else {
            fatalError("Bad fixture ISO8601 string: \(iso)")
        }
        return result
    }

    static func stepsSample(
        externalID: String,
        value: Double = 100,
        start: Date = date("2026-07-01T00:00:00Z"),
        end: Date = date("2026-07-01T01:00:00Z"),
        stampExternalID: Bool = true
    ) -> HKQuantitySample {
        HKQuantitySample(
            type: stepsType,
            quantity: HKQuantity(unit: .count(), doubleValue: value),
            start: start,
            end: end,
            metadata: stampExternalID
                ? [HKMetadataKeyExternalUUID: externalID, MappedMetadata.externalIDKey: externalID]
                : nil
        )
    }

    static func heartRateSample(
        externalID: String,
        start: Date = date("2026-07-01T00:00:00Z"),
        end: Date = date("2026-07-01T00:00:00Z")
    ) -> HKQuantitySample {
        HKQuantitySample(
            type: heartRateType,
            quantity: HKQuantity(unit: HKUnit.count().unitDivided(by: .minute()), doubleValue: 60),
            start: start,
            end: end,
            metadata: [HKMetadataKeyExternalUUID: externalID, MappedMetadata.externalIDKey: externalID]
        )
    }

    // A window wide enough to contain every fixture sample's dates above,
    // for tests that just want "everything currently in the store."
    static let farPast = date("2000-01-01T00:00:00Z")
    static let farFuture = date("2100-01-01T00:00:00Z")

    // MARK: - save: batch composition

    @Test func saveIssuesExactlyOneUnderlyingCallForTheWholeBatch() async throws {
        let mock = MockHealthStore()
        let writer = HealthKitWriter(store: mock)
        let batch: [HKObject] = [
            Self.stepsSample(externalID: "s1"),
            Self.stepsSample(externalID: "s2"),
            Self.stepsSample(externalID: "s3"),
        ]

        try await writer.save(batch)

        #expect(mock.savedBatches.count == 1)
        #expect(mock.savedBatches.first?.count == 3)
    }

    @Test func saveOfAnEmptyBatchNeverCallsTheUnderlyingStore() async throws {
        let mock = MockHealthStore()
        let writer = HealthKitWriter(store: mock)

        try await writer.save([])

        #expect(mock.savedBatches.isEmpty)
    }

    // MARK: - existingExternalIDs

    @Test func existingExternalIDsFindsInWindowSamplesAndExcludesOutOfWindowOnes() async throws {
        let mock = MockHealthStore()
        let writer = HealthKitWriter(store: mock)
        mock.seed(
            Self.stepsSample(
                externalID: "in-window",
                start: Self.date("2026-07-01T00:00:00Z"),
                end: Self.date("2026-07-01T01:00:00Z")
            ),
            isAppWritten: true
        )
        mock.seed(
            Self.stepsSample(
                externalID: "out-of-window",
                start: Self.date("2026-06-01T00:00:00Z"),
                end: Self.date("2026-06-01T01:00:00Z")
            ),
            isAppWritten: true
        )

        let ids = try await writer.existingExternalIDs(
            type: Self.stepsType,
            start: Self.date("2026-06-25T00:00:00Z"),
            end: Self.date("2026-07-02T00:00:00Z")
        )

        #expect(ids == ["in-window"])
    }

    @Test func existingExternalIDsExcludesSamplesWithoutExternalIDMetadata() async throws {
        let mock = MockHealthStore()
        let writer = HealthKitWriter(store: mock)
        mock.seed(Self.stepsSample(externalID: "unused", stampExternalID: false), isAppWritten: true)

        let ids = try await writer.existingExternalIDs(type: Self.stepsType, start: Self.farPast, end: Self.farFuture)

        #expect(ids.isEmpty)
    }

    @Test func existingExternalIDsDoesNotLeakAcrossSampleTypes() async throws {
        let mock = MockHealthStore()
        let writer = HealthKitWriter(store: mock)
        mock.seed(Self.stepsSample(externalID: "steps-id"), isAppWritten: true)
        mock.seed(Self.heartRateSample(externalID: "hr-id"), isAppWritten: true)

        let stepsIDs = try await writer.existingExternalIDs(type: Self.stepsType, start: Self.farPast, end: Self.farFuture)

        #expect(stepsIDs == ["steps-id"])
    }

    /// The core WP-09 diff pattern: query existing IDs for the page's window,
    /// then only save the objects whose external ID isn't already present.
    /// Confirms the already-existing ID is correctly identified (and would
    /// therefore be skipped by a caller performing that diff), not just that
    /// `existingExternalIDs` returns *something*.
    @Test func dedupeDiffCorrectlyIdentifiesAlreadyExistingExternalIDs() async throws {
        let mock = MockHealthStore()
        let writer = HealthKitWriter(store: mock)
        mock.seed(Self.stepsSample(externalID: "dup"), isAppWritten: true)

        let incoming: [HKQuantitySample] = [
            Self.stepsSample(externalID: "dup"),
            Self.stepsSample(externalID: "new-1"),
            Self.stepsSample(externalID: "new-2"),
        ]
        let existing = try await writer.existingExternalIDs(type: Self.stepsType, start: Self.farPast, end: Self.farFuture)
        #expect(existing == ["dup"])

        let toSave = incoming.filter { sample in
            guard let id = sample.metadata?[HKMetadataKeyExternalUUID] as? String else { return true }
            return !existing.contains(id)
        }
        try await writer.save(toSave)

        #expect(mock.savedBatches.count == 1)
        #expect(mock.savedBatches.first?.count == 2)
        #expect(mock.sampleCount(ofType: Self.stepsType) == 3) // 1 seeded + 2 newly saved
    }

    // MARK: - delete(externalIDs:type:)

    @Test func deleteByExternalIDRemovesOnlyTheRequestedIDs() async throws {
        let mock = MockHealthStore()
        let writer = HealthKitWriter(store: mock)
        mock.seed(Self.stepsSample(externalID: "keep-1"), isAppWritten: true)
        mock.seed(Self.stepsSample(externalID: "delete-me"), isAppWritten: true)
        mock.seed(Self.stepsSample(externalID: "keep-2"), isAppWritten: true)

        let deletedCount = try await writer.delete(externalIDs: ["delete-me"], type: Self.stepsType)

        #expect(deletedCount == 1)
        #expect(mock.sampleCount(ofType: Self.stepsType) == 2)
        let remaining = try await writer.existingExternalIDs(type: Self.stepsType, start: Self.farPast, end: Self.farFuture)
        #expect(remaining == ["keep-1", "keep-2"])
    }

    @Test func deleteByExternalIDDoesNotCrossContaminateOtherSampleTypes() async throws {
        let mock = MockHealthStore()
        let writer = HealthKitWriter(store: mock)
        mock.seed(Self.stepsSample(externalID: "shared-id"), isAppWritten: true)
        mock.seed(Self.heartRateSample(externalID: "shared-id"), isAppWritten: true)

        let deletedCount = try await writer.delete(externalIDs: ["shared-id"], type: Self.stepsType)

        #expect(deletedCount == 1)
        #expect(mock.sampleCount(ofType: Self.stepsType) == 0)
        #expect(mock.sampleCount(ofType: Self.heartRateType) == 1) // untouched -- different type
    }

    @Test func deleteWithEmptyExternalIDsIsANoOpAndNeverCallsTheStore() async throws {
        let mock = MockHealthStore()
        let writer = HealthKitWriter(store: mock)
        mock.seed(Self.stepsSample(externalID: "keep"), isAppWritten: true)

        let deletedCount = try await writer.delete(externalIDs: [], type: Self.stepsType)

        #expect(deletedCount == 0)
        #expect(mock.deleteObjectsCalls.isEmpty)
        #expect(mock.sampleCount(ofType: Self.stepsType) == 1)
    }

    /// The generic multi-type overload (`delete(externalIDs:types:)`) —
    /// D13.4's retroactive cleanup shape: one external-ID set, swept across
    /// every candidate type, counts summed.
    @Test func deleteAcrossMultipleTypesSumsTheDeletedCounts() async throws {
        let mock = MockHealthStore()
        let writer = HealthKitWriter(store: mock)
        mock.seed(Self.stepsSample(externalID: "shared-id"), isAppWritten: true)
        mock.seed(Self.heartRateSample(externalID: "shared-id"), isAppWritten: true)
        mock.seed(Self.stepsSample(externalID: "untouched"), isAppWritten: true)

        let total = try await writer.delete(externalIDs: ["shared-id"], types: [Self.stepsType, Self.heartRateType])

        #expect(total == 2)
        #expect(mock.sampleCount(ofType: Self.stepsType) == 1) // "untouched" survives
        #expect(mock.sampleCount(ofType: Self.heartRateType) == 0)
    }

    // MARK: - deleteAllAppData (delete-by-source)

    @Test func deleteAllAppDataRemovesOnlyAppWrittenSamples() async throws {
        let mock = MockHealthStore()
        let writer = HealthKitWriter(store: mock)
        mock.seed(Self.stepsSample(externalID: "app-1"), isAppWritten: true)
        mock.seed(Self.stepsSample(externalID: "app-2"), isAppWritten: true)
        // Simulates a sample some other app (or Apple Health natively) wrote:
        // no healthloom metadata, and -- crucially -- `isAppWritten: false`,
        // which is the only lever a test has to fake HKSource attribution
        // (see MockHealthStore.swift's header for why).
        mock.seed(Self.stepsSample(externalID: "not-ours", stampExternalID: false), isAppWritten: false)

        let report = try await writer.deleteAllAppData(types: [Self.stepsType])

        #expect(report.deletedCounts[Self.stepsType.identifier] == 2)
        #expect(report.total == 2)
        #expect(mock.sampleCount(ofType: Self.stepsType) == 1) // only the foreign sample survives
    }

    @Test func deleteAllAppDataReportsAnExplicitZeroForATypeWithNothingToDelete() async throws {
        let mock = MockHealthStore()
        let writer = HealthKitWriter(store: mock)

        let report = try await writer.deleteAllAppData(types: [Self.heartRateType])

        #expect(report.deletedCounts[Self.heartRateType.identifier] == 0)
        #expect(report.total == 0)
    }

    @Test func deleteAllAppDataSweepsEveryRequestedTypeIndependently() async throws {
        let mock = MockHealthStore()
        let writer = HealthKitWriter(store: mock)
        mock.seed(Self.stepsSample(externalID: "s1"), isAppWritten: true)
        mock.seed(Self.heartRateSample(externalID: "h1"), isAppWritten: true)

        let report = try await writer.deleteAllAppData(types: [Self.stepsType, Self.heartRateType])

        #expect(report.deletedCounts[Self.stepsType.identifier] == 1)
        #expect(report.deletedCounts[Self.heartRateType.identifier] == 1)
        #expect(report.total == 2)
    }

    // MARK: - Workouts (WP-12 replaced the stub with a real HKWorkoutBuilder
    // integration -- see WorkoutSavingTests.swift for saveWorkout(_:)'s own
    // orchestration/dedupe tests, mirroring this file's MockHealthStore-based
    // pattern but with MockWorkoutBuilder/MockWorkoutBuilderFactory.)

    // MARK: - Error propagation from the underlying store

    @Test func saveErrorFromTheStorePropagatesUnchanged() async throws {
        let mock = MockHealthStore()
        mock.saveError = .underlying("boom")
        let writer = HealthKitWriter(store: mock)

        do {
            try await writer.save([Self.stepsSample(externalID: "x")])
            Issue.record("Expected the mock's injected error to be thrown")
        } catch {
            #expect(error == .underlying("boom"))
        }
    }

    @Test func deleteObjectsErrorFromTheStorePropagatesUnchanged() async throws {
        let mock = MockHealthStore()
        mock.deleteObjectsError = .underlying("delete boom")
        let writer = HealthKitWriter(store: mock)

        do {
            _ = try await writer.delete(externalIDs: ["x"], type: Self.stepsType)
            Issue.record("Expected the mock's injected error to be thrown")
        } catch {
            #expect(error == .underlying("delete boom"))
        }
    }
}
#endif
