// DuplicateWriteRepair.swift
//
// WP-58: removes the second copies of daily resting heart rate the WP-52
// span loop wrote. Each 24 h span diffed against the run's opening
// existence snapshot, and a day-keyed filter returns the day a span starts
// in to that span and the one before it, so every multi-day run saved that
// day twice. The loop no longer does (`PagePipeline.processPages` carries
// the set across spans); this clears what it already wrote.
//
// Once per install (`OneTimeTask`).

import CoreModel
import Foundation

enum DuplicateWriteRepair {
    static let defaultsKey = "com.healthloom.repair.duplicateDailySummaries"

    /// Day-keyed types the Google feed reads (the `.date` rows of
    /// `GoogleDataTypeSchema`) -- the only ones the span overlap duplicated.
    static let affectedTypes: [GoogleDataType] = [.dailyRestingHeartRate]

    static func runIfNeeded(
        defaults: UserDefaults = .standard,
        repair: (GoogleDataType) async throws -> Int
    ) async {
        await OneTimeTask.runIfNeeded(key: defaultsKey, defaults: defaults) {
            var removed = 0
            for type in affectedTypes {
                removed += try await repair(type)
            }
            return "removed \(removed) duplicate daily summaries"
        }
    }
}
