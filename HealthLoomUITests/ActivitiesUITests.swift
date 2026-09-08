// ActivitiesUITests.swift
//
// WP-12b (implementation-plan.md) "Tests:" line: "UI test for the
// consolidated Activities entry with seeded data." Same `-UITestSeedData`
// machinery as DashboardUITests (see that file's header):
// `AppEnvironment.seedDashboardFixtures` seeds one deferred Fitbit exercise
// session (`seed-exercise-1`, a `LocalSample` with a
// `linkedWatchWorkoutUUID`) into the in-memory container. The simulator's
// HealthKit store contributes no workouts, so the entry renders through the
// documented unlinked-session fallback (ActivitiesModels.swift) -- the
// watch-primary + inline-supplement composition is covered at the unit
// level by `ActivityConsolidatorTests`, which can fabricate workouts; this
// test proves the screen itself is reachable and renders a consolidated
// entry from seeded data.

import XCTest

final class ActivitiesUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testActivitiesScreenRendersSeededConsolidatedEntry() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestSeedData"]
        app.launch()

        let anyElement = app.descendants(matching: .any)
        XCTAssertTrue(anyElement["dashboard.syncNow"].waitForExistence(timeout: 10))

        // The Activities link sits below the dashboard's other sections --
        // scroll the virtualized List until it materializes (same reasoning
        // as DashboardUITests' own scrolling).
        let link = anyElement["dashboard.activities.link"]
        var attempts = 0
        while !link.exists && attempts < 10 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(link.exists)
        link.tap()

        // seed-exercise-1: a 40-min Fitbit run, deferred to a (seeded,
        // unreadable) watch workout -- one consolidated entry, titled from
        // the session payload's activity type, sourced "Fitbit Air".
        let title = anyElement["activities.row.seed-exercise-1.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.label, "Run")

        let detail = anyElement["activities.row.seed-exercise-1.detail"]
        XCTAssertTrue(detail.exists)
        XCTAssertTrue(detail.label.contains("Fitbit Air"))
        XCTAssertTrue(detail.label.contains("40 min"))
        // WP-37: hit-region audit over the Activities screen (test plan §6).
        try app.performAccessibilityAudit(for: [.hitRegion])
    }
}
