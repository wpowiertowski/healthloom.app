// StoreDeleter.swift
//
// WP-35: deletes the on-disk SwiftData store. SQLite keeps `-wal`/`-shm`
// sidecars next to `CoreModel.store` — all three go, or the next launch
// resurrects half a database. Missing files are success (idempotent:
// wipe-twice is a no-op, and a fresh install has nothing to delete).
// The store URL stays CoreModel's single source (`productionStoreURL`,
// widened to public for this one caller — recomputing the path here
// would let the two drift apart).

import CoreModel
import Foundation

enum StoreDeleter {
    /// Every file the wipe must remove for the store step (round-6
    /// item 6): the main store, EVERY SQLite sidecar the store can
    /// run under (`-wal`/`-shm` in WAL mode, `-journal` in rollback
    /// mode — CoreModel's own comment says either is possible, so the
    /// old list's missing `-journal` left newest rows behind), plus
    /// `SyncLog.json` (SyncKit's on-disk sync log lives in this same
    /// directory — health-adjacent history that must not survive a
    /// "cannot be undone" wipe; owned explicitly here since no other
    /// wipe step covers it).
    static func storeFileURLs() throws -> [URL] {
        let main = try CoreModel.productionStoreURL()
        return [
            main,
            URL(fileURLWithPath: main.path + "-wal"),
            URL(fileURLWithPath: main.path + "-shm"),
            URL(fileURLWithPath: main.path + "-journal"),
            main.deletingLastPathComponent().appending(path: "SyncLog.json", directoryHint: .notDirectory),
        ]
    }

    /// Files in `directory` NOT covered by `inventory` (round-7 fix
    /// N1): the enumeration cross-check — a future file type (new
    /// sidecar, new log) fails LOUDLY here instead of escaping the
    /// wipe. Pure over paths (no deletes), so tests drive it with
    /// temp dirs.
    static func uncoveredFiles(in directory: URL, coveredBy inventory: [URL]) throws -> [String] {
        let actual = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        let covered = Set(inventory.map(\.lastPathComponent))
        return actual.subtracting(covered).sorted()
    }

    /// Files the wipe cannot explain (round-7 fix N1): a future file
    /// in the store directory must fail the step LOUDLY (ledger +
    /// retry) rather than survive a "cannot be undone" wipe in
    /// silence. Never thrown for explicit-subset deletes (tests and
    /// sweeps pass their own lists) — only the full-inventory
    /// production path trips it.
    struct UnknownWipeFiles: Error, CustomStringConvertible {
        var names: [String]
        var description: String {
            let listed = names.prefix(3).joined(separator: ", ")
            let more = names.count > 3 ? " and \(names.count - 3) more" : ""
            return "App data holds unrecognized files (\(listed)\(more)) — they were left in place, nothing skipped silently. Update the app and run again."
        }
    }

    /// Removes existing store files. Returns the removed URLs (for the
    /// ledger); throws on the first removal failure.
    @discardableResult
    static func deleteStoreFiles(in directoryURLs: [URL]? = nil) throws -> [URL] {
        let urls = try directoryURLs ?? storeFileURLs()
        var removed: [URL] = []
        for url in urls {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
                removed.append(url)
            }
        }
        if directoryURLs == nil {
            // Full-inventory production path only: enumerate the live
            // store directory and fail loudly on anything left behind
            // (see `uncoveredFiles`). Explicit-subset callers (tests,
            // export sweep) manage their own scope — flagging their
            // siblings would be noise, not signal.
            let storeDir = try CoreModel.productionStoreURL().deletingLastPathComponent()
            let remaining = try uncoveredFiles(in: storeDir, coveredBy: urls)
            if !remaining.isEmpty {
                throw UnknownWipeFiles(names: remaining)
            }
        }
        return removed
    }

    /// Removes staged export files (`healthloom-export-*.json`, F3): a
    /// complete health-data JSON must not survive a wipe in sandbox tmp,
    /// and re-exports must not accumulate. Prefix-scoped so unrelated tmp
    /// files are never touched.
    @discardableResult
    static func deleteExportFiles() throws -> [URL] {
        let tmp = FileManager.default.temporaryDirectory
        let staged = (try? FileManager.default.contentsOfDirectory(
            at: tmp,
            includingPropertiesForKeys: nil
        ))?.filter {
            $0.lastPathComponent.hasPrefix("healthloom-export-") && $0.pathExtension == "json"
        } ?? []
        for url in staged {
            try FileManager.default.removeItem(at: url)
        }
        return staged
    }
}
