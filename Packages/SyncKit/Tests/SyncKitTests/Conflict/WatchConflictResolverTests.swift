// WatchConflictResolverTests.swift
//
// WP-12b (implementation-plan.md) "Tests:" line + test-plan.md §2.3, the
// impure half (WatchCoverageIndexTests.swift covers the pure truth table):
// `WatchConflictResolver` installed in a real `SyncEngine`'s conflict-filter
// seam, driven end-to-end with `MockGoogleReconcileClient` +
// `MockHealthStore` + `MockWorkoutBuilderFactory` + `TestSyncClock` +
// injected coverage windows (the simulator cannot fake an Apple Watch
// source -- `StubWatchCoverageProvider` below is exactly the injection
// point test-plan.md §2.3 prescribes). Covers: session deferral with the
// LocalSample link, stream suppression + cumulative split pro-rating
// through the pipeline, retroactive cleanup (samples and workouts,
// including idempotency), toggle-OFF identity, coverage-read-failure
// degradation, Fitbit-only workout import + dedupe, and the suppressed
// count reaching the sync log.

#if canImport(HealthKit)
import CoreModel
import Foundation
import GoogleHealthClient
import HealthKit
import SwiftData
import Testing
@testable import SyncKit

// MARK: - Injection stubs

/// Same `@unchecked Sendable` + `nonisolated(unsafe)` shape as
/// `MockGoogleReconcileClient` (SyncEngine/MockGoogleReconcileClient.swift),
/// for the same strict-conformance-isolation reasons.
final class StubWatchCoverageProvider: WatchCoverageProviding, @unchecked Sendable {
    struct StubError: Error {}

    nonisolated(unsafe) var windows: [WatchCoverageWindow] = []
    nonisolated(unsafe) var shouldThrow = false
    nonisolated(unsafe) private(set) var callCount = 0

    init() {}

    nonisolated func watchWorkoutWindows(start: Date, end: Date) async throws -> [WatchCoverageWindow] {
        callCount += 1
        if shouldThrow { throw StubError() }
        return windows
    }
}

nonisolated struct StubWatchPriorityPreference: WatchPriorityPreferenceReading {
    var enabled: Bool
    nonisolated func isWatchPriorityEnabled() -> Bool { enabled }
}

@Suite struct WatchConflictResolverTests {
    /// Same virtual "now" as `SyncEngineTests` -- the first-sync window
    /// (initialWindow 7 d + lookback 72 h) then reaches back to
    /// 2026-06-30T12:00:00Z, comfortably containing every 2026-07-09
    /// scenario timestamp below.
    static let fixedNow = TypeMapperFixtures.date("2026-07-10T12:00:00Z")

    static func at(_ time: String) -> Date { TypeMapperFixtures.date("2026-07-09T\(time)Z") }

    static let watchWorkoutUUID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    /// One watch workout 10:00-10:40 -- the scenario every defer/suppress
    /// test below is framed around. Padded coverage: 09:55-10:45.
    static func morningRunWindow() -> WatchCoverageWindow {
        WatchCoverageWindow(workoutUUID: watchWorkoutUUID, start: at("10:00:00"), end: at("10:40:00"))
    }

    struct Harness {
        let container: ModelContainer
        let clock: TestSyncClock
        let mock: MockGoogleReconcileClient
        let store: MockHealthStore
        let builderFactory: MockWorkoutBuilderFactory
        let coverage: StubWatchCoverageProvider
        let engine: SyncEngine
    }

    static func makeHarness(
        windows: [WatchCoverageWindow],
        preferenceEnabled: Bool = true,
        coverageThrows: Bool = false,
        runRecorder: (any SyncRunRecording)? = nil
    ) throws -> Harness {
        let container = try CoreModel.makeContainer(inMemory: true)
        let clock = TestSyncClock(fixedNow)
        let mock = MockGoogleReconcileClient()
        let store = MockHealthStore()
        let builderFactory = MockWorkoutBuilderFactory()
        let writer = HealthKitWriter(store: store, workoutBuilderFactory: builderFactory)
        let coverage = StubWatchCoverageProvider()
        coverage.windows = windows
        coverage.shouldThrow = coverageThrows
        let resolver = WatchConflictResolver(
            coverageProvider: coverage,
            writer: writer,
            preference: StubWatchPriorityPreference(enabled: preferenceEnabled)
        )
        let engine = SyncEngine(
            client: mock,
            writer: writer,
            modelContainer: container,
            clock: clock,
            conflictFilter: resolver,
            runRecorder: runRecorder
        )
        return Harness(
            container: container, clock: clock, mock: mock, store: store,
            builderFactory: builderFactory, coverage: coverage, engine: engine
        )
    }

    static func localSamples(_ container: ModelContainer) throws -> [LocalSample] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocalSample>())
    }

    // MARK: - Session deferral (D13.2)

    @Test func overlappingExerciseSessionDefersToLocalSampleWithWatchLink() async throws {
        let harness = try Self.makeHarness(windows: [Self.morningRunWindow()])
        // Fitbit auto-detected the same run, slightly offset: 10:02-10:43.
        let point = TypeMapperFixtures.exercisePoint(
            id: "fitbit-run-1", start: Self.at("10:02:00"), end: Self.at("10:43:00")
        )
        harness.mock.setPage(type: .exercise, pageToken: nil, page: Page(points: [point], nextPageToken: nil))

        let outcome = await harness.engine.sync(type: .exercise)

        #expect(outcome.status == .ok)
        #expect(outcome.suppressedCount == 1)
        #expect(outcome.itemCount == 1) // counted as a localOnly upsert
        // Never reached the workout builder -- D13.2's "must never reach
        // saveWorkout at all".
        #expect(harness.builderFactory.requestedActivityTypes.isEmpty)

        let samples = try Self.localSamples(harness.container)
        #expect(samples.count == 1)
        #expect(samples.first?.externalID == "fitbit-run-1")
        #expect(samples.first?.dataType == GoogleDataType.exercise.rawValue)
        #expect(samples.first?.linkedWatchWorkoutUUID == Self.watchWorkoutUUID)
    }

    @available(*, deprecated, message: "constructs a test-only fake HKWorkout via a deprecated initializer, see MockWorkoutBuilder.swift")
    @Test func fitbitOnlyWorkoutWithNoCoverageImportsFullyAndDedupes() async throws {
        let harness = try Self.makeHarness(windows: []) // watch-off day
        let point = TypeMapperFixtures.exercisePoint(
            id: "fitbit-solo-1", start: Self.at("07:00:00"), end: Self.at("07:45:00")
        )
        harness.mock.setPage(type: .exercise, pageToken: nil, page: Page(points: [point], nextPageToken: nil))
        // Make the finished workout land in the mock store (the real
        // builder's finishWorkout saves to the store itself) so run 2's
        // existence diff can find it -- see MockWorkoutBuilder.swift.
        harness.builderFactory.builder.storeToSeedOnFinish = harness.store
        seedFinishResult(harness, point: point)

        let first = await harness.engine.sync(type: .exercise)
        #expect(first.status == .ok)
        #expect(first.itemCount == 1)
        #expect(first.suppressedCount == 0)
        #expect(harness.builderFactory.requestedActivityTypes.count == 1)
        #expect(try Self.localSamples(harness.container).isEmpty)

        harness.clock.set(Self.fixedNow.addingTimeInterval(3600))
        let second = await harness.engine.sync(type: .exercise)
        #expect(second.status == .ok)
        #expect(second.itemCount == 0) // already present -- dedupe by external ID
        #expect(harness.builderFactory.requestedActivityTypes.count == 1) // builder not touched again
    }

    /// The deprecated `HKWorkout` initializer is test-fixture-only -- see
    /// MockWorkoutBuilder.swift's `makeFakeHKWorkoutForTesting` doc comment
    /// for why the annotation silences the -warnings-as-errors diagnostic.
    @available(*, deprecated, message: "uses the test-only deprecated HKWorkout fixture initializer")
    private func seedFinishResult(_ harness: Harness, point: GoogleDataPoint) {
        harness.builderFactory.builder.finishResult = makeFakeHKWorkoutForTesting(
            activityType: .running,
            start: point.start,
            end: point.end,
            metadata: [
                HKMetadataKeyExternalUUID: point.id,
                "healthloom.externalID": point.id,
            ]
        )
    }

    // MARK: - Stream suppression + split (D13.3)

    @Test func heartRateInsideCoverageIsSuppressedAndCounted() async throws {
        let harness = try Self.makeHarness(windows: [Self.morningRunWindow()])
        let point = TypeMapperFixtures.heartRatePoint(
            id: "hr-covered-1", start: Self.at("10:15:00"), end: Self.at("10:15:00"), bpm: 152
        )
        harness.mock.setPage(type: .heartRate, pageToken: nil, page: Page(points: [point], nextPageToken: nil))

        let outcome = await harness.engine.sync(type: .heartRate)

        #expect(outcome.status == .ok)
        #expect(outcome.suppressedCount == 1)
        #expect(outcome.itemCount == 1) // suppressed -> .skip, still one processed point
        #expect(harness.store.savedBatches.isEmpty)
    }

    @Test func stepsOutsideCoverageImportUntouched() async throws {
        let harness = try Self.makeHarness(windows: [Self.morningRunWindow()])
        let point = TypeMapperFixtures.stepsPoint(
            id: "steps-baseline-1", start: Self.at("06:00:00"), end: Self.at("07:00:00"), count: 700
        )
        harness.mock.setPage(type: .steps, pageToken: nil, page: Page(points: [point], nextPageToken: nil))

        let outcome = await harness.engine.sync(type: .steps)

        #expect(outcome.status == .ok)
        #expect(outcome.suppressedCount == 0)
        #expect(harness.store.savedBatches.first?.count == 1)
    }

    @Test func cumulativeStepsStraddlingCoverageAreSplitWithProRatedValue() async throws {
        // Coverage padded span: 09:55-10:45. Steps interval 09:00-10:00
        // (600 steps) overlaps it from 09:55 ⇒ kept slice 09:00-09:55
        // (55/60 of the hour) with 550 steps.
        let harness = try Self.makeHarness(windows: [Self.morningRunWindow()])
        let point = TypeMapperFixtures.stepsPoint(
            id: "steps-straddle-1", start: Self.at("09:00:00"), end: Self.at("10:00:00"), count: 600
        )
        harness.mock.setPage(type: .steps, pageToken: nil, page: Page(points: [point], nextPageToken: nil))

        let outcome = await harness.engine.sync(type: .steps)

        #expect(outcome.status == .ok)
        #expect(outcome.suppressedCount == 1) // partially deferred counts
        #expect(outcome.itemCount == 1) // one point, however many part samples
        let batch = try #require(harness.store.savedBatches.first)
        let sample = try #require(batch.first as? HKQuantitySample)
        #expect(batch.count == 1)
        #expect(sample.startDate == Self.at("09:00:00"))
        #expect(sample.endDate == Self.at("09:55:00"))
        #expect(abs(sample.quantity.doubleValue(for: .count()) - 550) < 0.0001)
        // The split part keeps the original point's external-ID stamp (D4).
        #expect(sample.metadata?[HKMetadataKeyExternalUUID] as? String == "steps-straddle-1")
    }

    @Test func instantaneousHeartRateIntervalStraddlingCoverageIsDroppedWhole() async throws {
        // HR interval sample 09:50-10:05 crosses the padded edge (09:55) --
        // instantaneous types are dropped at edges, never split.
        let harness = try Self.makeHarness(windows: [Self.morningRunWindow()])
        let point = TypeMapperFixtures.heartRatePoint(
            id: "hr-straddle-1", start: Self.at("09:50:00"), end: Self.at("10:05:00"), bpm: 120
        )
        harness.mock.setPage(type: .heartRate, pageToken: nil, page: Page(points: [point], nextPageToken: nil))

        let outcome = await harness.engine.sync(type: .heartRate)

        #expect(outcome.suppressedCount == 1)
        #expect(harness.store.savedBatches.isEmpty)
    }

    @Test func nonCoveredTypesPassThroughEvenInsideCoverage() async throws {
        // Weight measured mid-workout: weight is not a watch-covered stream
        // type (D13.3 names exactly four) -- imports untouched.
        let harness = try Self.makeHarness(windows: [Self.morningRunWindow()])
        let point = TypeMapperFixtures.weightPoint(
            id: "weight-mid-run", start: Self.at("10:10:00"), end: Self.at("10:10:00")
        )
        harness.mock.setPage(type: .weight, pageToken: nil, page: Page(points: [point], nextPageToken: nil))

        let outcome = await harness.engine.sync(type: .weight)

        #expect(outcome.suppressedCount == 0)
        #expect(harness.store.savedBatches.first?.count == 1)
    }

    // MARK: - Retroactive cleanup (D13.4)

    @Test func lateArrivingWatchWorkoutTriggersCleanupOfConflictingSamplesAndIsIdempotent() async throws {
        // Run 1: no coverage yet (watch away from phone) -- Fitbit steps
        // inside the future workout window import normally.
        let harness = try Self.makeHarness(windows: [])
        let point = TypeMapperFixtures.stepsPoint(
            id: "steps-conflict-1", start: Self.at("10:05:00"), end: Self.at("10:20:00"), count: 900
        )
        harness.mock.setPage(type: .steps, pageToken: nil, page: Page(points: [point], nextPageToken: nil))
        let stepsType = HKObjectType.quantityType(forIdentifier: .stepCount)!

        let first = await harness.engine.sync(type: .steps)
        #expect(first.status == .ok)
        #expect(harness.store.sampleCount(ofType: stepsType) == 1)

        // Run 2: the watch workout has now landed in HealthKit; the same
        // lookback window is re-pulled (cursor moved only 1 h). Cleanup must
        // delete the now-conflicting written sample, and the re-pulled point
        // must be suppressed, not re-written.
        harness.coverage.windows = [Self.morningRunWindow()]
        harness.clock.set(Self.fixedNow.addingTimeInterval(3600))
        let second = await harness.engine.sync(type: .steps)

        #expect(second.status == .ok)
        #expect(second.suppressedCount == 1)
        #expect(harness.store.sampleCount(ofType: stepsType) == 0)
        #expect(harness.store.deleteObjectsCalls.count == 1)
        #expect(harness.store.deleteObjectsCalls.first?.externalIDs == ["steps-conflict-1"])

        // Run 3: nothing left to clean -- cleanup is idempotent (no further
        // delete call), and the point stays suppressed.
        harness.clock.set(Self.fixedNow.addingTimeInterval(2 * 3600))
        let third = await harness.engine.sync(type: .steps)
        #expect(third.status == .ok)
        #expect(harness.store.deleteObjectsCalls.count == 1)
        #expect(harness.store.sampleCount(ofType: stepsType) == 0)
    }

    @available(*, deprecated, message: "constructs a test-only fake HKWorkout via a deprecated initializer, see MockWorkoutBuilder.swift")
    @Test func lateArrivingWatchWorkoutTriggersCleanupOfConflictingImportedWorkout() async throws {
        // Run 1: Fitbit session imported as a real HKWorkout (no coverage).
        let harness = try Self.makeHarness(windows: [])
        let point = TypeMapperFixtures.exercisePoint(
            id: "fitbit-run-2", start: Self.at("10:02:00"), end: Self.at("10:43:00")
        )
        harness.mock.setPage(type: .exercise, pageToken: nil, page: Page(points: [point], nextPageToken: nil))
        harness.builderFactory.builder.storeToSeedOnFinish = harness.store
        seedFinishResult(harness, point: point)

        let first = await harness.engine.sync(type: .exercise)
        #expect(first.status == .ok)
        #expect(harness.store.sampleCount(ofType: .workoutType()) == 1)

        // Run 2: watch workout lands -> imported workout now conflicts ->
        // deleted, and the re-pulled session defers to LocalSample with the
        // watch link (the reversed-order variant of the deferral test).
        harness.coverage.windows = [Self.morningRunWindow()]
        harness.clock.set(Self.fixedNow.addingTimeInterval(3600))
        let second = await harness.engine.sync(type: .exercise)

        #expect(second.status == .ok)
        #expect(second.suppressedCount == 1)
        #expect(harness.store.sampleCount(ofType: .workoutType()) == 0)
        let samples = try Self.localSamples(harness.container)
        #expect(samples.count == 1)
        #expect(samples.first?.linkedWatchWorkoutUUID == Self.watchWorkoutUUID)
        // The sweep also covered the workout's attached distance/energy
        // sample types (same external ID -- see the resolver's cleanup).
        let sweptTypes = Set(harness.store.deleteObjectsCalls.map(\.objectType.identifier))
        #expect(sweptTypes.contains(HKObjectType.workoutType().identifier))
        #expect(sweptTypes.contains(HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue))
        #expect(sweptTypes.contains(HKQuantityTypeIdentifier.activeEnergyBurned.rawValue))
    }

    // MARK: - Toggle OFF (D13.5) + degradation

    @Test func preferenceOffMakesResolverIdentityEvenWithCoverage() async throws {
        let harness = try Self.makeHarness(windows: [Self.morningRunWindow()], preferenceEnabled: false)
        let steps = TypeMapperFixtures.stepsPoint(
            id: "steps-off-1", start: Self.at("10:05:00"), end: Self.at("10:20:00"), count: 500
        )
        harness.mock.setPage(type: .steps, pageToken: nil, page: Page(points: [steps], nextPageToken: nil))

        let outcome = await harness.engine.sync(type: .steps)

        #expect(outcome.status == .ok)
        #expect(outcome.suppressedCount == 0)
        #expect(harness.store.savedBatches.first?.count == 1)
        #expect(harness.coverage.callCount == 0) // OFF short-circuits before any coverage read
        #expect(harness.store.deleteObjectsCalls.isEmpty) // and before any cleanup
    }

    @Test func coverageReadFailureDegradesToIdentityInsteadOfFailingTheRun() async throws {
        // e.g. HealthKit read authorization not granted yet (onboarding's
        // first sync) -- the run must succeed and import normally; the next
        // readable run's retroactive cleanup self-corrects (D13.4).
        let harness = try Self.makeHarness(windows: [Self.morningRunWindow()], coverageThrows: true)
        let steps = TypeMapperFixtures.stepsPoint(
            id: "steps-degrade-1", start: Self.at("10:05:00"), end: Self.at("10:20:00"), count: 500
        )
        harness.mock.setPage(type: .steps, pageToken: nil, page: Page(points: [steps], nextPageToken: nil))

        let outcome = await harness.engine.sync(type: .steps)

        #expect(outcome.status == .ok)
        #expect(outcome.suppressedCount == 0)
        #expect(harness.store.savedBatches.first?.count == 1)
    }

    // MARK: - Bookkeeping reaches the sync log (test-plan.md §2.3)

    @Test func suppressedCountReachesTheSyncLogEntryAndExport() async throws {
        let logStore = SyncLogStore(persistence: NullSyncLogPersistence())
        let recorder = SyncEngineLogRecorder(store: logStore, clock: TestSyncClock(Self.fixedNow))
        let harness = try Self.makeHarness(windows: [Self.morningRunWindow()], runRecorder: recorder)
        let point = TypeMapperFixtures.heartRatePoint(
            id: "hr-logged-1", start: Self.at("10:15:00"), end: Self.at("10:15:00"), bpm: 149
        )
        harness.mock.setPage(type: .heartRate, pageToken: nil, page: Page(points: [point], nextPageToken: nil))

        _ = await harness.engine.sync(type: .heartRate)

        let entry = try #require(await logStore.recentEntries().first)
        #expect(entry.suppressedCount == 1)
        let export = SyncLogTextExporter.export([entry], generatedAt: Self.fixedNow)
        #expect(export.contains("1 deferred to Apple Watch"))
    }

    // MARK: - Concurrent types share one resolver without sharing runs

    @Test func secondTypeBeginRunDoesNotWipeFirstTypesInFlightRun() async throws {
        // Two types syncing concurrently on one pipeline: the second
        // type's beginRun must not reset the first's coverage index (the
        // pre-fix shared slot set activeIndex = nil mid-run, so every
        // remaining steps point resolved with no coverage and double-wrote
        // watch-covered data).
        let coverage = StubWatchCoverageProvider()
        coverage.windows = [Self.morningRunWindow()]
        let writer = HealthKitWriter(
            store: MockHealthStore(), workoutBuilderFactory: MockWorkoutBuilderFactory())
        let resolver = WatchConflictResolver(coverageProvider: coverage, writer: writer)
        let windowStart = Self.at("09:00:00")
        let windowEnd = Self.at("11:00:00")

        try await resolver.beginRun(type: .steps, windowStart: windowStart, windowEnd: windowEnd)
        // The interleaving SyncEngine's awaits allow: heartRate's run
        // starts while steps is still in flight.
        try await resolver.beginRun(type: .heartRate, windowStart: windowStart, windowEnd: windowEnd)

        // A steps point fully inside padded coverage (09:55-10:45) still
        // suppresses -- identity resolution here would mean the index died.
        let point = TypeMapperFixtures.stepsPoint(
            id: "steps-covered-1", start: Self.at("10:05:00"), end: Self.at("10:10:00"))
        let resolved = await resolver.resolve(TypeMapper.map(point), for: point)
        guard case .skip = resolved else {
            Issue.record("expected a suppressed (skipped) point, got \(resolved)")
            return
        }
        #expect(await resolver.drainSuppressedCount(for: .steps) == 1)
        #expect(await resolver.drainSuppressedCount(for: .heartRate) == 0)
    }
}
#endif
