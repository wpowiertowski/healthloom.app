// CloudSyncChangeMonitor.swift
//
// WP-49 (architecture.md D17): tells `CloudSyncEngine` when app-owned data
// changed locally, so a change reaches iCloud within seconds instead of at
// the next foreground sync. Structural rather than per-caller: it watches
// where the synced data lives -- `UserDefaults` (sync settings, insight
// preferences) and SwiftData saves that touch `ChatTurn` -- so a new toggle
// or a new writer is covered without remembering to call anything.
//
// Thin adapter over two notifications; the decisions (did the synced
// fields really change? is a sync already running? debounce) live in the
// engine and are tested there. Never installed under `-UITest*`
// (HealthLoomApp), the same rule the launch sync follows, so UI tests
// never touch CloudKit.

import CoreModel
import Foundation
import SwiftData
import UIKit

@MainActor
final class CloudSyncChangeMonitor {
    private let engine: CloudSyncEngine
    private var observers: [NSObjectProtocol] = []

    /// `ChatTurn`'s entity name, the only model whose saves matter here.
    private nonisolated static let turnEntityName = String(describing: ChatTurn.self)

    init(engine: CloudSyncEngine) {
        self.engine = engine
    }

    /// Idempotent: the app calls it on every activation.
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // Fires for every defaults write in the process, the engine's own
        // watermarks included; the engine compares the synced fields
        // before requesting anything.
        observers.append(center.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.noteLocalPreferencesChange() }
        })
        // Cheap check first: most saves are Google sync writing samples
        // and cursors. Only a save that touched a `ChatTurn` asks the
        // engine to count turns.
        observers.append(center.addObserver(
            forName: ModelContext.didSave, object: nil, queue: .main
        ) { [weak self] note in
            guard Self.touchesTurns(note.userInfo) else { return }
            MainActor.assumeIsolated { self?.engine.noteLocalTurnsChange() }
        })
    }

    /// Whether a `ModelContext.didSave` payload inserted, updated or
    /// deleted a `ChatTurn`. Pure over the notification payload.
    nonisolated static func touchesTurns(_ userInfo: [AnyHashable: Any]?) -> Bool {
        guard let userInfo else { return false }
        let keys: [ModelContext.NotificationKey] = [.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
        return keys.contains { key in
            let ids = userInfo[key.rawValue] as? [PersistentIdentifier] ?? []
            return ids.contains { $0.entityName == turnEntityName }
        }
    }
}

/// Runs a waiting change-triggered sync when the app goes to the
/// background, holding a background-task assertion so iOS gives it time
/// to finish. Thin UIKit adapter; the sync itself is the engine's.
@MainActor
enum CloudSyncBackgroundFlush {
    static func run(_ engine: CloudSyncEngine) {
        let token = BackgroundTaskToken()
        token.id = UIApplication.shared.beginBackgroundTask(withName: "cloud-sync-flush") {
            // Out of time: end the assertion; the change stays local and
            // syncs at the next activation.
            MainActor.assumeIsolated { token.end() }
        }
        Task {
            await engine.flushPendingSync()
            token.end()
        }
    }
}

/// Holds the assertion's identifier so both the expiration handler and
/// the completion can end it exactly once.
@MainActor
private final class BackgroundTaskToken {
    var id: UIBackgroundTaskIdentifier = .invalid

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
