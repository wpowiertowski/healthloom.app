// AIModelsUITests.swift
//
// WP-29 (implementation-plan.md) "Tests:" line -- enable blocked without
// key (Claude), blocked without consent (all off-device tiers incl. PCC),
// key delete disables tier, tier switcher in chat shows only enabled tiers.
// `-UITestAIModels[=<scenario>]` scripts every gate input (PCC + Claude
// rows live, stubbed validator, in-memory keys, scrubbed preferences), so
// these flows are deterministic on a simulator where the real gates never
// pass. Each launch starts from scrubbed preferences (the scenario seeds
// only what it names), so assertions never depend on run order.

import XCTest

final class AIModelsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Taps a row control at its trailing edge. A plain `tap()` hits
    /// the element's center -- row controls' accessibility frames span the
    /// whole row width, so center lands on the label/text and never fires
    /// (verified on toggles: no `set()` call, no sheet; and on the key
    /// delete button: key survived). The control itself sits trailing, so
    /// the edge hits reliably on every device size.
    @MainActor
    private func tapTrailing(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    @MainActor
    private func tapToggle(_ toggle: XCUIElement) {
        tapTrailing(toggle)
    }

    /// Polls an element's label until it matches (sheet/keyboard
    /// dismissal re-renders the tree under settling snapshots -- a single
    /// `label` read can land on a stale generation while the state itself
    /// is already correct).
    @MainActor
    private func waitForLabel(_ identifier: String, _ label: String, in app: XCUIApplication, timeout: TimeInterval = 10) {
        let element = app.descendants(matching: .any)[identifier]
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label),
            object: element
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
            "waiting for \(identifier) to read [\(label)]"
        )
    }

    /// Scrolls until the element is hittable (exists + visible +
    /// enabled), not merely existing: row controls near the screen bottom
    /// exist while still tucked under the tab bar, and taps there hit the
    /// chrome instead of the control.
    @MainActor
    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication, maxAttempts: Int = 20) {
        var attempts = 0
        while !element.isHittable && attempts < maxAttempts {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            start.press(forDuration: 0.05, thenDragTo: end)
            attempts += 1
        }
    }

    /// Launches into the scenario, lands on Settings, opens AI Models.
    @MainActor
    private func openAIModels(_ app: XCUIApplication) -> XCUIElementQuery {
        let anyElement = app.descendants(matching: .any)
        // The scenario lands directly on the Settings tab.
        let link = anyElement["settings.aimodels.link"]
        scrollUntilExists(link, in: app)
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap()
        XCTAssertTrue(anyElement["aimodels.screen"].waitForExistence(timeout: 10))
        return anyElement
    }

    @MainActor
    func testPCCEnableBlockedWithoutConsent() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestAIModels"]
        app.launch()
        let anyElement = openAIModels(app)

        // Enabling with nothing recorded presents the consent sheet; the
        // tier stays off behind it.
        let toggle = anyElement["aimodels.toggle.privateCloudCompute"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        tapToggle(toggle)
        XCTAssertTrue(anyElement["aimodels.consent.sheet"].waitForExistence(timeout: 10))
        // The sheet names the destination and the forget-forward rule.
        XCTAssertTrue(app.staticTexts["Apple Private Cloud Compute"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "can't be recalled")).count > 0)

        // Decline: sheet gone, toggle still off, status still blocked.
        anyElement["aimodels.consent.decline"].tap()
        XCTAssertFalse(anyElement["aimodels.consent.sheet"].waitForExistence(timeout: 2))
        XCTAssertEqual((toggle.value as? String), "0")
        XCTAssertTrue(anyElement["aimodels.status.privateCloudCompute"].label.contains("Requires opt-in consent."))

        // Accept: consent recorded, PCC needs no key, tier on.
        tapToggle(toggle)
        XCTAssertTrue(anyElement["aimodels.consent.sheet"].waitForExistence(timeout: 10))
        anyElement["aimodels.consent.accept"].tap()
        XCTAssertFalse(anyElement["aimodels.consent.sheet"].waitForExistence(timeout: 2))
        XCTAssertEqual((toggle.value as? String), "1")
        XCTAssertEqual(anyElement["aimodels.status.privateCloudCompute"].label, "On")
        // Quota line renders (the scenario's quota is ok).
        XCTAssertTrue(anyElement["aimodels.quota.pcc"].label.contains("included"))
    }

    @MainActor
    func testClaudeEnableBlockedWithoutKeyThenSaved() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestAIModels"]
        app.launch()
        let anyElement = openAIModels(app)

        // Consent first, then the key sheet (blocked without key).
        let toggle = anyElement["aimodels.toggle.claude"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        tapToggle(toggle)
        XCTAssertTrue(anyElement["aimodels.consent.sheet"].waitForExistence(timeout: 10))
        anyElement["aimodels.consent.accept"].tap()
        XCTAssertTrue(anyElement["aimodels.key.sheet"].waitForExistence(timeout: 10))
        XCTAssertEqual((toggle.value as? String), "0")

        // Cancel leaves the tier off with consent recorded (re-enable goes
        // straight to key entry, no second consent sheet).
        anyElement["aimodels.key.cancel"].tap()
        XCTAssertFalse(anyElement["aimodels.key.sheet"].waitForExistence(timeout: 2))
        XCTAssertEqual((toggle.value as? String), "0")
        tapToggle(toggle)
        XCTAssertFalse(anyElement["aimodels.consent.sheet"].waitForExistence(timeout: 2))
        XCTAssertTrue(anyElement["aimodels.key.sheet"].waitForExistence(timeout: 10))

        // The scenario's validator accepts any key: save stores and enables.
        let field = app.secureTextFields["aimodels.key.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("sk-ant-uitest")
        anyElement["aimodels.key.save"].tap()
        XCTAssertFalse(anyElement["aimodels.key.sheet"].waitForExistence(timeout: 10))
        XCTAssertEqual((toggle.value as? String), "1")
        XCTAssertEqual(anyElement["aimodels.status.claude"].label, "On")
    }

    @MainActor
    func testRejectedKeyIsNotStored() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestAIModels=invalidKey"]
        app.launch()
        let anyElement = openAIModels(app)

        let toggle = anyElement["aimodels.toggle.claude"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        tapToggle(toggle)
        anyElement["aimodels.consent.accept"].tap()
        XCTAssertTrue(anyElement["aimodels.key.sheet"].waitForExistence(timeout: 10))

        let field = app.secureTextFields["aimodels.key.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("sk-ant-wrong")
        anyElement["aimodels.key.save"].tap()

        // Rejection copy (not a transport message), sheet stays, tier off.
        let error = anyElement["aimodels.key.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue(error.label.contains("rejected"))
        XCTAssertTrue(anyElement["aimodels.key.sheet"].exists)
        XCTAssertEqual((toggle.value as? String), "0")
    }

    @MainActor
    func testKeyDeleteDisablesTier() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestAIModels"]
        app.launch()
        let anyElement = openAIModels(app)

        // Enable Claude fully first (consent + key).
        let toggle = anyElement["aimodels.toggle.claude"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        tapToggle(toggle)
        anyElement["aimodels.consent.accept"].tap()
        XCTAssertTrue(anyElement["aimodels.key.sheet"].waitForExistence(timeout: 10))
        let field = app.secureTextFields["aimodels.key.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("sk-ant-uitest")
        anyElement["aimodels.key.save"].tap()
        XCTAssertFalse(anyElement["aimodels.key.sheet"].waitForExistence(timeout: 10))
        waitForLabel("aimodels.status.claude", "On", in: app)

        // Delete the key: the row reports the key blocker (toggle
        // preference stays; the gate is what dropped).
        let delete = anyElement["aimodels.key.delete.claude"]
        scrollUntilHittable(delete, in: app)
        XCTAssertTrue(delete.isHittable, "delete key button never became hittable")
        // WP-29 re-review: the Delete button needs the trailing-edge tap
        // (same whole-row accessibility-frame reason as the toggles).
        tapTrailing(delete)
        // The delete round-trips the (in-memory, stubbed) Keychain on a
        // Task -- poll until the gate drop renders, same settle race as
        // above. The toggle preference stays on, so the row reads the bare
        // blocker reason.
        waitForLabel("aimodels.status.claude", "Requires an API key.", in: app)
    }

    @MainActor
    func testChatSlotShowsOnlyEnabledTiers() throws {
        // The pccOn scenario pre-consents and enables PCC (on-device is
        // always on); Claude is neither consented nor keyed.
        let app = XCUIApplication()
        app.launchArguments = ["-UITestAIModels=pccOn"]
        app.launch()

        let anyElement = app.descendants(matching: .any)
        anyElement["tabbar.coach"].tap()
        let slot = anyElement["chat.tierSlot"]
        XCTAssertTrue(slot.waitForExistence(timeout: 10))
        XCTAssertTrue(slot.label.contains("On-device"))
        XCTAssertTrue(slot.label.contains("Apple cloud (PCC)"))
        XCTAssertFalse(slot.label.contains("Claude"))
        XCTAssertFalse(slot.label.contains("Gemini"))
    }
}
