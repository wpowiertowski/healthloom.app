// SyncEngineTests.swift
//
// WP-09 (implementation-plan.md) "Tests:" line, verbatim:
//   "idempotency (second run writes 0); pagination consumed fully; cursor
//   advances only on success; failure mid-window leaves cursor and is
//   retried; lookback window computed correctly (virtual clock);
//   late-arriving sample (older timestamp, new ID) inside lookback gets
//   written; concurrent sync(type:) calls coalesce."
// Plus this task's explicit additions: syncAll continues past one failing
// type and reports per-type results, and SyncState field verification
// (lastStatus/lastError/itemCount/lastSyncedAt).
//
// Every test uses: `MockGoogleReconcileClient` (this directory) instead of
// real networking, `MockHealthStore` (HealthKitWriter/MockHealthStore.swift,
// already built for WP-08) instead of a real `HKHealthStore`, an in-memory
// `CoreModel.makeContainer(inMemory: true)` instead of a real SwiftData
// store, and `TestSyncClock` (this directory) instead of wall-clock time --
// no test here touches the network, HealthKit entitlements, or real
// `Date()`.

#if canImport(HealthKit)
import CoreModel
import Foundation
import GoogleHealthClient
import HealthKit
import SwiftData
import Testing
@testable import SyncKit

@Suite struct SyncEngineTests {
    static let fixedNow = TypeMapperFixtures.date("2026-07-10T12:00:00Z")

    static let initialWindow: TimeInterval = 7 * 24 * 3600
    static let defaultLookback: TimeInterval = 72 * 3600
    static let sleepLookback: TimeInterval = 7 * 24 * 3600

    // MARK: - Test fixtures

    /// A `.localOnly`-writability point (architecture.md D2) -- any
    /// `GoogleDataType` whose `writability` is `.localOnly` maps
    /// unconditionally via `TypeMapper.decide`, regardless of `values`.
    static func ecgPoint(id: String, start: Date, end: Date) -> GoogleDataPoint {
        GoogleDataPoint(
            id: id,
            dataType: .electrocardiogram,
            start: start,
            end: end,
            source: DataSource(platform: "IOS", deviceDisplayName: "Apple Watch", recordingMethod: "AUTOMATICALLY_RECORDED"),
            values: [:]
        )
    }

    /// WP-14: same shape as `ecgPoint`, generalized to any `.localOnly`
    /// `GoogleDataType` (architecture.md D2 -- ECG, Active Zone Minutes,
    /// Active Minutes, Irregular Rhythm Notification) so the upsert-on-resync
    /// coverage below isn't ECG-only.
    static func localOnlyPoint(id: String, dataType: GoogleDataType, start: Date, end: Date) -> GoogleDataPoint {
        GoogleDataPoint(
            id: id,
            dataType: dataType,
            start: start,
            end: end,
            source: DataSource(platform: "IOS", deviceDisplayName: "Apple Watch", recordingMethod: "AUTOMATICALLY_RECORDED"),
            values: [:]
        )
    }

    static func syncState(_ container: ModelContainer, type: GoogleDataType) throws -> SyncState? {
        let context = ModelContext(container)
        let key = type.rawValue
        let descriptor = FetchDescriptor<SyncState>(predicate: #Predicate { $0.dataType == key })
        return try context.fetch(descriptor).first
    }

    static func allLocalSamples(_ container: ModelContainer) throws -> [LocalSample] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocalSample>())
    }

    // MARK: - Lookback window computed correctly (virtual clock)

    @Test func lookbackWindowIsSeventyTwoHoursForNonSleepTypesOnFirstSync() async throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let clock = TestSyncClock(Self.fixedNow)
        let mock = MockGoogleReconcileClient()
        mock.setPage(type: .steps, pageToken: nil, page: Page(points: [], nextPageToken: nil))
        let engine = SyncEngine(
            client: mock,
            writer: HealthKitWriter(store: MockHealthStore()),
            modelContainer: container,
            clock: clock
        )

        _ = await engine.sync(type: .steps)

        let call = try #require(mock.calls.first { $0.type == .steps })
        let expectedStart = Self.fixedNow.addingTimeInterval(-(Self.initialWindow + Self.defaultLookback))
        #expect(call.since == expectedStart)
        #expect(call.until == Self.fixedNow)
    }

    @Test func lookbackWindowIsSevenDaysForSleep() async throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let clock = TestSyncClock(Self.fixedNow)
        let mock = MockGoogleReconcileClient()
        mock.setPage(type: .sleep, pageToken: nil, page: Page(points: [], nextPageToken: nil))
        let engine = SyncEngine(
            client: mock,
            writer: HealthKitWriter(store: MockHealthStore()),
            modelContainer: container,
            clock: clock
        )

        _ = await engine.sync(type: .sleep)

        let call = try #require(mock.calls.first { $0.type == .sleep })
        let expectedStart = Self.fixedNow.addingTimeInterval(-(Self.initialWindow + Self.sleepLookback))
        #expect(call.since == expectedStart)
        #expect(call.until == Self.fixedNow)
    }

    @Test func secondSyncWindowIsAnchoredOnLastSyncedAtNotInitialWindow() async throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let clock = TestSyncClock(Self.fixedNow)
        let mock = MockGoogleReconcileClient()
        mock.setPage(type: .steps, pageToken: nil, page: Page(points: [], nextPageToken: nil))
        let store = MockHealthStore()
        let engine = SyncEngine(client: mock, writer: HealthKitWriter(store: store), modelContainer: container, clock: clock)

        _ = await engine.sync(type: .steps) // establishes lastSyncedAt == fixedNow

        let secondNow = Self.fixedNow.addingTimeInterval(3600) // one hour later
        clock.set(secondNow)
        _ = await engine.sync(type: .steps)

        let secondCall = try #require(mock.calls.last { $0.type == .steps })
        let expectedStart = Self.fixedNow.addingTimeInterval(-Self.defaultLookback) // anchored on lastSyncedAt, not (secondNow - initialWindow)
        #expect(secondCall.since == expectedStart)
        #expect(secondCall.until == secondNow)
    }

    // MARK: - Idempotency (second identical run writes 0 new HK objects)

    @Test func secondIdenticalRunWritesZeroNewHealthKitObjects() async throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let clock = TestSyncClock(Self.fixedNow)
        let mock = MockGoogleReconcileClient()
        // Timestamps close to `fixedNow` -- not `TypeMapperFixtures`' distant
        // default dates -- so they still fall inside the *second* run's
        // narrower window (anchored on `lastSyncedAt - 72h` once the first
        // run succeeds, rather than the wide first-ever-sync bootstrap
        // window). A real Google `reconcile` call for that narrower window
        // wouldn't re-return points outside it either -- this mock returning
        // the identical page both times is exactly the "identical run"
        // idempotency scenario the test's name promises.
        let pointStart = Self.fixedNow.addingTimeInterval(-3600)
        let pointEnd = Self.fixedNow.addingTimeInterval(-1800)
        let page = Page(
            points: [
                TypeMapperFixtures.stepsPoint(id: "idem-1", start: pointStart, end: pointEnd, count: 100),
                TypeMapperFixtures.stepsPoint(id: "idem-2", start: pointStart, end: pointEnd, count: 200),
            ],
            nextPageToken: nil
        )
        mock.setPage(type: .steps, pageToken: nil, page: page)
        let store = MockHealthStore()
        let engine = SyncEngine(client: mock, writer: HealthKitWriter(store: store), modelContainer: container, clock: clock)

        let first = await engine.sync(type: .steps)
        #expect(first.status == .ok)
        #expect(first.itemCount == 2)
        #expect(store.savedBatches.count == 1)
        #expect(store.savedBatches[0].count == 2)

        let second = await engine.sync(type: .steps)
        #expect(second.status == .ok)
        #expect(second.itemCount == 0) // both already present -> 0 newly written
        #expect(store.savedBatches.count == 1) // no new save call at all
    }

    // MARK: - .localOnly upsert (keyed on externalID, not duplicated on re-sync)

    @Test func localOnlyPointsUpsertIntoLocalSampleAndDoNotDuplicateOnResync() async throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let clock = TestSyncClock(Self.fixedNow)
        let mock = MockGoogleReconcileClient()
        let start = TypeMapperFixtures.date("2026-07-09T00:00:00Z")
        let end = TypeMapperFixtures.date("2026-07-09T00:00:30Z")
        let page = Page(points: [Self.ecgPoint(id: "ecg-1", start: start, end: end)], nextPageToken: nil)
        mock.setPage(type: .electrocardiogram, pageToken: nil, page: page)
        let engine = SyncEngine(
            client: mock,
            writer: HealthKitWriter(store: MockHealthStore()),
            modelContainer: container,
            clock: clock
        )

        let first = await engine.sync(type: .electrocardiogram)
        #expect(first.status == .ok)
        #expect(first.itemCount == 1)
        #expect(try Self.allLocalSamples(container).count == 1)

        let second = await engine.sync(type: .electrocardiogram)
        #expect(second.status == .ok)
        #expect(second.itemCount == 1) // every localOnly point counts on every run, even a re-upsert
        let samples = try Self.allLocalSamples(container)
        #expect(samples.count == 1) // upserted in place, not duplicated
        #expect(samples.first?.externalID == "ecg-1")
        #expect(samples.first?.dataType == GoogleDataType.electrocardiogram.rawValue)
    }

    /// WP-14 (implementation-plan.md) "Tests:" line: "upsert on re-sync (no
    /// dupes)" -- confirmed above for ECG alone (WP-09); this extends the
    /// same assertions to all four `.localOnly` types the WP-14 brief names
    /// (architecture.md D2): Active Zone Minutes, Active Minutes, and
    /// Irregular Rhythm Notification, in addition to ECG. `upsertLocalSample`
    /// has no per-`GoogleDataType` branching (SyncEngine.swift), so this is a
    /// belt-and-suspenders confirmation that genuinely nothing about a
    /// specific type's raw value trips up the fetch-by-`externalID` upsert
    /// path -- each type gets its own fresh container/engine so one type's
    /// run can't accidentally read another's `LocalSample` row.
    @Test func allFourLocalOnlyTypesUpsertIntoLocalSampleAndDoNotDuplicateOnResync() async throws {
        for dataType: GoogleDataType in [.electrocardiogram, .activeZoneMinutes, .activeMinutes, .irregularRhythmNotification] {
            let container = try CoreModel.makeContainer(inMemory: true)
            let clock = TestSyncClock(Self.fixedNow)
            let mock = MockGoogleReconcileClient()
            let start = TypeMapperFixtures.date("2026-07-09T00:00:00Z")
            let end = TypeMapperFixtures.date("2026-07-09T00:00:30Z")
            let point = Self.localOnlyPoint(id: "\(dataType.rawValue)-1", dataType: dataType, start: start, end: end)
            let page = Page(points: [point], nextPageToken: nil)
            mock.setPage(type: dataType, pageToken: nil, page: page)
            let engine = SyncEngine(
                client: mock,
                writer: HealthKitWriter(store: MockHealthStore()),
                modelContainer: container,
                clock: clock
            )

            let first = await engine.sync(type: dataType)
            #expect(first.status == .ok)
            #expect(first.itemCount == 1)
            #expect(try Self.allLocalSamples(container).count == 1)

            let second = await engine.sync(type: dataType)
            #expect(second.status == .ok)
            #expect(second.itemCount == 1) // every localOnly point counts on every run, even a re-upsert
            let samples = try Self.allLocalSamples(container)
            #expect(samples.count == 1) // upserted in place, not duplicated
            #expect(samples.first?.externalID == "\(dataType.rawValue)-1")
            #expect(samples.first?.dataType == dataType.rawValue)
        }
    }

    // MARK: - itemCount composition (new writes + localOnly upserts + skips)

    @Test func itemCountCountsNewWritesAndSkipsForAMixedPage() async throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let clock = TestSyncClock(Self.fixedNow)
        let mock = MockGoogleReconcileClient()
        let page = Page(
            points: [
                TypeMapperFixtures.stepsPoint(id: "mix-1", count: 50),
                TypeMapperFixtures.stepsPoint(id: "mix-2", count: 75),
                TypeMapperFixtures.stepsPoint(id: "mix-3", count: -5), // negative -> TypeMapper drops to .skip
            ],
            nextPageToken: nil
        )
        mock.setPage(type: .steps, pageToken: nil, page: page)
        let store = MockHealthStore()
        let engine = SyncEngine(client: mock, writer: HealthKitWriter(store: store), modelContainer: container, clock: clock)

        let outcome = await engine.sync(type: .steps)

        #expect(outcome.status == .ok)
        #expect(outcome.itemCount == 3) // 2 new writes + 1 skip
        #expect(store.savedBatches.first?.count == 2)
        let state = try #require(try Self.syncState(container, type: .steps))
        #expect(state.itemCount == 3)
    }

    // MARK: - Cursor advances only after full-window success

    @Test func cursorAdvancesOnlyOnFullWindowSuccessAndStaysPutOnFailure() async throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let clock = TestSyncClock(Self.fixedNow)
        let mock = MockGoogleReconcileClient()
        mock.setScript(
            type: .steps,
            pageToken: nil,
            results: [
                .success(Page(points: [TypeMapperFixtures.stepsPoint(id: "cursor-1")], nextPageToken: nil)),
                .failure(.server(status: 500)),
                .success(Page(points: [TypeMapperFixtures.stepsPoint(id: "cursor-2")], nextPageToken: nil)),
            ]
        )
        let engine = SyncEngine(
            client: mock,
            writer: HealthKitWriter(store: MockHealthStore()),
            modelContainer: container,
            clock: clock
        )

        let first = await engine.sync(type: .steps)
        #expect(first.status == .ok)
        var state = try #require(try Self.syncState(container, type: .steps))
        #expect(state.lastSyncedAt == Self.fixedNow)
        #expect(state.lastStatus == "ok")
        #expect(state.lastError == nil)

        let secondNow = Self.fixedNow.addingTimeInterval(3600)
        clock.set(secondNow)
        let second = await engine.sync(type: .steps)
        #expect(second.status == .error)
        #expect(second.errorMessage != nil)
        state = try #require(try Self.syncState(container, type: .steps))
        #expect(state.lastSyncedAt == Self.fixedNow) // untouched by the failed run
        #expect(state.lastStatus == "error")
        #expect(state.lastError != nil)

        let thirdNow = secondNow.addingTimeInterval(3600)
        clock.set(thirdNow)
        let third = await engine.sync(type: .steps)
        #expect(third.status == .ok)
        state = try #require(try Self.syncState(container, type: .steps))
        #expect(state.lastSyncedAt == thirdNow) // advances again once a run fully succeeds
        #expect(state.lastStatus == "ok")
        #expect(state.lastError == nil)
    }

    // WP-38 degradation matrix, offline leg (third-party F8): no HTTP
    // response at all (airplane mode, dead zone) surfaces as
    // .transport, reports a per-type error, moves no cursor, writes
    // nothing, and leaves the persisted message redacted-safe.
    @Test func offlineTransportReportsErrorWithoutMovingCursorOrWriting() async throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let clock = TestSyncClock(Self.fixedNow)
        let mock = MockGoogleReconcileClient()
        mock.setScript(type: .steps, pageToken: nil, results: [.failure(.transport("URLError"))])
        let store = MockHealthStore()
        let engine = SyncEngine(
            client: mock,
            writer: HealthKitWriter(store: store),
            modelContainer: container,
            clock: clock
        )

        let result = await engine.sync(type: .steps)
        #expect(result.status == .error)
        #expect(result.errorMessage != nil)
        let state = try #require(try Self.syncState(container, type: .steps))
        #expect(state.lastStatus == "error")
        #expect(state.lastSyncedAt == nil)
        #expect(state.lastError != nil)
        #expect(store.savedBatches.isEmpty)
    }

    @Test func persistedErrorMessagesAreRedactedBeforeTheyReachTheStore() async throws {
        // D11: a pipeline error embedding a bearer token must reach
        // SyncState.lastError (and the outcome) only as [REDACTED].
        let container = try CoreModel.makeContainer(inMemory: true)
        let mock = MockGoogleReconcileClient()
        mock.setScript(type: .steps, pageToken: nil, results: [
            .failure(.transport("request failed, header Bearer ya29.TESTSECRET12345")),
        ])
        let engine = SyncEngine(
            client: mock,
            writer: HealthKitWriter(store: MockHealthStore()),
            modelContainer: container,
            clock: TestSyncClock(Self.fixedNow)
        )
        let outcome = await engine.sync(type: .steps)
        #expect(outcome.status == .error)
        let message = try #require(outcome.errorMessage)
        #expect(message.contains(SyncLogRedactor.redactedMarker))
        #expect(!message.contains("ya29.TESTSECRET12345"))
        let state = try #require(try Self.syncState(container, type: .steps))
        #expect(state.lastError == message)
        #expect(!state.lastError!.contains("ya29.TESTSECRET12345"))
    }

    @Test func cancellationReportsStoppedNotFailed() async throws {
        // A mid-backoff cancel (expiration handler) surfaces `.cancelled`
        // with no error row -- the dashboard must not redden for the system
        // doing its job -- and the cursor stays for the next run to retry.
        let container = try CoreModel.makeContainer(inMemory: true)
        let mock = MockGoogleReconcileClient()
        mock.setScript(type: .steps, pageToken: nil, results: [
            .failure(.cancelled),
        ])
        let engine = SyncEngine(
            client: mock,
            writer: HealthKitWriter(store: MockHealthStore()),
            modelContainer: container,
            clock: TestSyncClock(Self.fixedNow)
        )
        let outcome = await engine.sync(type: .steps)
        #expect(outcome.status == .cancelled)
        #expect(outcome.errorMessage == nil)
        let state = try #require(try Self.syncState(container, type: .steps))
        #expect(state.lastStatus == SyncStatus.cancelled.rawValue)
        #expect(state.lastError == nil)
        #expect(state.lastSyncedAt == nil)
    }

    // MARK: - All pages of a paginated response are consumed

    @Test func allPagesOfAPaginatedResponseAreConsumed() async throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let clock = TestSyncClock(Self.fixedNow)
        let mock = MockGoogleReconcileClient()
        mock.setPage(
            type: .steps,
            pageToken: nil,
            page: Page(
                points: [TypeMapperFixtures.stepsPoint(id: "page1-a"), TypeMapperFixtures.stepsPoint(id: "page1-b")],
                nextPageToken: "p2"
            )
        )
        mock.setPage(
            type: .steps,
            pageToken: "p2",
            page: Page(points: [TypeMapperFixtures.stepsPoint(id: "page2-a")], nextPageToken: nil)
        )
        let store = MockHealthStore()
        let engine = SyncEngine(client: mock, writer: HealthKitWriter(store: store), modelContainer: container, clock: clock)

        let outcome = await engine.sync(type: .steps)

        #expect(outcome.status == .ok)
        #expect(outcome.itemCount == 3)
        #expect(mock.callCount(type: .steps, pageToken: nil) == 1)
        #expect(mock.callCount(type: .steps, pageToken: "p2") == 1)
        // Both page fetches used the identical window (Page.swift's "stable
        // window" invariant -- since/until is the request window, the page
        // token continues within it).
        let calls = mock.calls.filter { $0.type == .steps }
        #expect(calls.count == 2)
        #expect(calls[0].since == calls[1].since)
        #expect(calls[0].until == calls[1].until)
        #expect(store.savedBatches.reduce(0) { $0 + $1.count } == 3)
    }

    // MARK: - Failure mid-pagination leaves cursor untouched; retried next run

    @Test func failureMidPaginationLeavesCursorUntouchedAndIsSafelyRetried() async throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let clock = TestSyncClock(Self.fixedNow)
        let mock = MockGoogleReconcileClient()
        mock.setPage(
            type: .steps,
            pageToken: nil,
            page: Page(points: [TypeMapperFixtures.stepsPoint(id: "mp-1")], nextPageToken: "p2")
        )
        mock.setScript(
            type: .steps,
            pageToken: "p2",
            results: [
                .failure(.server(status: 500)),
                .success(Page(points: [TypeMapperFixtures.stepsPoint(id: "mp-2")], nextPageToken: nil)),
            ]
        )
        let store = MockHealthStore()
        let engine = SyncEngine(client: mock, writer: HealthKitWriter(store: store), modelContainer: container, clock: clock)

        // Run 1: page 1 succeeds and is written; page 2 fails -> whole run errors.
        let first = await engine.sync(type: .steps)
        #expect(first.status == .error)
        #expect(first.itemCount == 1) // page 1's point was processed before the failure (informational)
        var state = try #require(try Self.syncState(container, type: .steps))
        #expect(state.lastSyncedAt == nil) // never advanced -- this was the type's first-ever run
        #expect(store.sampleCount(ofType: HKObjectType.quantityType(forIdentifier: .stepCount)!) == 1) // page 1's write already persisted (idempotent, safe)

        // Run 2 (clock unchanged -> identical window recomputed from the
        // still-nil cursor): page 1 is safely re-pulled (already-written
        // point costs 0 new writes), page 2 succeeds this time.
        let second = await engine.sync(type: .steps)
        #expect(second.status == .ok)
        state = try #require(try Self.syncState(container, type: .steps))
        #expect(state.lastSyncedAt == Self.fixedNow)

        let pageNilCalls = mock.calls.filter { $0.type == .steps && $0.pageToken == nil }
        #expect(pageNilCalls.count == 2)
        #expect(pageNilCalls[0].since == pageNilCalls[1].since)
        #expect(pageNilCalls[0].until == pageNilCalls[1].until)

        #expect(store.sampleCount(ofType: HKObjectType.quantityType(forIdentifier: .stepCount)!) == 2) // mp-1 (unchanged) + mp-2 (newly written)
    }

    // MARK: - Late-arriving sample (old timestamp, new externalID) inside lookback gets written

    @Test func lateArrivingSampleInsideLookbackWindowGetsWritten() async throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let clock = TestSyncClock(Self.fixedNow)
        let mock = MockGoogleReconcileClient()
        mock.setScript(
            type: .steps,
            pageToken: nil,
            results: [
                .success(Page(points: [TypeMapperFixtures.stepsPoint(id: "on-time")], nextPageToken: nil)),
            ]
        )
        let store = MockHealthStore()
        let engine = SyncEngine(client: mock, writer: HealthKitWriter(store: store), modelContainer: container, clock: clock)

        _ = await engine.sync(type: .steps) // lastSyncedAt becomes fixedNow

        // A day later, the device finally syncs a sample whose *own*
        // timestamp is well before `fixedNow` (a late-arriving Fitbit sync,
        // architecture.md D3) but whose externalID has never been seen.
        // Since the next run's window is anchored on `lastSyncedAt -
        // lookback` (72h), and this point's timestamp is only ~10h before
        // `fixedNow`, it falls inside that lookback window.
        let secondNow = Self.fixedNow.addingTimeInterval(24 * 3600)
        clock.set(secondNow)
        let lateTimestamp = Self.fixedNow.addingTimeInterval(-10 * 3600)
        mock.setScript(
            type: .steps,
            pageToken: nil,
            results: [
                .success(Page(points: [TypeMapperFixtures.stepsPoint(id: "on-time")], nextPageToken: nil)), // consumed by run 1
                .success(
                    Page(
                        points: [
                            TypeMapperFixtures.stepsPoint(id: "late-arrival", start: lateTimestamp, end: lateTimestamp.addingTimeInterval(60)),
                        ],
                        nextPageToken: nil
                    )
                ),
            ]
        )

        let call = try #require(mock.calls.first { $0.type == .steps })
        _ = call // window's `since` for run 2 will be asserted below

        let second = await engine.sync(type: .steps)
        #expect(second.status == .ok)
        #expect(second.itemCount == 1)

        let secondCall = try #require(mock.calls.last { $0.type == .steps && $0.pageToken == nil })
        #expect(secondCall.since <= lateTimestamp) // the window genuinely covers the late timestamp
        #expect(store.sampleCount(ofType: HKObjectType.quantityType(forIdentifier: .stepCount)!) == 2) // on-time + late-arrival
        let ids = try await HealthKitWriter(store: store).existingExternalIDs(
            type: HKObjectType.quantityType(forIdentifier: .stepCount)!,
            start: TypeMapperFixtures.date("2000-01-01T00:00:00Z"),
            end: TypeMapperFixtures.date("2100-01-01T00:00:00Z")
        )
        #expect(ids.contains("late-arrival"))
    }

    // MARK: - Concurrent sync(type:) calls for the same type coalesce

    @Test func concurrentSyncCallsForTheSameTypeCoalesceIntoOneExecution() async throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let clock = TestSyncClock(Self.fixedNow)
        let mock = MockGoogleReconcileClient()
        let gate = AsyncGate()
        mock.gate = gate
        mock.setPage(
            type: .steps,
            pageToken: nil,
            page: Page(points: [TypeMapperFixtures.stepsPoint(id: "coalesce-1")], nextPageToken: nil)
        )
        let engine = SyncEngine(
            client: mock,
            writer: HealthKitWriter(store: MockHealthStore()),
            modelContainer: container,
            clock: clock
        )

        let t1 = Task { await engine.sync(type: .steps) }
        // Guaranteed: by the time this returns, `reconcile` has been entered,
        // which can only happen after `sync(type:)`'s synchronous prefix
        // (check `inFlight`, create+store the child `Task`) already ran --
        // so `inFlight[.steps]` is populated for the entire remainder of
        // this test, until the gate is opened below.
        await gate.waitUntilEntered()

        let t2 = Task { await engine.sync(type: .steps) }
        let t3 = Task { await engine.sync(type: .steps) }
        // Give the (currently idle -- t1 is parked on the gate) actor a
        // chance to run t2/t3's entry and observe the in-flight task before
        // we let t1 proceed.
        await Task.yield()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))

        await gate.open()

        let r1 = await t1.value
        let r2 = await t2.value
        let r3 = await t3.value

        #expect(r1 == r2)
        #expect(r2 == r3)
        #expect(mock.calls.count == 1) // the pipeline ran exactly once
    }

    // MARK: - syncAll continues past one failing type and reports per-type results

    @Test func syncAllRunsSequentiallyContinuesPastFailureAndReportsPerTypeResults() async throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let clock = TestSyncClock(Self.fixedNow)
        let mock = MockGoogleReconcileClient()
        mock.setPage(type: .steps, pageToken: nil, page: Page(points: [TypeMapperFixtures.stepsPoint(id: "all-steps")], nextPageToken: nil))
        mock.setScript(type: .heartRate, pageToken: nil, results: [.failure(.rateLimited)])
        mock.setPage(type: .weight, pageToken: nil, page: Page(points: [TypeMapperFixtures.weightPoint(id: "all-weight")], nextPageToken: nil))
        let engine = SyncEngine(
            client: mock,
            writer: HealthKitWriter(store: MockHealthStore()),
            modelContainer: container,
            clock: clock
        )

        let results = await engine.syncAll(types: [.steps, .heartRate, .weight])

        #expect(results.count == 3)
        #expect(results[0].dataType == .steps)
        #expect(results[0].status == .ok)
        #expect(results[1].dataType == .heartRate)
        #expect(results[1].status == .error)
        #expect(results[2].dataType == .weight)
        #expect(results[2].status == .ok) // continues past the failing type

        // Sequential, not concurrent: exactly one call per type, in order.
        #expect(mock.calls.map(\.type) == [.steps, .heartRate, .weight])
    }

    // MARK: - ConflictFiltering hook: identity by default, overridable

    @Test func identityConflictFilterPassesMappingThroughUnchanged() async throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let clock = TestSyncClock(Self.fixedNow)
        let mock = MockGoogleReconcileClient()
        mock.setPage(type: .steps, pageToken: nil, page: Page(points: [TypeMapperFixtures.stepsPoint(id: "filt-1")], nextPageToken: nil))
        let store = MockHealthStore()
        let engine = SyncEngine(
            client: mock,
            writer: HealthKitWriter(store: store),
            modelContainer: container,
            clock: clock,
            conflictFilter: IdentityConflictFilter()
        )

        let outcome = await engine.sync(type: .steps)

        #expect(outcome.status == .ok)
        #expect(outcome.itemCount == 1)
        #expect(store.savedBatches.first?.count == 1)
    }

    /// A conflict filter that always suppresses -- downgrades every
    /// `.quantity`/`.category` mapping to `.localOnly` -- to prove the seam
    /// is genuinely wired between mapping and the existence-diff/write step
    /// (this is exactly what WP-12b's real resolver will do for samples
    /// inside a watch coverage window, architecture.md D13.3).
    private struct SuppressingConflictFilter: ConflictFiltering {
        // Explicit drains (no protocol defaults to inherit): this double
        // records nothing, so both are honest no-ops.
        func drainDeferredSessionLinks(for type: GoogleDataType) async -> [String: UUID] { [:] }
        func drainSuppressedCount(for type: GoogleDataType) async -> Int { 0 }

        func resolve(_ mapped: MappedObject, for point: GoogleDataPoint) async -> MappedObject {
            switch mapped {
            case .quantity, .category:
                return .localOnly
            case .workout, .correlation, .quantities, .localOnly, .skip:
                // WP-12 added `.workout`; WP-13 added `.correlation`; WP-12b
                // added `.quantities` (split cumulative samples). This test
                // predates all three and isn't about them, so it passes them
                // through unchanged, same as `.localOnly`/`.skip`.
                return mapped
            }
        }
    }

    @Test func customConflictFilterCanSuppressWritesBeforeTheExistenceDiff() async throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let clock = TestSyncClock(Self.fixedNow)
        let mock = MockGoogleReconcileClient()
        mock.setPage(type: .steps, pageToken: nil, page: Page(points: [TypeMapperFixtures.stepsPoint(id: "suppressed-1")], nextPageToken: nil))
        let store = MockHealthStore()
        let engine = SyncEngine(
            client: mock,
            writer: HealthKitWriter(store: store),
            modelContainer: container,
            clock: clock,
            conflictFilter: SuppressingConflictFilter()
        )

        let outcome = await engine.sync(type: .steps)

        #expect(outcome.status == .ok)
        #expect(store.savedBatches.isEmpty) // suppressed before the write step
        #expect(try Self.allLocalSamples(container).count == 1) // routed to LocalSample instead
    }
}
#endif
