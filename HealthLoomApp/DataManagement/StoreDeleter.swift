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
    /// All files comprising the store (main + SQLite sidecars).
    static func storeFileURLs() throws -> [URL] {
        let main = try CoreModel.productionStoreURL()
        return [
            main,
            URL(fileURLWithPath: main.path + "-wal"),
            URL(fileURLWithPath: main.path + "-shm"),
        ]
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
