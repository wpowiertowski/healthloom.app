// CoreModel.swift
// CoreModel
//
// Package-level namespace: the `ModelContainer` factory (implementation-plan.md WP-02
// step 4). CoreModel is persistence + shared value types only — no I/O beyond opening
// the SwiftData store, and never a HealthKit import (architecture.md §2).

import Foundation
import SwiftData

/// Namespace for CoreModel's `ModelContainer` factory and the canonical model list.
public enum CoreModel {
    /// Every SwiftData model CoreModel defines, gathered in one place so the container
    /// schema and the "round-trips every model" test (WP-02 "Done when") can't
    /// silently drift apart as models are added.
    public static let modelTypes: [any PersistentModel.Type] = [
        SyncState.self,
        LocalSample.self,
        KnowledgeProfile.self,
        DerivedInsight.self,
        PromptVersion.self,
        ChatTurn.self,
        ContextSnapshot.self,
    ]

    /// Builds the app's `ModelContainer`.
    ///
    /// - Parameter inMemory: `true` for tests/previews — nothing touches disk, no file
    ///   protection to apply. `false` opens (creating if needed) the on-disk store
    ///   under Application Support/HealthLoom, with `NSFileProtectionComplete` applied
    ///   to the store file (architecture.md D11 — the store holds `LocalSample`
    ///   clinical events and chat history, nothing more sensitive belongs in it per D2).
    public static func makeContainer(inMemory: Bool) throws -> ModelContainer {
        let schema = Schema(modelTypes)

        let configuration: ModelConfiguration
        let onDiskURL: URL?
        // Explicit `.none`: `cloudKitDatabase` defaults to `.automatic`,
        // which silently promotes every container to CloudKit sync the
        // moment the app gains the iCloud capability — breaking the store
        // outright (CloudKit requires all-optional attributes) AND
        // violating this app's sync scope (settings/insight-prefs/coach
        // history ONLY, via the hand-built `CloudSyncEngine` — HealthKit-
        // sourced entities must never leave the device). Local-only store
        // here; CloudKit traffic goes exclusively through that engine.
        if inMemory {
            configuration = ModelConfiguration(
                schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none
            )
            onDiskURL = nil
        } else {
            let storeURL = try productionStoreURL()
            configuration = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
            onDiskURL = storeURL
        }

        let container = try ModelContainer(for: schema, configurations: [configuration])

        if let onDiskURL {
            try applyCompleteFileProtection(at: onDiskURL)
        }

        return container
    }

    /// On-disk store location. Public for WP-35's `StoreDeleter` only —
    /// the single source both the container factory and the wipe delete
    /// through, so the wipe can never miss the live store's files.
    public static func productionStoreURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appending(path: "HealthLoom", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "CoreModel.store", directoryHint: .notDirectory)
    }

    /// Applies `NSFileProtectionComplete` (architecture.md D11) to the on-disk store.
    ///
    /// Data Protection classes are an iOS concept enforced by the Secure Enclave/
    /// passcode-derived keys. This package's tests also run natively on macOS (per
    /// WP-01's environment note, Xcode 26.4.1 / Swift 6.3.1 host), where the OS has no
    /// such protection classes to enforce — `FileProtectionType` exists in the SDK
    /// there, but setting it is a documented no-op, not a real guarantee. Guarding to
    /// iOS keeps this call honest about what it actually does per platform, per the
    /// WP-02 spec's own note that this API "may be a no-op or unavailable" on macOS.
    private static func applyCompleteFileProtection(at url: URL) throws {
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        #endif
    }
}

/// Retained from WP-01: `SyncKit`, `CoachKit`, and `GoogleHealthClient`'s WP-01
/// placeholder sources reference `CoreModelPlaceholder.moduleName` at compile time to
/// prove their dependency wiring on CoreModel. WP-02's scope is CoreModel only (its own
/// handoff-protocol constraints say not to touch other packages), so this stays until
/// whichever later WP replaces those placeholders removes the reference too.
public enum CoreModelPlaceholder {
    public static let moduleName = "CoreModel"
}
