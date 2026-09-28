// SyncSchedule.swift
//
// WP-63: runs a sync over several types a few at a time instead of one
// after another. A run is mostly waiting -- on Google's round trips and on
// HealthKit's queries -- so the types overlap well: a normal 26-type sync
// spent ~1m40s walking them in sequence. Bounded, so Google sees a few
// concurrent requests, not 26. Safe per type: `SyncEngine` and
// `WatchConflictResolver` keep their run state per type, and each run
// uses its own `ModelContext`.
//
// One implementation for Sync Now, first sync and the background path.
// The callbacks are `@Sendable` and async: a caller hops to its own actor
// inside them (`ForegroundSync` marks them `@MainActor`). An `isolated`
// parameter doesn't do it -- the task group's body closure doesn't inherit
// it, so main-actor callbacks ran on a background thread and trapped (the
// build-21 crash class; caught by ForegroundSync's tests).

import CoreModel
import Foundation

nonisolated public enum SyncSchedule {
    /// How many types sync at once.
    public static let maxConcurrentTypes = 3

    /// Runs `work` for each of `types`, at most `maxConcurrent` at a time,
    /// starting them in order. `shouldStart` is asked before each start: once
    /// it says no, nothing further starts (the background budget). Returns
    /// the results of every started type, in `types` order.
    public static func run<Result: Sendable>(
        _ types: [GoogleDataType],
        maxConcurrent: Int = maxConcurrentTypes,
        shouldStart: @escaping @Sendable () async -> Bool = { true },
        didStart: @escaping @Sendable (GoogleDataType) async -> Void = { _ in },
        didFinish: @escaping @Sendable (GoogleDataType) async -> Void = { _ in },
        work: @escaping @Sendable (GoogleDataType) async -> Result
    ) async -> [Result] {
        var results = [Result?](repeating: nil, count: types.count)
        let limit = max(1, maxConcurrent)
        await withTaskGroup(of: (Int, Result).self) { group in
            var next = 0
            var running = 0
            while true {
                // Fill free lanes; once `shouldStart` refuses, start nothing more.
                while next < types.count, running < limit {
                    guard await shouldStart() else { next = types.count; break }
                    let index = next
                    next += 1
                    running += 1
                    await didStart(types[index])
                    group.addTask { (index, await work(types[index])) }
                }
                guard let (index, result) = await group.next() else { break }
                running -= 1
                results[index] = result
                await didFinish(types[index])
            }
        }
        return results.compactMap { $0 }
    }
}
