// YouTabUITests.swift
//
// WP-30 (implementation-plan.md) "Tests:" line — toggling a field off
// removes it (persisted exclusion + next-context gate are pinned at the
// unit level; here the toggle flips and sticks), a correction persists,
// forget clears, and the chat trace names the serving tier.
// `-UITestYouTab` seeds an in-memory profile (derived + clinical +
// correction, one insight, two chat turns) and lands on the You tab, so
// these flows are deterministic without HealthKit data on a simulator.

import XCTest

final class YouTabUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Taps a toggle at its trailing edge (whole-row accessibility frames
    /// make center-taps land on labels — the `AIModelsUITests` precedent).
    @MainActor
    private func tapTrailing(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    /// Launches into the You scenario, lands on the You tab.
    @MainActor
    private func openYou(_ app: XCUIApplication) -> XCUIElementQuery {
        let anyElement = app.descendants(matching: .any)
        XCTAssertTrue(anyElement["you.screen"].waitForExistence(timeout: 10))
        return anyElement
    }

    @MainActor
    func testProfileRendersSeededFields() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestYouTab"]
        app.launch()
        let anyElement = openYou(app)

        // Derived field, clinical badge (excluded by default, D8), and the
        // pinned correction all render.
        XCTAssertTrue(anyElement["you.row.steps.dailyAverage"].waitForExistence(timeout: 10))
        XCTAssertTrue(anyElement["you.clinical.heart.ecg"].exists)
        XCTAssertTrue(anyElement["you.correction.user.goal"].exists)
        // Steps starts included for AI replies.
        XCTAssertEqual((anyElement["you.ai.steps.dailyAverage"].value as? String), "1")
        // WP-37: hit-region audit over the You screen (test plan §6).
        try app.performAccessibilityAudit(for: [.hitRegion])
    }

    @MainActor
    func testToggleOffSticks() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestYouTab"]
        app.launch()
        let anyElement = openYou(app)

        let toggle = anyElement["you.ai.steps.dailyAverage"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        tapTrailing(toggle)
        // The exclusion persists to the store (the toggle re-reads it).
        XCTAssertEqual((anyElement["you.ai.steps.dailyAverage"].value as? String), "0")
    }

    @MainActor
    func testCorrectionPersists() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestYouTab"]
        app.launch()
        let anyElement = openYou(app)

        let edit = anyElement["you.edit.steps.dailyAverage"]
        scrollUntilExists(edit, in: app)
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.tap()
        XCTAssertTrue(anyElement["you.correct.sheet"].waitForExistence(timeout: 10))
        let field = app.textFields["you.correct.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        // Triple-tap selects the pre-filled text so typing replaces it.
        field.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        field.typeText("~9,000 steps/day (my tracker)")
        anyElement["you.correct.save"].tap()
        XCTAssertFalse(anyElement["you.correct.sheet"].waitForExistence(timeout: 5))
        // The corrected text renders with the correction badge.
        XCTAssertTrue(app.staticTexts["~9,000 steps/day (my tracker)"].waitForExistence(timeout: 10))
        XCTAssertTrue(anyElement["you.correction.steps.dailyAverage"].exists)
    }

    @MainActor
    func testForgetChatWipe() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestYouTab"]
        app.launch()
        let anyElement = openYou(app)

        let wipe = anyElement["you.forget.chat"]
        scrollUntilExists(wipe, in: app)
        XCTAssertTrue(wipe.waitForExistence(timeout: 10))
        wipe.tap()
        app.buttons["Erase history"].tap()
        // Two seeded turns cleared (notice names the count).
        XCTAssertTrue(anyElement["you.notice"].label.contains("2 messages cleared"))
    }
}


