// OneTimeTask.swift
//
// Run-once repairs and migrations (WP-58, WP-62): each runs on foreground
// until it succeeds once, then never again. Marked done only after `body`
// returns, so a locked phone or a HealthKit error leaves it for the next
// foreground instead of skipping it for good.

import Foundation
import os

enum OneTimeTask {
    private static let logger = Logger(subsystem: "app.healthloom", category: "OneTimeTask")

    /// Runs `body` unless `key` is already marked done; `body` returns a
    /// line for the log.
    static func runIfNeeded(key: String, defaults: UserDefaults = .standard, _ body: () async throws -> String) async {
        guard !defaults.bool(forKey: key) else { return }
        do {
            let summary = try await body()
            defaults.set(true, forKey: key)
            logger.log("\(key, privacy: .public) done: \(summary, privacy: .public)")
        } catch {
            logger.notice("\(key, privacy: .public) deferred: \(String(describing: error), privacy: .public)")
        }
    }
}
