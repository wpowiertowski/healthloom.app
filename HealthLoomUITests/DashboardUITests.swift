// DashboardUITests.swift
//
// WP-10 (implementation-plan.md): "dashboard renders per-type states from a
// seeded in-memory container." `-UITestSeedData` (see
// HealthLoomApp/DI/LaunchConfiguration.swift) skips onboarding entirely and
// seeds an in-memory `CoreModel.makeContainer(inMemory: true)` with
// `SyncState` rows spanning ok / error / idle-never-synced
// (`AppEnvironment.seedDashboardFixtures`) before the first frame renders --
// no real HealthKit or Google call happens in this test at all.
//
// WP-14 (implementation-plan.md): the same seeding function also inserts
// `LocalSample` rows for the four P1 local-only types (ECG, Active Zone
// Minutes, Active Minutes, Irregular Rhythm Notification); `testDashboard
// RendersNotInAppleHealthBadgesForLocalOnlyTypes` below asserts the "Not in
// Apple Health" section renders off that seeded data, including that only
// the two clinical types (ECG/IRN) show the additional clinical indicator.

import XCTest

final class DashboardUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDashboardRendersPerTypeStatesFromSeededContainer() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestSeedData"]
        app.launch()

        let anyElement = app.descendants(matching: .any)

        XCTAssertTrue(anyElement["dashboard.syncNow"].waitForExistence(timeout: 10))

        // The data-freshness header (architecture.md §1's "synced 9m ago" /
        // ~15 min framing) is present. Asserted here, before any scrolling:
        // it's the very first section, and (WP-14) the List now has more
        // total content below it (a second "Not in Apple Health" section),
        // so scrolling far enough to reach the `sleep` row further down can
        // evict this row's cell from the virtualized List's materialized
        // window -- asserting up top, right after launch, avoids coupling
        // this check to how much content happens to exist below it.
        XCTAssertTrue(anyElement["dashboard.freshnessHeader"].exists)

        // steps: seeded "ok", 4213 items.
        XCTAssertTrue(anyElement["dashboard.row.steps.name"].waitForExistence(timeout: 5))
        XCTAssertEqual(anyElement["dashboard.row.steps.itemCount"].label, "4213")
        XCTAssertFalse(anyElement["dashboard.row.steps.error"].exists)

        // heart_rate: seeded "ok", 812 items.
        XCTAssertTrue(anyElement["dashboard.row.heart_rate.name"].exists)
        XCTAssertEqual(anyElement["dashboard.row.heart_rate.itemCount"].label, "812")

        // The List is lazily rendered (SwiftUI backs it with a
        // UICollectionView) -- the freshness header + section header push
        // the last two P0 rows below the fold on first layout, so their
        // accessibility elements don't exist until scrolled into view.
        // Observed directly against the real simulator run: `weight`/`sleep`
        // were simply absent from the accessibility snapshot before
        // scrolling. Scrolling happens in small increments (see
        // ScrollUntilExists.swift) so the row can't be overshot and evicted.
        scrollUntilExists(anyElement["dashboard.row.weight.name"], in: app)

        // weight: seeded "idle" (never synced) -- no error row, "Never synced" text.
        XCTAssertTrue(anyElement["dashboard.row.weight.name"].exists)
        XCTAssertEqual(anyElement["dashboard.row.weight.lastSynced"].label, "Never synced")
        XCTAssertFalse(anyElement["dashboard.row.weight.error"].exists)

        scrollUntilExists(anyElement["dashboard.row.sleep.name"], in: app)

        // sleep: seeded "error" with a specific message -- must render, not
        // vanish (architecture.md's "errors render rather than vanish").
        XCTAssertTrue(anyElement["dashboard.row.sleep.name"].exists)
        XCTAssertTrue(anyElement["dashboard.row.sleep.error"].waitForExistence(timeout: 5))
        XCTAssertEqual(
            anyElement["dashboard.row.sleep.error"].label,
            "Google 429: rate limited - will retry automatically"
        )
    }

    /// WP-14 (implementation-plan.md) "Tests:" line's UI-test requirement:
    /// "verifying the badge renders for a seeded LocalSample row." Launches
    /// fresh (separately from the P0-states test above, matching XCTest's
    /// one-launch-per-test convention) with the same `-UITestSeedData`
    /// container, which now also seeds one `LocalSample` per P1 local-only
    /// type (`AppEnvironment.seedDashboardFixtures`).
    @MainActor
    func testDashboardRendersNotInAppleHealthBadgesForLocalOnlyTypes() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestSeedData"]
        app.launch()

        let anyElement = app.descendants(matching: .any)
        XCTAssertTrue(anyElement["dashboard.syncNow"].waitForExistence(timeout: 10))

        // The "Not in Apple Health" section sits below the four P0 rows --
        // scroll until each row is materialized (same virtualized-List
        // reasoning as the P0 test above).
        scrollUntilExists(anyElement["dashboard.localRow.electrocardiogram.name"], in: app)

        // ECG: clinical -- both badges render.
        XCTAssertTrue(anyElement["dashboard.localRow.electrocardiogram.name"].exists)
        XCTAssertEqual(anyElement["dashboard.localRow.electrocardiogram.badge"].label, "Not in Apple Health")
        XCTAssertTrue(anyElement["dashboard.localRow.electrocardiogram.clinicalBadge"].exists)
        XCTAssertEqual(anyElement["dashboard.localRow.electrocardiogram.itemCount"].label, "1")

        // Irregular Rhythm Notification: clinical -- both badges render.
        scrollUntilExists(anyElement["dashboard.localRow.irregular_rhythm_notification.name"], in: app)
        XCTAssertTrue(anyElement["dashboard.localRow.irregular_rhythm_notification.name"].exists)
        XCTAssertEqual(
            anyElement["dashboard.localRow.irregular_rhythm_notification.badge"].label,
            "Not in Apple Health"
        )
        XCTAssertTrue(anyElement["dashboard.localRow.irregular_rhythm_notification.clinicalBadge"].exists)

        // Active Zone Minutes: not clinical -- "Not in Apple Health" badge
        // only, no clinical indicator.
        scrollUntilExists(anyElement["dashboard.localRow.active_zone_minutes.name"], in: app)
        XCTAssertTrue(anyElement["dashboard.localRow.active_zone_minutes.name"].exists)
        XCTAssertEqual(anyElement["dashboard.localRow.active_zone_minutes.badge"].label, "Not in Apple Health")
        // WP-37: hit-region audit over the Dashboard screen (test plan §6).
        try app.performAccessibilityAudit(for: [.hitRegion])
        XCTAssertFalse(anyElement["dashboard.localRow.active_zone_minutes.clinicalBadge"].exists)

        // Active Minutes: not clinical -- same as Active Zone Minutes.
        scrollUntilExists(anyElement["dashboard.localRow.active_minutes.name"], in: app)
        XCTAssertTrue(anyElement["dashboard.localRow.active_minutes.name"].exists)
        XCTAssertEqual(anyElement["dashboard.localRow.active_minutes.badge"].label, "Not in Apple Health")
        XCTAssertFalse(anyElement["dashboard.localRow.active_minutes.clinicalBadge"].exists)
    }

}
