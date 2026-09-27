// DashboardSnapshotTests.swift
//
// WP-38 degradation matrix, no-Google-account leg (third-party F8): with
// no account there is no SyncState for any type, so every row renders its
// nil state. Pinned here at the pixel level — "Never synced", "No recent
// data" (WP-56's trend column), gray dot — so a regression that hides the never-synced posture (blank
// rows, crash on nil) fails snapshots instead of reaching review.

import CoreModel
import SwiftUI
import Testing
@testable import HealthLoom

@Suite("Dashboard snapshots (no-account leg)")
struct DashboardSnapshotTests {
    @Test("never-synced row across appearance and content size")
    func neverSyncedRow() {
        let sizes: [(String, ContentSizeCategory)] = [
            ("XS", .extraSmall),
            ("AXXXL", .accessibilityExtraExtraExtraLarge),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (label, size) in sizes {
                SnapshotAssert.assert(
                    SyncTypeRow(type: .steps, state: nil, trend: .empty),
                    named: "syncRow-neverSynced-\(scheme == .light ? "light" : "dark")-\(label)",
                    colorScheme: scheme,
                    sizeCategory: size
                )
            }
        }
    }

    // WP-56: the trend column populated -- the average over its 30-day
    // comparison must stay legible and right-aligned from XS through the
    // largest accessibility size, beside a long synced line.
    @Test("row with a 7-day trend across appearance and content size")
    func trendRow() {
        let sizes: [(String, ContentSizeCategory)] = [
            ("XS", .extraSmall),
            ("AXXXL", .accessibilityExtraExtraExtraLarge),
        ]
        // No `lastSyncedAt`: the relative "Synced … ago" text would make the
        // reference depend on the clock.
        let synced = SyncState(dataType: "heart_rate", lastStatus: "ok", itemCount: 373_285)
        for scheme in [ColorScheme.light, .dark] {
            for (label, size) in sizes {
                SnapshotAssert.assert(
                    SyncTypeRow(
                        type: .heartRate,
                        state: synced,
                        trend: DataTrendText(value: "62 bpm", comparison: "7d avg · +3 bpm vs 30d")
                    ),
                    named: "syncRow-trend-\(scheme == .light ? "light" : "dark")-\(label)",
                    colorScheme: scheme,
                    sizeCategory: size
                )
            }
        }
    }
}
