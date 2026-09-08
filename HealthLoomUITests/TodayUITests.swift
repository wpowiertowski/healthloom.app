// TodayUITests.swift
//
// WP-33 (implementation-plan.md) "Tests:" line's UI-test requirement
// ("UI test for edit mode") plus a render smoke test for the new Today
// screen. Uses the same `-UITestSeedData` machinery as DashboardUITests:
// the seeded launch lands on the Data tab (RootView keeps that behavior
// for the dashboard tests), so this test's first move is tapping the
// Today tab -- which also exercises the new WP-33 tab bar itself.
//
// `-UITestResetTodayMetrics` (first launch only) clears any metric order
// a previous run persisted -- `UserDefaults.standard` outlives launches
// on a simulator, and this test's relaunch leg deliberately drops the
// flag to prove real persistence (WP-33's "order persists in
// UserDefaults").
//
// The simulator's HealthKit store holds no metric data, so rows render
// their "No data yet" empty state and the hero shows the pending
// readiness instrument -- existence (not values) is asserted, keeping
// this test honest on any simulator state.

import XCTest

final class TodayUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTodayScreenRendersAndEditModeAddsRemovesWithPersistence() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestSeedData", "-UITestResetTodayMetrics"]
        app.launch()

        let anyElement = app.descendants(matching: .any)

        // Seeded launches land on the Data tab (DashboardUITests' contract)
        // -- switch to Today via the new tab bar.
        let todayTab = anyElement["tabbar.today"]
        XCTAssertTrue(todayTab.waitForExistence(timeout: 10))
        todayTab.tap()

        // Header sync status (seeded SyncState rows put it in the fresh
        // form), pending readiness hero, coach panel placeholder.
        XCTAssertTrue(anyElement["today.syncStatus"].waitForExistence(timeout: 10))
        XCTAssertTrue(anyElement["today.readiness"].exists)
        XCTAssertTrue(anyElement["today.coachPanel"].exists)

        // Default four metric rows, in the mockup's set.
        for kind in ["heart", "steps", "sleep", "bloodOxygen"] {
            XCTAssertTrue(anyElement["today.metric.\(kind)"].exists, "Missing default metric row \(kind)")
        }

        // In-place edit flow (iOS 27 reorderable-content): add Weight via
        // the MORE METRICS section, remove Sleep via its row button, Done
        // -- the panel reflects both immediately. Drag-reorder itself is
        // covered by unit tests over the difference mapping, not gestures.
        anyElement["today.editButton"].tap()
        let addWeight = anyElement["today.add.weight"]
        XCTAssertTrue(addWeight.waitForExistence(timeout: 10))
        addWeight.tap()
        let removeSleep = anyElement["today.remove.sleep"]
        XCTAssertTrue(removeSleep.exists)
        removeSleep.tap()
        anyElement["today.editButton"].tap()

        XCTAssertTrue(anyElement["today.metric.weight"].waitForExistence(timeout: 5))
        XCTAssertFalse(anyElement["today.metric.sleep"].exists)

        // Hit-region audit over the Today screen (test plan §6).
        // Deliberately NOT the full audit (WP-37 outcome): some 30 probe
        // runs show the beta's contrast verdict neither converges on
        // identical trees (fail/near-pass flip-flops) nor localizes
        // (fails with all content hidden) — see the WP-37 progress entry.
        // Contrast is verified instead by computation (every text pair
        // ≥4.5:1, Theme.swift documents the figures) plus snapshots
        // pinning the rendering the figures describe.
        try app.performAccessibilityAudit(for: [.hitRegion])

        // Persistence across relaunch -- WITHOUT the reset flag this time.
        app.terminate()
        app.launchArguments = ["-UITestSeedData"]
        app.launch()
        XCTAssertTrue(anyElement["tabbar.today"].waitForExistence(timeout: 10))
        anyElement["tabbar.today"].tap()
        XCTAssertTrue(anyElement["today.metric.weight"].waitForExistence(timeout: 10))
        XCTAssertFalse(anyElement["today.metric.sleep"].exists)
    }
}
