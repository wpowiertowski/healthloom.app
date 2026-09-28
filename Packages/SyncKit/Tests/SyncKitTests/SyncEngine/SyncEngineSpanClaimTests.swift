// SyncEngineSpanClaimTests.swift
//
// WP-58: what a multi-span run writes when spans overlap, how the backfill
// claim serializes the two pipelines per type, cancellation reaching the
// run, and the one-time duplicate repair.

#if canImport(HealthKit)
import CoreModel
import Foundation
import GoogleHealthClient
import HealthKit
import SwiftData
import Testing
@testable import SyncKit

@Suite struct SyncEngineSpanClaimTests {
    static let fixedNow = TypeMapperFixtures.date("2026-07-10T12:00:00Z")

    static func engine(_ mock: MockGoogleReconcileClient, store: MockHealthStore) throws -> SyncEngine {
        SyncEngine(
            client: mock,
            writer: HealthKitWriter(store: store),
            modelContainer: try CoreModel.makeContainer(inMemory: true),
            clock: TestSyncClock(fixedNow)
        )
    }

    /// A point 30 h before now: inside one of the first sync's 24 h spans,
    /// and inside the next span's leading overlap.
    static func middleSpanPage(id: String) -> Page {
        let start = fixedNow.addingTimeInterval(-30 * 3600)
        return Page(
            points: [TypeMapperFixtures.stepsPoint(id: id, start: start, end: start.addingTimeInterval(1800), count: 100)],
            nextPageToken: nil
        )
    }

    // catches: every span diffing against the run's opening existence
    // snapshot -- a day returned by two consecutive spans (the `.date`
    // filter's civil-day truncation) written twice, as daily resting heart
    // rate was on every multi-day run since WP-52.
    @Test func aPointReturnedByTwoSpansIsWrittenOnce() async throws {
        let mock = MockGoogleReconcileClient()
        mock.leadingOverlap = 24 * 3600
        mock.setPage(type: .steps, pageToken: nil, page: Self.middleSpanPage(id: "day-1"))
        let store = MockHealthStore()
        let engine = try Self.engine(mock, store: store)

        let outcome = await engine.sync(type: .steps)

        #expect(outcome.status == .ok)
        #expect(mock.calls.count > 1, "a multi-span run")
        #expect(store.sampleCount(ofType: HKQuantityType(.stepCount)) == 1)
        #expect(outcome.itemCount == 1)
    }

    // catches: the backfill check-then-run race -- a claim granted while an
    // incremental run of the type is in flight lets both write its window.
    @Test func aClaimIsRefusedWhileAnIncrementalRunIsInFlight() async throws {
        let mock = MockGoogleReconcileClient()
        let gate = AsyncGate()
        mock.gate = gate
        let engine = try Self.engine(mock, store: MockHealthStore())

        let run = Task { await engine.sync(type: .steps) }
        await gate.waitUntilEntered()
        #expect(await engine.claimForBackfill(.steps) == false)
        #expect(await engine.claimForBackfill(.heartRate), "other types stay claimable")
        await gate.open()
        _ = await run.value
        #expect(await engine.claimForBackfill(.steps), "claimable once the run ends")
    }

    // catches: an incremental run starting mid-chunk -- sync(type:) must
    // wait out the claim, then run (not skip) once it's released.
    @Test func aSyncWaitsForTheBackfillClaimThenRuns() async throws {
        let mock = MockGoogleReconcileClient()
        mock.setPage(type: .steps, pageToken: nil, page: Self.middleSpanPage(id: "after-claim"))
        let store = MockHealthStore()
        let engine = try Self.engine(mock, store: store)
        #expect(await engine.claimForBackfill(.steps))

        let run = Task { await engine.sync(type: .steps) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(mock.calls.isEmpty, "nothing pulled while the backfill holds the type")

        await engine.releaseBackfillClaim(.steps)
        let outcome = await run.value
        #expect(outcome.status == .ok)
        #expect(store.sampleCount(ofType: HKQuantityType(.stepCount)) == 1)
    }

    // catches: a waiter stranded on the claim past its caller's
    // cancellation (the background expiry would then hang until the chunk
    // ends).
    @Test func aCancelledWaiterStopsWithoutRunning() async throws {
        let mock = MockGoogleReconcileClient()
        let engine = try Self.engine(mock, store: MockHealthStore())
        #expect(await engine.claimForBackfill(.steps))

        let run = Task { await engine.sync(type: .steps) }
        try await Task.sleep(for: .milliseconds(50))
        run.cancel()
        let outcome = await run.value

        #expect(outcome.status == .cancelled)
        #expect(mock.calls.isEmpty)
        await engine.releaseBackfillClaim(.steps)
    }

    // catches: the run living in an unstructured task cancellation never
    // reaches -- an expired background sync kept walking every span.
    @Test func cancellingTheCallerStopsTheRunAtTheNextSpan() async throws {
        let mock = MockGoogleReconcileClient()
        let gate = AsyncGate()
        mock.gate = gate
        let engine = try Self.engine(mock, store: MockHealthStore())

        let run = Task { await engine.sync(type: .steps) }
        await gate.waitUntilEntered()
        run.cancel()
        await gate.open()
        let outcome = await run.value

        #expect(outcome.status == .cancelled)
        #expect(mock.calls.count == 1, "the first span's page finished; no later span started")
    }

    // catches: the repair deleting every copy (data loss) or keeping the
    // duplicates, or touching another app's samples.
    @Test func theRepairKeepsOneCopyPerExternalID() async throws {
        let store = MockHealthStore()
        let type = HKQuantityType(.restingHeartRate)
        func sample(_ id: String) -> HKQuantitySample {
            HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: 52),
                start: Self.fixedNow,
                end: Self.fixedNow.addingTimeInterval(86_400),
                metadata: [HKMetadataKeyExternalUUID: id]
            )
        }
        store.seed(sample("day-1"), isAppWritten: true)
        store.seed(sample("day-1"), isAppWritten: true)
        store.seed(sample("day-2"), isAppWritten: true)
        store.seed(sample("day-2"), isAppWritten: false)
        let engine = try Self.engine(MockGoogleReconcileClient(), store: store)

        let removed = try await engine.removeDuplicateWrites(of: .dailyRestingHeartRate)

        #expect(removed == 1)
        #expect(store.sampleCount(ofType: type) == 3)
        #expect(try await engine.removeDuplicateWrites(of: .dailyRestingHeartRate) == 0)
    }
}
#endif
