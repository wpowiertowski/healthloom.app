// DuplicateWriteRepair.swift
//
// WP-58: removes the second copies of daily resting heart rate the WP-52
// span loop wrote. Each 24 h span diffed against the run's opening
// existence snapshot, and a day-keyed filter returns the day a span starts
// in to that span and the one before it, so every multi-day run saved that
// day twice. The loop no longer does (`PagePipeline.processPages` carries
// the set across spans); this clears what it already wrote.
//
// Once per install, marked done only after it succeeds: a locked phone or
// a HealthKit error leaves it to run again on the next foreground.

import CoreModel
import Foundation
import os

enum DuplicateWriteRepair {
    static let defaultsKey = "com.healthloom.repair.duplicateDailySummaries"

    /// Day-keyed types the Google feed reads (the `.date` rows of
    /// `GoogleDataTypeSchema`) -- the only ones the span overlap duplicated.
    static let affectedTypes: [GoogleDataType] = [.dailyRestingHeartRate]

    private static let logger = Logger(subsystem: "app.healthloom", category: "DuplicateRepair")

    static func runIfNeeded(
        defaults: UserDefaults = .standard,
        repair: (GoogleDataType) async throws -> Int
    ) async {
        guard !defaults.bool(forKey: defaultsKey) else { return }
        do {
            var removed = 0
            for type in affectedTypes {
                removed += try await repair(type)
            }
            defaults.set(true, forKey: defaultsKey)
            logger.log("Removed \(removed, privacy: .public) duplicate daily summaries")
        } catch {
            logger.notice("Duplicate repair deferred: \(String(describing: error), privacy: .public)")
        }
    }
}
