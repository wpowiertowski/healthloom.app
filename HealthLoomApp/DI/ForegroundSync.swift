// ForegroundSync.swift
//
// WP-53: the manual Sync Now run, owned by `AppEnvironment` instead of the
// Data tab's `@State`. `HomeView` rebuilds a tab's stack whenever the tab
// changes, so a view-owned spinner reset to idle mid-run -- and since WP-52
// a first heart-rate sync runs for minutes. The Data tab looked finished
// while the engine kept going, and a second tap started a parallel pass.
// Owned here, the run survives view rebuilds, names the types in flight,
// and a second Sync Now while one runs does nothing.
//
// WP-71: a run holds background time, so leaving the app mid-sync no
// longer cuts off the types in flight. If iOS's time runs out anyway, the
// run is cancelled (the engine records it as cancelled, not failed) and
// no further type starts.

import CoreModel
import Observation
import SyncKit

@Observable
@MainActor
final class ForegroundSync {
    /// The types syncing right now, in the order they started (WP-63: a
    /// few run at once); empty when idle.
    private(set) var inFlight: [GoogleDataType] = []
    private(set) var isRunning = false

    /// Syncs one type. The engine in production; tests pass a recorder.
    @ObservationIgnored private let syncType: @MainActor (GoogleDataType) async -> Void
    /// The background-time assertion. UIKit in production; tests record.
    @ObservationIgnored private let backgroundTime: BackgroundTime
    @ObservationIgnored private var run: Task<Void, Never>?

    init(engine: SyncEngine) {
        self.syncType = { type in _ = await engine.sync(type: type) }
        self.backgroundTime = .system
    }

    init(backgroundTime: BackgroundTime, syncType: @escaping @MainActor (GoogleDataType) async -> Void) {
        self.syncType = syncType
        self.backgroundTime = backgroundTime
    }

    /// Syncs `types`, a few at a time in order (`SyncSchedule`, WP-63).
    /// Returns `nil` without doing anything when a run is already under
    /// way; otherwise the run's task.
    @discardableResult
    func start(types: [GoogleDataType]) -> Task<Void, Never>? {
        guard !isRunning else { return nil }
        isRunning = true
        let syncType = syncType
        let endBackgroundTime = backgroundTime.begin("sync-now") { [weak self] in
            self?.run?.cancel()
        }
        let task = Task {
            // Once cancelled (out of background time), start nothing more.
            _ = await SyncSchedule.run(types, shouldStart: {
                !Task.isCancelled
            }, didStart: { @MainActor type in
                self.inFlight.append(type)
            }, didFinish: { @MainActor type in
                self.inFlight.removeAll { $0 == type }
            }, work: { type in
                await syncType(type)
            })
            inFlight = []
            isRunning = false
            run = nil
            endBackgroundTime()
        }
        run = task
        return task
    }
}
