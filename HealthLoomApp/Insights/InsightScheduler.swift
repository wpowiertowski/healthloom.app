// InsightScheduler.swift
//
// WP-34 (implementation-plan.md) "Tests:" line, first half: the scheduling
// decision as a pure function of last-run + clock. Rule: at most one
// insight per calendar day (local), and never before 5am local — the
// "first run after 5am" half of the plan's trigger. The "after the
// overnight BG sync completes" half is a separate gate
// (`syncAllowsRun`) over SyncState freshness, so each half is testable
// alone and neither can silently absorb the other.

import Foundation

enum InsightScheduler {
    /// Earliest local hour an insight may generate.
    static let earliestHour = 5

    /// Once per calendar day, first run at/after 5am local.
    static func shouldRun(lastRun: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        if let lastRun, calendar.isDate(lastRun, inSameDayAs: now) {
            return false
        }
        return calendar.component(.hour, from: now) >= earliestHour
    }

    /// The overnight-sync gate: some sync must have completed since
    /// today's 5am. BG and foreground syncs both write `SyncState`, so
    /// both satisfy this — the overnight BG run is the usual driver, a
    /// 6am manual sync is an equally valid "sync completes".
    static func syncAllowsRun(lastSync: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let lastSync else { return false }
        guard let fiveAM = calendar.date(bySettingHour: earliestHour, minute: 0, second: 0, of: now) else {
            return false
        }
        return lastSync >= fiveAM && lastSync <= now
    }
}
