// ForegroundSyncTests.swift
//
// WP-53: the manual Sync Now run owned by `AppEnvironment`. The syncType
// closure stands in for `SyncEngine.sync(type:)` (the network + HealthKit
// boundary) and records what the run looked like while each type synced.
// WP-71: `BackgroundTime` stands in for UIKit's background-task assertion.

import CoreModel
import Foundation
import SyncKit
import Testing
@testable import HealthLoom

@MainActor
@Suite struct ForegroundSyncTests {
    /// Records each call and what the run reported at that moment.
    @MainActor
    final class Recorder {
        var synced: [GoogleDataType] = []
        var inFlightDuringSync: [GoogleDataType: [GoogleDataType]] = [:]
        var runningDuringSync: [Bool] = []
        var secondStartWasRefused: Bool?
        var backgroundTimeBegun = 0
        var backgroundTimeEnded = 0
        var backgroundTimeEndedDuringSync: [Int] = []
        var expire: (@MainActor @Sendable () -> Void)?
        var sawCancellation = false

        /// Records the assertion's lifetime; `expire` plays iOS running
        /// out of background time.
        var backgroundTime: BackgroundTime {
            BackgroundTime { _, expired in
                self.backgroundTimeBegun += 1
                self.expire = expired
                return { self.backgroundTimeEnded += 1 }
            }
        }
    }

    // catches: the run reporting idle (or leaving out a type) while that
    // type is still syncing -- the Data tab's spinner went idle mid-run and
    // looked finished -- and staying "running" after the last type. Types
    // overlap since WP-63, so each must be named while it syncs.
    @Test func reportsTheTypesInFlightAndEndsIdle() async throws {
        let recorder = Recorder()
        var foreground: ForegroundSync?
        foreground = ForegroundSync(backgroundTime: recorder.backgroundTime) { type in
            recorder.synced.append(type)
            recorder.inFlightDuringSync[type] = foreground?.inFlight ?? []
            recorder.runningDuringSync.append(foreground?.isRunning ?? false)
        }
        let sync = try #require(foreground)

        let task = try #require(sync.start(types: [.steps, .heartRate]))
        await task.value

        #expect(Set(recorder.synced) == [.steps, .heartRate])
        #expect(recorder.inFlightDuringSync[.steps]?.contains(.steps) == true)
        #expect(recorder.inFlightDuringSync[.heartRate]?.contains(.heartRate) == true)
        #expect(recorder.runningDuringSync == [true, true])
        #expect(sync.inFlight.isEmpty)
        #expect(!sync.isRunning)
    }

    // catches: the progress line naming one type while three sync.
    @Test func theProgressLineNamesEveryTypeInFlight() throws {
        #expect(DashboardView.syncProgressText([]) == nil)
        let text = try #require(DashboardView.syncProgressText([.steps, .sleep, .weight]))
        #expect(text.contains(GoogleDataType.steps.displayName))
        #expect(text.contains(GoogleDataType.sleep.displayName))
        #expect(text.contains(GoogleDataType.weight.displayName))
    }

    // catches: a second Sync Now while one runs starting a parallel pass
    // (the view-owned flag was lost on every tab switch, so the button
    // re-enabled mid-run).
    @Test func aSecondStartWhileRunningDoesNothing() async throws {
        let recorder = Recorder()
        var foreground: ForegroundSync?
        foreground = ForegroundSync(backgroundTime: recorder.backgroundTime) { type in
            recorder.synced.append(type)
            if recorder.secondStartWasRefused == nil {
                recorder.secondStartWasRefused = foreground?.start(types: [.weight]) == nil
            }
        }
        let sync = try #require(foreground)

        let task = try #require(sync.start(types: [.steps]))
        await task.value

        #expect(recorder.secondStartWasRefused == true)
        #expect(recorder.synced == [.steps])
        // Idle again: the next tap runs.
        let next = try #require(sync.start(types: [.weight]))
        await next.value
        #expect(recorder.synced == [.steps, .weight])
    }

    // catches: a Sync Now run without background time (leaving the app
    // cut off the types in flight), and the assertion never ended -- or
    // ended before the last type finished.
    @Test func holdsBackgroundTimeForTheWholeRun() async throws {
        let recorder = Recorder()
        let sync = ForegroundSync(backgroundTime: recorder.backgroundTime) { _ in
            recorder.backgroundTimeEndedDuringSync.append(recorder.backgroundTimeEnded)
        }

        let task = try #require(sync.start(types: [.steps, .heartRate]))
        #expect(recorder.backgroundTimeBegun == 1)
        await task.value

        #expect(recorder.backgroundTimeEndedDuringSync == [0, 0])
        #expect(recorder.backgroundTimeEnded == 1)
    }

    // catches: running out of background time leaving the run going (iOS
    // kills an app that overstays), or starting further types after it.
    @Test func runningOutOfBackgroundTimeCancelsTheRun() async throws {
        let recorder = Recorder()
        let sync = ForegroundSync(backgroundTime: recorder.backgroundTime) { type in
            recorder.synced.append(type)
            // The first type to run expires the time, before any finishes.
            if let expire = recorder.expire {
                recorder.expire = nil
                expire()
                recorder.sawCancellation = Task.isCancelled
            }
        }
        let types: [GoogleDataType] = [.steps, .heartRate, .weight, .sleep, .distance]

        let task = try #require(sync.start(types: types))
        await task.value

        #expect(recorder.sawCancellation)
        #expect(recorder.synced.count <= SyncSchedule.maxConcurrentTypes)
        #expect(!sync.isRunning)
        #expect(sync.inFlight.isEmpty)
    }

    // catches (WP-74, review): the Data tab's trends and in-app rows
    // refreshing only on Sync Now -- a background sync or backfill landing
    // new rows (a new type's last sync, a backfill step, more items) left
    // them stale -- and state no sync writes forcing reloads.
    @Test func theDataTabRefreshesWheneverASyncLandsData() {
        let date = Date(timeIntervalSince1970: 1_790_500_000)
        func key(_ states: [SyncState], syncing: Bool = false) -> DashboardView.RefreshKey {
            DashboardView.refreshKey(states, isSyncing: syncing)
        }
        let base = key([SyncState(dataType: "activeMinutes", lastSyncedAt: date, itemCount: 10)])
        #expect(key([SyncState(dataType: "activeMinutes", lastSyncedAt: date, itemCount: 10)]) == base)
        #expect(key([SyncState(dataType: "activeMinutes", lastSyncedAt: date.addingTimeInterval(60), itemCount: 10)]) != base)
        #expect(key([SyncState(dataType: "activeMinutes", lastSyncedAt: date, backfillCursor: date, itemCount: 10)]) != base)
        #expect(key([SyncState(dataType: "activeMinutes", lastSyncedAt: date, itemCount: 11)]) != base)
        #expect(key([SyncState(dataType: "activeMinutes", lastSyncedAt: date, itemCount: 10)], syncing: true) != base)
        #expect(key([SyncState(dataType: "activeMinutes", lastSyncedAt: date, lastError: "x", itemCount: 10)]) == base)
    }
}
