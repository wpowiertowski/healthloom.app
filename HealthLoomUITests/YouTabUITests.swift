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

    /// Replaces a text field's contents without a select-all gesture.
    ///
    /// A triple-tap select-all is the flaky step on loaded runners: when
    /// it misses, the tap leaves the cursor mid-prefill and the typed text
    /// is spliced into it (PR #32, and again PR #51 after a retype-once
    /// guard was added). Deleting the known prefill needs no selection:
    /// tap past the last glyph to park the cursor at the end, delete as
    /// many characters as the field reports, and re-read. If the cursor
    /// still landed mid-text, the leftover suffix is short enough that the
    /// next trailing tap lands after it. The typed result is verified the
    /// same way, since the keyboard can also drop characters.
    @MainActor
    private func replaceText(
        in field: XCUIElement, with text: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for _ in 0..<3 {
            clear(field)
            field.typeText(text)
            if (field.value as? String) == text { return }
        }
        XCTFail(
            "field holds \(String(describing: field.value)) after three attempts, "
                + "expected \(text) — typing fidelity failure, not a product regression",
            file: file, line: line
        )
    }

    /// Empties a text field by deleting from the end. An empty
    /// `UITextField` reports its placeholder as its value.
    @MainActor
    private func clear(_ field: XCUIElement) {
        for _ in 0..<3 {
            let current = (field.value as? String) ?? ""
            if current.isEmpty || current == field.placeholderValue { return }
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
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
        let expectedCorrection = "~9,000 steps/day (my tracker)"
        replaceText(in: field, with: expectedCorrection)
        anyElement["you.correct.save"].tap()
        XCTAssertFalse(anyElement["you.correct.sheet"].waitForExistence(timeout: 5))
        // The corrected text renders with the correction badge.
        XCTAssertTrue(app.staticTexts[expectedCorrection].waitForExistence(timeout: 10))
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


