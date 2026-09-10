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
