// WipeUITests.swift
//
// WP-35 (implementation-plan.md) UI coverage: the export row prepares a
// shareable file, and the wipe flow runs end-to-end to its completion
// screen. Step *outcomes* are not asserted here (HealthKit authorization
// on a simulator is undetermined, so the HK row may legitimately fail;
// unit tests pin per-step semantics) — what is deterministic is flow
// completion. The wipe runs against the seeded in-memory container, so
// no store files exist and nothing real is at risk.

import XCTest

final class WipeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func openSettings(_ app: XCUIApplication) -> XCUIElementQuery {
        let anyElement = app.descendants(matching: .any)
        let settingsTab = anyElement["tabbar.settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10))
        settingsTab.tap()
        XCTAssertTrue(anyElement["settings.export.prepare"].waitForExistence(timeout: 10))
        return anyElement
    }

    @MainActor
    func testExportPreparesShareableFile() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestSeedData"]
        app.launch()
        let anyElement = openSettings(app)

        anyElement["settings.export.prepare"].tap()
        XCTAssertTrue(anyElement["settings.export.share"].waitForExistence(timeout: 10))
        XCTAssertFalse(anyElement["settings.export.error"].exists)
    }

    @MainActor
    func testWipeFlowReachesCompletion() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestSeedData"]
        app.launch()
        let anyElement = openSettings(app)

        let wipeOpen = anyElement["settings.wipe.open"]
        var swipes = 0
        while !wipeOpen.isHittable, swipes < 12 {
            if wipeOpen.frame.minY < 0 {
                app.swipeDown()
            } else {
                app.swipeUp()
            }
            swipes += 1
        }
        XCTAssertTrue(wipeOpen.isHittable)
        // Let scroll deceleration finish, then tap until the sheet
        // answers: a tap mid-scroll can land nowhere with no error, so a
        // blind single tap is a flake. Re-query each attempt (never reuse
        // a possibly stale element across scrolls).
        for _ in 0..<3 {
            anyElement["settings.wipe.open"].tap()
            if anyElement["wipe.close"].waitForExistence(timeout: 3) { break }
        }
        XCTAssertTrue(anyElement["wipe.confirm"].waitForExistence(timeout: 10))
        anyElement["wipe.confirm"].tap()

        // Every step runs (success or recorded failure); the flow always
        // lands on a completion screen, never a spinner.
        let done = anyElement["wipe.done"]
        let donePartial = anyElement["wipe.donePartial"]
        let deadline = Date().addingTimeInterval(30)
        while !done.exists, !donePartial.exists, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertTrue(done.exists || donePartial.exists)
        XCTAssertTrue(anyElement["wipe.step.store"].exists)
    }
}
