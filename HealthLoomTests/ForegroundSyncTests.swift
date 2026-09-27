// ForegroundSyncTests.swift
//
// WP-53: the manual Sync Now run owned by `AppEnvironment`. The syncType
// closure stands in for `SyncEngine.sync(type:)` (the network + HealthKit
// boundary) and records what the run looked like while each type synced.

import CoreModel
import Testing
@testable import HealthLoom

@MainActor
@Suite struct ForegroundSyncTests {
    /// Records each call and what the run reported at that moment.
    @MainActor
    final class Recorder {
        var synced: [GoogleDataType] = []
        var currentDuringSync: [GoogleDataType?] = []
        var runningDuringSync: [Bool] = []
        var secondStartWasRefused: Bool?
    }

    // catches: the run reporting idle (or naming the wrong type) while a
    // type is still syncing -- the Data tab's spinner went idle mid-run and
    // looked finished -- and staying "running" after the last type.
    @Test func reportsTheTypeInFlightAndEndsIdle() async throws {
        let recorder = Recorder()
        var foreground: ForegroundSync?
        foreground = ForegroundSync { type in
            recorder.synced.append(type)
            recorder.currentDuringSync.append(foreground?.current)
            recorder.runningDuringSync.append(foreground?.isRunning ?? false)
        }
        let sync = try #require(foreground)

        let task = try #require(sync.start(types: [.steps, .heartRate]))
        await task.value

        #expect(recorder.synced == [.steps, .heartRate])
        #expect(recorder.currentDuringSync == [.steps, .heartRate])
        #expect(recorder.runningDuringSync == [true, true])
        #expect(sync.current == nil)
        #expect(!sync.isRunning)
    }

    // catches: a second Sync Now while one runs starting a parallel pass
    // (the view-owned flag was lost on every tab switch, so the button
    // re-enabled mid-run).
    @Test func aSecondStartWhileRunningDoesNothing() async throws {
        let recorder = Recorder()
        var foreground: ForegroundSync?
        foreground = ForegroundSync { type in
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
}
