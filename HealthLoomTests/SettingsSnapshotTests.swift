// SettingsSnapshotTests.swift
//
// WP-60: the sleep source row must keep its label and both segments
// legible from XS through the largest accessibility size (it stacks when
// the segmented picker no longer fits beside the label).

import SwiftUI
import SyncKit
import Testing
@testable import HealthLoom

@Suite("Settings snapshots")
struct SettingsSnapshotTests {
    @Test("sleep source row across appearance and content size")
    func sleepSourceRow() {
        let sizes: [(String, ContentSizeCategory)] = [
            ("XS", .extraSmall),
            ("AXXXL", .accessibilityExtraExtraExtraLarge),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (label, size) in sizes {
                SnapshotAssert.assert(
                    SleepSourceRow(source: .constant(.fitbit)),
                    named: "sleepSourceRow-\(scheme == .light ? "light" : "dark")-\(label)",
                    colorScheme: scheme,
                    sizeCategory: size
                )
            }
        }
    }
}
