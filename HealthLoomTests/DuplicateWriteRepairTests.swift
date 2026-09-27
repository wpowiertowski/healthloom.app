// DuplicateWriteRepairTests.swift
//
// WP-58: the one-time duplicate repair runs until it succeeds, then never
// again.

import CoreModel
import Foundation
import Testing
@testable import HealthLoom

@Suite("Duplicate write repair")
@MainActor
struct DuplicateWriteRepairTests {
    private struct Refused: Error {}

    private func freshDefaults() throws -> UserDefaults {
        let suite = "DuplicateWriteRepairTests.\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: suite))
    }

    // catches: re-running the repair on every foreground (a HealthKit
    // query over all resting heart rate history each time).
    @Test func runsOnceAfterSucceeding() async throws {
        let defaults = try freshDefaults()
        var repaired: [GoogleDataType] = []

        await DuplicateWriteRepair.runIfNeeded(defaults: defaults) { type in
            repaired.append(type)
            return 3
        }
        await DuplicateWriteRepair.runIfNeeded(defaults: defaults) { type in
            repaired.append(type)
            return 0
        }

        #expect(repaired == DuplicateWriteRepair.affectedTypes)
    }

    // catches: marking the repair done when HealthKit refused it (a
    // locked phone), leaving the duplicates in place for good.
    @Test func aFailedRepairRunsAgain() async throws {
        let defaults = try freshDefaults()
        var attempts = 0

        await DuplicateWriteRepair.runIfNeeded(defaults: defaults) { _ in
            attempts += 1
            throw Refused()
        }
        await DuplicateWriteRepair.runIfNeeded(defaults: defaults) { _ in
            attempts += 1
            return 1
        }

        #expect(attempts == 2)
        #expect(defaults.bool(forKey: DuplicateWriteRepair.defaultsKey))
    }
}
