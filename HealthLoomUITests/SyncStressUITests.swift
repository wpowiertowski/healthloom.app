// SyncStressUITests.swift
//
// WP-69: reproduces the owner's watchdog kill -- switching tabs while a
// sync runs hung Today. `-HLStressVolume` gives the sync realistic
// per-minute Active Minutes / Zone Minutes volume and seeds 60 days of that
// history, with the production-only monitors left on (no `-UITest`
// prefix); this drives Data -> Settings -> Data -> Today during the sync
// and times each arrival on Today.

import XCTest

final class SyncStressUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testTodayStaysResponsiveWhileSyncing() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HLStressVolume"]
        app.launch()
        let anyElement = app.descendants(matching: .any)

        let syncNow = anyElement["dashboard.syncNow"]
        XCTAssertTrue(syncNow.waitForExistence(timeout: 60))
        syncNow.tap()

        var arrivals: [TimeInterval] = []
        for _ in 0..<8 {
            anyElement["tabbar.settings"].tap()
            anyElement["tabbar.data"].tap()
            let started = Date()
            anyElement["tabbar.today"].tap()
            XCTAssertTrue(anyElement["today.editButton"].waitForExistence(timeout: 30))
            arrivals.append(Date().timeIntervalSince(started))
        }
        let summary = arrivals.map { String(format: "%.2f", $0) }.joined(separator: ", ")
        print("STRESS Today arrivals (s): \(summary)")
        XCTAssertLessThan(arrivals.max() ?? 0, 3, "Today took \(summary) s to appear during a sync")
    }
}
