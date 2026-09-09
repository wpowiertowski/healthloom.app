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

    // Round-2 item 7: the settled states ARE covered in UI — via the
    // one-shot launch-arg stub (short-circuits inside the store, no
    // StoreKit session, no network). Tier buttons need real `Product`
    // instances, which only a StoreKit session can mint: they stay
    // manual-QA until the SKTestSession lane lands (F1).
    @MainActor
    func testTipsComingSoonRenders() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestSeedData", "-UITestTipsStub=empty"]
        app.launch()

        let settingsTab = app.descendants(matching: .any)["tabbar.settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10))
        settingsTab.tap()

        XCTAssertTrue(app.staticTexts["settings.tips.status"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testTipsFailedRetrySettles() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestSeedData", "-UITestTipsStub=failed,empty"]
        app.launch()

        let settingsTab = app.descendants(matching: .any)["tabbar.settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10))
        settingsTab.tap()

        XCTAssertTrue(app.staticTexts["settings.tips.loadError"].waitForExistence(timeout: 10))
        let retry = app.buttons["settings.tips.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        // Fix-round F1: the stub is a SEQUENCE (`failed,empty`), so
        // Retry consumes the next stubbed value and settles to
        // coming-soon with zero network involved — no network-flaky UI
        // test ships.
        retry.tap()
        XCTAssertTrue(app.staticTexts["settings.tips.status"].waitForExistence(timeout: 10))
    }
}
