// SyncScheduleTests.swift
//
// WP-63: several types at a time, never more than the bound, results in
// input order, and no new start once `shouldStart` refuses.

import CoreModel
import Foundation
import Testing
@testable import SyncKit

@Suite struct SyncScheduleTests {
    /// Counts how many `work` calls overlap.
    actor Lanes {
        private(set) var running = 0
        private(set) var peak = 0
        func enter() { running += 1; peak = max(peak, running) }
        func leave() { running -= 1 }
    }

    static let types: [GoogleDataType] = [.steps, .heartRate, .sleep, .weight, .distance, .floors, .height]

    // catches: types still syncing one after another (the whole point),
    // or an unbounded fan-out sending Google every type at once.
    @Test func runsUpToTheBoundAtOnce() async {
        let lanes = Lanes()
        _ = await SyncSchedule.run(Self.types, maxConcurrent: 3) { _ in
            await lanes.enter()
            try? await Task.sleep(for: .milliseconds(30))
            await lanes.leave()
            return 0
        }
        #expect(await lanes.peak == 3)
    }

    // catches: outcomes reordered by finish time (callers pair them with
    // their types), or a type dropped.
    @Test func resultsComeBackInInputOrder() async {
        let results = await SyncSchedule.run(Self.types, maxConcurrent: 3) { type in
            // Later types finish first.
            try? await Task.sleep(for: .milliseconds(Double(10 * (Self.types.count - (Self.types.firstIndex(of: type) ?? 0)))))
            return type
        }
        #expect(results == Self.types)
    }

    // catches: the background budget or expiry ignored -- types keep
    // starting after `shouldStart` said stop (past the system deadline).
    @Test func nothingStartsOnceShouldStartRefuses() async {
        actor Budget {
            var asked = 0
            func allow() -> Bool { asked += 1; return asked <= 3 }
        }
        let budget = Budget()
        let results = await SyncSchedule.run(Self.types, maxConcurrent: 2, shouldStart: {
            await budget.allow()
        }) { type in type }
        #expect(results == Array(Self.types.prefix(3)))
    }

    // catches: callbacks running on the wrong actor -- a caller's
    // main-actor state updated from a background thread traps at runtime
    // (the first cut of this scheduler crashed Sync Now exactly so).
    @MainActor
    @Test func callbacksCanHopToTheCallersActor() async {
        final class Seen { var started: [GoogleDataType] = []; var finished: [GoogleDataType] = [] }
        let seen = Seen()
        _ = await SyncSchedule.run(Self.types, didStart: { @MainActor type in
            MainActor.assertIsolated()
            seen.started.append(type)
        }, didFinish: { @MainActor type in
            MainActor.assertIsolated()
            seen.finished.append(type)
        }) { type in type }
        #expect(seen.started == Self.types)
        #expect(Set(seen.finished) == Set(Self.types))
    }
}
