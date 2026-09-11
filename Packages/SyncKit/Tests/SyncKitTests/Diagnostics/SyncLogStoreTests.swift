// SyncLogStoreTests.swift
//
// WP-18 (implementation-plan.md) "Tests:" line, verbatim: "ring-buffer
// capping." Pushes more entries than the configured cap and verifies the
// exact FIFO eviction contract `SyncLogStore.swift`'s header documents:
// oldest entries evicted first, newest retained, exact resulting count.
import CoreModel
import Foundation
import Testing
@testable import SyncKit

@Suite struct SyncLogStoreTests {
    static func entry(_ index: Int, at date: Date) -> SyncLogEntry {
        SyncLogEntry(
            timestamp: date,
            dataType: .steps,
            status: .ok,
            itemCount: index
        )
    }

    @Test func wakeCostsSingleAppendsNotFullRewrites() async {
        // Round-10 item 13: a 26-entry wake must cost 26 O(1) appends
        // and ZERO full rewrites (the old shape re-encoded + atomic-
        // rewrote the whole file per entry — 26 encodes + 26 writes
        // inside the ~20s budget). Compaction only fires at cap.
        final class CountingPersistence: SyncLogPersisting, @unchecked Sendable {
            private let lock = NSLock()
            private(set) var appends = 0
            private(set) var saves = 0
            nonisolated func load() -> [SyncLogEntry] { [] }
            nonisolated func save(_ entries: [SyncLogEntry]) {
                lock.lock(); defer { lock.unlock() }
                saves += 1
            }
            nonisolated func append(_ entry: SyncLogEntry) {
                lock.lock(); defer { lock.unlock() }
                appends += 1
            }
        }
        let persistence = CountingPersistence()
        let store = SyncLogStore(persistence: persistence)
        let base = Date(timeIntervalSince1970: 0)
        for index in 0..<26 {
            await store.append(Self.entry(index, at: base.addingTimeInterval(Double(index))))
        }
        #expect(persistence.appends == 26)
        #expect(persistence.saves == 0)
        #expect(await store.count() == 26)
    }

    @Test func compactionRewritesAtCap() async {
        // Round-10 item 13: once at cap, every `compactionInterval`
        // appends triggers one full rewrite (bounding file slack);
        // in-memory eviction stays exact and reload sees the cap.
        final class CountingPersistence: SyncLogPersisting, @unchecked Sendable {
            private let lock = NSLock()
            private(set) var saves = 0
            private nonisolated(unsafe) var saved: [SyncLogEntry] = []
            nonisolated func load() -> [SyncLogEntry] {
                lock.lock(); defer { lock.unlock() }
                return saved
            }
            nonisolated func save(_ entries: [SyncLogEntry]) {
                lock.lock(); defer { lock.unlock() }
                saves += 1
                saved = entries
            }
            // No-op: per-entry durability is the FILE conformer's job;
            // this fake isolates the store's compaction cadence (the
            // default append would `save` on every call and hide it).
            nonisolated func append(_ entry: SyncLogEntry) {}
        }
        let persistence = CountingPersistence()
        let store = SyncLogStore(capacity: 5, compactionInterval: 3, persistence: persistence)
        let base = Date(timeIntervalSince1970: 0)
        for index in 0..<10 {
            await store.append(Self.entry(index, at: base.addingTimeInterval(Double(index))))
        }
        // Entries 0-4 fill below cap (no compaction); 5-9 at cap with
        // interval 3 compact at the 6th and 9th at-cap appends.
        #expect(persistence.saves == 2)
        #expect(await store.count() == 5)
        #expect(await store.recentEntries().map(\.itemCount) == [5, 6, 7, 8, 9])
    }

    @Test func fileLinesRoundTripAndArrayMigrates() throws {
        // Round-10 item 13: the lines format round-trips through a
        // real file; a pre-change whole-array file still loads
        // (self-migrating on the next `save`).
        let dir = FileManager.default.temporaryDirectory.appending(
            path: "synclog-r10-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "SyncLog.json", directoryHint: .notDirectory)
        let persistence = FileSyncLogPersistence(fileURL: url)
        let base = Date(timeIntervalSince1970: 0)
        persistence.append(Self.entry(0, at: base))
        persistence.append(Self.entry(1, at: base.addingTimeInterval(1)))
        #expect(persistence.load().map(\.itemCount) == [0, 1])
        let arrayData = try JSONEncoder().encode([Self.entry(7, at: base), Self.entry(8, at: base)])
        try arrayData.write(to: url, options: .atomic)
        #expect(persistence.load().map(\.itemCount) == [7, 8])
    }

    @Test func appendingFewerEntriesThanCapacityKeepsAllOfThem() async {
        let store = SyncLogStore(capacity: 5, persistence: NullSyncLogPersistence())
        let base = Date(timeIntervalSince1970: 0)
        for index in 0..<3 {
            await store.append(Self.entry(index, at: base.addingTimeInterval(Double(index))))
        }
        let entries = await store.recentEntries()
        #expect(entries.count == 3)
        #expect(entries.map(\.itemCount) == [0, 1, 2])
    }

    @Test func pushingMoreEntriesThanTheCapEvictsOldestFirstAndRetainsExactCount() async {
        let capacity = 5
        let store = SyncLogStore(capacity: capacity, persistence: NullSyncLogPersistence())
        let base = Date(timeIntervalSince1970: 0)

        // Push 8 entries (indices 0...7) through a cap of 5.
        for index in 0..<8 {
            await store.append(Self.entry(index, at: base.addingTimeInterval(Double(index))))
        }

        let entries = await store.recentEntries()
        // Exact count: capped, never grows past the configured capacity.
        #expect(entries.count == capacity)
        #expect(await store.count() == capacity)
        // Oldest evicted (0, 1, 2 are gone), newest retained, in original
        // (oldest-first) order -- the last element is the most recent push.
        #expect(entries.map(\.itemCount) == [3, 4, 5, 6, 7])
        #expect(entries.first?.itemCount == 3)
        #expect(entries.last?.itemCount == 7)
    }

    @Test func recentEntriesLimitWindowsToTheMostRecentSubset() async {
        let store = SyncLogStore(capacity: 100, persistence: NullSyncLogPersistence())
        let base = Date(timeIntervalSince1970: 0)
        for index in 0..<10 {
            await store.append(Self.entry(index, at: base.addingTimeInterval(Double(index))))
        }
        let last3 = await store.recentEntries(limit: 3)
        #expect(last3.map(\.itemCount) == [7, 8, 9])
    }

    @Test func nonPositiveLimitReturnsEmptyNeverTraps() async {
        // Round-7 item 11: `suffix(-1)` traps (process crash) — a
        // non-positive window is empty, never the whole log (same
        // contract as `PromptManager.history(limit:)`).
        let store = SyncLogStore(capacity: 100, persistence: NullSyncLogPersistence())
        let base = Date(timeIntervalSince1970: 0)
        for index in 0..<5 {
            await store.append(Self.entry(index, at: base.addingTimeInterval(Double(index))))
        }
        #expect(await store.recentEntries(limit: 0).isEmpty)
        #expect(await store.recentEntries(limit: -1).isEmpty)
        #expect(await store.recentEntries(limit: -10_000).isEmpty)
        #expect(await store.recentEntries(limit: nil).count == 5)
        #expect(await store.recentEntries(limit: 99).count == 5)
    }

    @Test func clearRemovesEveryEntry() async {
        let store = SyncLogStore(capacity: 10, persistence: NullSyncLogPersistence())
        await store.append(Self.entry(0, at: Date()))
        await store.append(Self.entry(1, at: Date()))
        await store.clear()
        #expect(await store.count() == 0)
    }

    @Test func persistenceRoundTripsAndAppliesTheSameCapOnReload() async {
        final class MemoryPersistence: SyncLogPersisting, @unchecked Sendable {
            private let lock = NSLock()
            private nonisolated(unsafe) var saved: [SyncLogEntry] = []
            nonisolated func load() -> [SyncLogEntry] {
                lock.lock(); defer { lock.unlock() }
                return saved
            }
            nonisolated func save(_ entries: [SyncLogEntry]) {
                lock.lock(); defer { lock.unlock() }
                saved = entries
            }
        }

        let persistence = MemoryPersistence()
        let base = Date(timeIntervalSince1970: 0)
        let first = SyncLogStore(capacity: 3, persistence: persistence)
        for index in 0..<5 {
            await first.append(Self.entry(index, at: base.addingTimeInterval(Double(index))))
        }
        // First store already capped to 3 (indices 2,3,4) before a second
        // instance ever loads from the same persistence.
        #expect(await first.recentEntries().map(\.itemCount) == [2, 3, 4])

        // A brand-new store over the same (already-capped) persisted data
        // loads exactly what was saved, re-applying its own cap defensively.
        let reloaded = SyncLogStore(capacity: 3, persistence: persistence)
        #expect(await reloaded.recentEntries().map(\.itemCount) == [2, 3, 4])
    }
}
