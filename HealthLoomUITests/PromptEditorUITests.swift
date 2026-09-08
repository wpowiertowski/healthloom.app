// PromptEditorUITests.swift
//
// WP-26 (implementation-plan.md) "Tests:" line -- edit → preview contains
// edit + suffix; reset restores default; history restore works. Seeded
// launch (in-memory store, past onboarding, lands on Data): Settings tab →
// Coach Prompt row. The in-memory store makes every run start from the
// compiled-in default with empty history, so the assertions are
// deterministic.

import XCTest

final class PromptEditorUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEditPreviewResetAndHistoryRestore() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestSeedData"]
        app.launch()

        let anyElement = app.descendants(matching: .any)
        let settingsTab = anyElement["tabbar.settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10))
        settingsTab.tap()

        let promptLink = anyElement["settings.prompt.link"]
        XCTAssertTrue(promptLink.waitForExistence(timeout: 10))
        promptLink.tap()

        XCTAssertTrue(anyElement["prompt.screen"].waitForExistence(timeout: 10))
        // Fresh store: matches the shipped default, history empty, reset
        // disabled (it would append a no-op history row).
        XCTAssertTrue(anyElement["prompt.diff.clean"].waitForExistence(timeout: 10))
        XCTAssertTrue(anyElement["prompt.history.empty"].exists)
        XCTAssertFalse(anyElement["prompt.reset"].isEnabled)

        // Edit: append a marker (position-independent -- the tap may land
        // mid-text, but the marker stays one contiguous substring either
        // way), then save.
        let editor = anyElement["prompt.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText(" UITest edit marker.")
        anyElement["prompt.save"].tap()
        XCTAssertTrue(anyElement["prompt.notice"].waitForExistence(timeout: 10))

        // Preview shows the exact effective prompt: the edit plus the
        // locked safety suffix.
        let preview = anyElement["prompt.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertTrue(preview.label.contains("UITest edit marker."))
        let suffix = anyElement["prompt.suffix"]
        XCTAssertTrue(suffix.exists)
        XCTAssertTrue(suffix.label.contains("not a medical professional"))
        XCTAssertFalse(anyElement["prompt.diff.clean"].waitForExistence(timeout: 2))

        // Reset restores the default; the save + reset both stay in history.
        anyElement["prompt.reset"].tap()
        XCTAssertTrue(anyElement["prompt.diff.clean"].waitForExistence(timeout: 10))
        XCTAssertFalse(preview.label.contains("UITest edit marker."))

        // History restore reaches the pre-reset edit (newest-first: index 0
        // is the reset row carrying default text, index 1 is the edit).
        let restoreButtons = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@",
            "prompt.restore."
        ))
        XCTAssertEqual(restoreButtons.count, 2)
        restoreButtons.element(boundBy: 1).tap()
        XCTAssertTrue(anyElement["prompt.notice"].waitForExistence(timeout: 10))
        XCTAssertTrue(preview.label.contains("UITest edit marker."))
        // WP-37: hit-region audit over the prompt editor (test plan §6).
        try app.performAccessibilityAudit(for: [.hitRegion])
    }
}
