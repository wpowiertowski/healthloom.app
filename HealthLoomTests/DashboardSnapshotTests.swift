// DashboardSnapshotTests.swift
//
// WP-38 degradation matrix, no-Google-account leg (third-party F8): with
// no account there is no SyncState for any type, so every row renders its
// nil state. Pinned here at the pixel level — "Never synced", zero count,
// gray dot — so a regression that hides the never-synced posture (blank
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
                    SyncTypeRow(type: .steps, state: nil),
                    named: "syncRow-neverSynced-\(scheme == .light ? "light" : "dark")-\(label)",
                    colorScheme: scheme,
                    sizeCategory: size
                )
            }
        }
    }
}
