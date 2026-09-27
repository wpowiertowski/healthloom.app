// ThemedHeaderLayoutTests.swift
//
// WP-54: the title + actions row must not change shape when a header
// button goes busy. On a `.firstTextBaseline` row the Sync spinner (no text
// baseline) hung from the title's baseline: the buttons dropped and the
// header grew ~23 pt every time Sync Now ran.

import SwiftUI
import Testing
@testable import HealthLoom

@MainActor
@Suite struct ThemedHeaderLayoutTests {
    private func renderedHeight(syncBusy: Bool) throws -> CGFloat {
        let header = ThemedHeader(title: "HealthLoom") {
            ThemedIconButton(
                systemImage: "gearshape",
                accessibilityLabel: "Settings",
                accessibilityIdentifier: "test.settings",
                action: {}
            )
            ThemedIconButton(
                systemImage: "arrow.triangle.2.circlepath",
                accessibilityLabel: "Sync Now",
                accessibilityIdentifier: "test.sync",
                isBusy: syncBusy,
                action: {}
            )
        }
        .frame(width: 390)
        let renderer = ImageRenderer(content: header)
        renderer.scale = 2
        let image = try #require(renderer.uiImage, "header rendered no image")
        return image.size.height
    }

    // catches: the header row growing (and its buttons dropping) when the
    // Sync button swaps its icon for a spinner.
    @Test func busyButtonLeavesTheHeaderHeightUnchanged() throws {
        #expect(try renderedHeight(syncBusy: true) == renderedHeight(syncBusy: false))
    }
}
