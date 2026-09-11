// StoreProtectionTests.swift
//
// Round-6 items 3, 12, 13: the store/data-protection trio.
// - Item 3: an on-disk open failure falls back LOUDLY (ephemeral +
//   flagged), never silently discarding the session.
// - Item 12: the store-file protection DECISION is pinned (named
//   constant — enforcement is iOS-only, unobservable on macOS and,
//   empirically, the simulator; devices enforce).
// - Item 13: staged exports carry Complete in their write options
//   (pinned), and staging sweeps stale copies first (observed).

import CoreModel
import Foundation
import SwiftData
import Testing
@testable import HealthLoom

@Suite("Store fallback and staged-export protection")
@MainActor
struct StoreProtectionTests {
    struct OpenBoom: Error {}

    @Test("store open failure falls back ephemeral and flagged")
    func openFailureIsLoud() throws {
        // Round-6 item 3: a throwing on-disk opener must NEVER surface
        // as a quiet healthy store — the tuple reports ephemeral, and
        // the flag is what the UI banners. (The opener succeeds for
        // in-memory — only the on-disk path fails here.)
        let (container, ephemeral) = try AppEnvironment.openModelContainer(
            useInMemory: false,
            opener: { inMemory in
                guard inMemory else { throw OpenBoom() }
                return try CoreModel.makeContainer(inMemory: true)
            }
        )
        #expect(ephemeral)
        // The fallback container is usable (launch survives)…
        _ = ModelContext(container)
        // …while the happy path reports non-ephemeral.
        let (_, clean) = try AppEnvironment.openModelContainer(
            useInMemory: true,
            opener: { inMemory in try CoreModel.makeContainer(inMemory: inMemory) }
        )
        #expect(!clean)
    }

    @Test("total failure propagates (nothing can run)")
    func totalFailurePropagates() {
        // Both opens throw: the error propagates to the call site,
        // which traps (a dead store cannot launch — verified by
        // review of the init path; this pins the propagation).
        #expect(throws: OpenBoom.self) {
            try AppEnvironment.openModelContainer(useInMemory: false, opener: { _ in throw OpenBoom() })
        }
    }

    @Test("staged export options carry Complete protection")
    func stagedWriteOptionsProtected() {
        // Round-6 item 13: pins the DECISION (see the item-12 note
        // above on why the class itself is unobservable off-device).
        #expect(ExportBuilder.stagedWriteOptions.contains(.completeFileProtection))
        #expect(ExportBuilder.stagedWriteOptions.contains(.atomic))
    }

    @Test("staging sweeps stale copies and writes content")
    func stagingSweepsAndWrites() throws {
        // The OBSERVABLE half of item 13 (runs everywhere): a stale
        // staged file is gone after staging, and the staged bytes are
        // exactly the encoded payload.
        let stale = FileManager.default.temporaryDirectory.appending(
            path: "healthloom-export-stale.json",
            directoryHint: .notDirectory
        )
        try Data("stale".utf8).write(to: stale, options: .atomic)
        let payload = Data("payload".utf8)
        let url = try ExportBuilder.stageForSharing(payload)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(try Data(contentsOf: url) == payload)
    }

    @Test("dismissal sweep empties the staged inventory")
    func dismissalSweepEmptiesInventory() throws {
        // Round-10 item 15: the staged file must not survive past
        // dismissal — the view sweeps on disappear + re-prepare via
        // `deleteExportFiles`. Stage, sweep, prove the inventory empty.
        let url = try ExportBuilder.stageForSharing(Data("payload".utf8))
        #expect(FileManager.default.fileExists(atPath: url.path))
        _ = try StoreDeleter.deleteExportFiles()
        let remaining = try FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("healthloom-export-") && $0.pathExtension == "json"
        }
        #expect(remaining.isEmpty)
    }
}
