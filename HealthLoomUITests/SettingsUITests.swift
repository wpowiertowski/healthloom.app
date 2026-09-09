// SettingsUITests.swift
//
// iCloud sync section: the status surface must render on the Settings
// tab in every launch configuration. Only existence is pinned here —
// the status TEXT depends on the device's iCloud account (absent on CI
// sims, possibly present on a dev machine), and every status value is
// pinned deterministically in CloudSyncTests.

import XCTest

final class SettingsUITests: XCTestCase {
    @MainActor
    func testICloudSectionRenders() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestSeedData"]
        app.launch()

        let settingsTab = app.descendants(matching: .any)["tabbar.settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10))
        settingsTab.tap()

        let status = app.staticTexts["settings.icloud.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["settings.icloud.syncNow"].exists)

        // Tip jar never fetches in UI tests (hermetic gate), so it
        // renders its pre-fetch loading state deterministically — never
        // tier buttons, never coming-soon.
        XCTAssertTrue(app.activityIndicators["settings.tips.loading"].waitForExistence(timeout: 10))
    }
}
