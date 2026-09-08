// InsightUITests.swift
//
// WP-34 (implementation-plan.md) "Tests:" line's UI-test requirement
// ("UI test for permission flow"). The notification center is stubbed
// (`-UITestStubNotifications`: starts `.notDetermined`, grants on
// request; `-UITestNotificationsDenied`: starts `.denied`), so both
// sides of the in-context permission request are deterministic — no
// system sheet ever appears.
//
// Insight toggles live in `UserDefaults.standard`, which outlives
// launches on a simulator: both tests drive the toggle to a known state
// through its own `value` instead of assuming a fresh default.

import XCTest

final class InsightUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func openSettings(_ app: XCUIApplication) -> XCUIElementQuery {
        let anyElement = app.descendants(matching: .any)
        let settingsTab = anyElement["tabbar.settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10))
        settingsTab.tap()
        let toggle = anyElement["settings.insights.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        // Existence is not hittability: the insights panel sits below
        // several others, so scroll until the toggle is tappable.
        var swipes = 0
        while !toggle.isHittable, swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(toggle.isHittable)
        return anyElement
    }

    private func scrollToHittable(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        // Bidirectional: earlier swipes may have pushed this element off
        // either edge. Below the fold swipes up; above it swipes down.
        var swipes = 0
        while !element.isHittable, swipes < 12 {
            if element.frame.minY < 0 {
                app.swipeDown()
            } else {
                app.swipeUp()
            }
            swipes += 1
        }
        XCTAssertTrue(element.isHittable, file: file, line: line)
        // Let scroll deceleration finish: tapping while the list still
        // moves lands on the wrong row (or nowhere).
        Thread.sleep(forTimeInterval: 0.5)
    }

    private func setToggle(
        _ toggle: XCUIElement,
        to state: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Drive to a known state regardless of what a previous run left.
        // State updates resolve asynchronously — wait, don't assert.
        scrollToHittable(toggle, in: app, file: file, line: line)
        // Up to three attempts: a tap landing mid-animation can be dropped
        // by SwiftUI — but re-check before each re-tap, or a slow success
        // gets inverted by the retry. Polled direct reads (not an
        // NSPredicate on `value`, which never matches Switch values even
        // when the direct read shows the target state).
        for _ in 0..<3 {
            if (toggle.value as? String) == state { return }
            toggle.tap()
            let deadline = Date().addingTimeInterval(5)
            while (toggle.value as? String) != state, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
        }
        XCTAssertEqual(toggle.value as? String, state, file: file, line: line)
    }

    @MainActor
    func testInsightTogglesEnableWithPermissionGrant() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestSeedData", "-UITestStubNotifications"]
        app.launch()
        let anyElement = openSettings(app)

        // Enabling with `.notDetermined` requests in context (stub grants):
        // the toggle sticks ON and no denied guidance appears. The grant
        // resolves asynchronously, so wait for the value, don't assert it.
        let enable = anyElement["settings.insights.toggle"]
        setToggle(enable, to: "0", in: app)
        enable.tap()
        setToggle(enable, to: "1", in: app)
        XCTAssertFalse(anyElement["settings.insights.deniedHint"].exists)

        // The two sub-toggles flip and stick.
        let fullText = anyElement["settings.insights.fullText"]
        XCTAssertTrue(fullText.exists)
        setToggle(fullText, to: "1", in: app)
        let viaCloud = anyElement["settings.insights.viaCloud"]
        XCTAssertTrue(viaCloud.exists)
        setToggle(viaCloud, to: "1", in: app)
        // No tidy-down: `UserDefaults` persists across runs, but every
        // assertion above drives from the current value first, so leftover
        // ON states are a valid start state, not pollution.
    }

    @MainActor
    func testDeniedStatusShowsGuidance() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestSeedData", "-UITestNotificationsDenied"]
        app.launch()
        let anyElement = openSettings(app)

        XCTAssertTrue(anyElement["settings.insights.deniedHint"].waitForExistence(timeout: 5))
        // Delivery proof in-run (a dropped tap below would false-pass):
        // the direct-bound full-text toggle must flip and stick.
        let fullText = anyElement["settings.insights.fullText"]
        setToggle(fullText, to: "1", in: app)
        // Enabling while denied answers immediately with denial, so the
        // optimistic ON reverts OFF — end state OFF + guidance visible.
        // (The grant test proves the ON path sticks when allowed.)
        let enable = anyElement["settings.insights.toggle"]
        enable.tap()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(enable.value as? String, "0")
        XCTAssertTrue(anyElement["settings.insights.deniedHint"].exists)
    }
}
