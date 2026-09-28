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
        var inFlightDuringSync: [GoogleDataType: [GoogleDataType]] = [:]
        var runningDuringSync: [Bool] = []
        var secondStartWasRefused: Bool?
    }

    // catches: the run reporting idle (or leaving out a type) while that
    // type is still syncing -- the Data tab's spinner went idle mid-run and
    // looked finished -- and staying "running" after the last type. Types
    // overlap since WP-63, so each must be named while it syncs.
    @Test func reportsTheTypesInFlightAndEndsIdle() async throws {
        let recorder = Recorder()
        var foreground: ForegroundSync?
        foreground = ForegroundSync { type in
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
