// ForegroundSync.swift
//
// WP-53: the manual Sync Now run, owned by `AppEnvironment` instead of the
// Data tab's `@State`. `HomeView` rebuilds a tab's stack whenever the tab
// changes, so a view-owned spinner reset to idle mid-run -- and since WP-52
// a first heart-rate sync runs for minutes. The Data tab looked finished
// while the engine kept going, and a second tap started a parallel pass.
// Owned here, the run survives view rebuilds, names the types in flight,
// and a second Sync Now while one runs does nothing.

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

    init(engine: SyncEngine) {
        self.syncType = { type in _ = await engine.sync(type: type) }
    }

    init(syncType: @escaping @MainActor (GoogleDataType) async -> Void) {
        self.syncType = syncType
    }

    /// Syncs `types`, a few at a time in order (`SyncSchedule`, WP-63).
    /// Returns `nil` without doing anything when a run is already under
    /// way; otherwise the run's task.
    @discardableResult
    func start(types: [GoogleDataType]) -> Task<Void, Never>? {
        guard !isRunning else { return nil }
        isRunning = true
        let syncType = syncType
        return Task {
            _ = await SyncSchedule.run(types, didStart: { @MainActor type in
                self.inFlight.append(type)
            }, didFinish: { @MainActor type in
                self.inFlight.removeAll { $0 == type }
            }, work: { type in
                await syncType(type)
            })
            inFlight = []
            isRunning = false
        }
    }
}
