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
    /// progress row); throws on the first removal failure.
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
}
