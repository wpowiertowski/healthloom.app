// CoachSnapshotTests.swift
//
// WP-78: the coach's typing indicator -- named while the model thinks or a
// tool runs, bare dots under a streaming reply. The bubble is drawn at
// fixed frames (all dots even, as under Reduce Motion, and one lit), so
// the image doesn't depend on the clock.

import SwiftUI
import Testing
@testable import HealthLoom

@Suite("Coach snapshots")
struct CoachSnapshotTests {
    @Test("typing indicator across appearance and content size")
    @MainActor
    func activityIndicator() {
        let configs: [(String, ColorScheme, ContentSizeCategory)] = [
            ("light-XL", .light, .extraLarge),
            ("dark-XL", .dark, .extraLarge),
            ("light-AXXXL", .light, .accessibilityExtraExtraExtraLarge),
        ]
        let subject = VStack(alignment: .leading, spacing: 12) {
            CoachActivityBubble(label: "Thinking\u{2026}", lit: nil)
            CoachActivityBubble(label: "Reading workout 2 (ground contact time)\u{2026}", lit: 1)
            CoachActivityBubble(label: nil, lit: 2)
        }
        .frame(width: 360, alignment: .leading)
        .padding()
        .background(Theme.canvas)
        for (configName, scheme, size) in configs {
            SnapshotAssert.assert(subject, named: "activity-\(configName)", colorScheme: scheme, sizeCategory: size)
        }
    }
}
