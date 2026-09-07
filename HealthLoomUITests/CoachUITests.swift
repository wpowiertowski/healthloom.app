// CoachUITests.swift
//
// WP-25 (implementation-plan.md) "Tests:" line: UI test with a scripted mock
// `CoachSession` (WP-22's seam, `-UITestScriptedCoach`) -- send → stream
// renders → turn persisted → relaunch shows history -- plus unavailable
// state rendering (launched without the flag on this model-less simulator).
//
// The scripted flag deliberately uses the on-disk store (not the in-memory
// container every other UI test forces): the relaunch leg asserts a turn
// persisted across launches shows history, which is unobservable
// in-memory. Each run sends a UUID-marked message and asserts on that
// marker, so turns accumulated by earlier runs can't satisfy the
// assertions.

import XCTest

final class CoachUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testChatStreamsReplyAndPersistsAcrossRelaunch() throws {
        let marker = UUID().uuidString
        let ping = "UITest ping \(marker)"

        let app = XCUIApplication()
        app.launchArguments = ["-UITestScriptedCoach"]
        app.launch()

        // Scripted launches land directly on the Coach tab, input enabled
        // (forced `.available`), tier slot reserved for WP-32.
        let anyElement = app.descendants(matching: .any)
        XCTAssertTrue(anyElement["chat.screen"].waitForExistence(timeout: 10))
        XCTAssertTrue(anyElement["chat.tierSlot"].exists)
        let input = anyElement["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertTrue(input.isEnabled, "input must be enabled in the scripted available state")

        input.tap()
        input.typeText(ping)
        anyElement["chat.send"].tap()

        // The user turn persists immediately...
        XCTAssertTrue(app.staticTexts[ping].waitForExistence(timeout: 10))

        // ...a stream is visibly in flight (stop button present)...
        XCTAssertTrue(anyElement["chat.stop"].waitForExistence(timeout: 10))

        // ...and the scripted reply's chunks join into the full reply.
        XCTAssertTrue(
            app.staticTexts["Scripted coach reply: rest well and hydrate."].waitForExistence(timeout: 10)
        )

        app.terminate()

        // Relaunch with the same flags: the on-disk store kept both turns.
        let relaunched = XCUIApplication()
        relaunched.launchArguments = ["-UITestScriptedCoach"]
        relaunched.launch()

        XCTAssertTrue(relaunched.staticTexts[ping].waitForExistence(timeout: 10))
        XCTAssertTrue(relaunched.staticTexts["Scripted coach reply: rest well and hydrate."].exists)
    }

    @MainActor
    func testTraceExpanderNamesServingTier() throws {
        // WP-30 trace badge (D15.b): the per-message "What did the coach
        // see?" expander names the serving tier persisted on the turn.
        let app = XCUIApplication()
        app.launchArguments = ["-UITestScriptedCoach", "-UITestScrubChat"]
        app.launch()

        let anyElement = app.descendants(matching: .any)
        XCTAssertTrue(anyElement["chat.screen"].waitForExistence(timeout: 10))
        let input = anyElement["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("UITest trace \(UUID().uuidString)")
        anyElement["chat.send"].tap()
        XCTAssertTrue(
            app.staticTexts["Scripted coach reply: rest well and hydrate."].waitForExistence(timeout: 10)
        )
        // Wait for the stream to finish: the reply text above also matches
        // the mid-stream draft, so the stop button's *disappearance* (not
        // the reply's appearance) is the stream-end signal.
        let streamEnd = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: anyElement["chat.stop"]
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [streamEnd], timeout: 30), .completed,
            "stream did not finish"
        )
        // The DisclosureGroup label renders as a static text; tapping it
        // toggles expansion. Scrubbed transcript, so exactly one expander
        // exists and no scroll is needed.
        let expanders = app.staticTexts.matching(NSPredicate(format: "label == %@", "What did the coach see?"))
        XCTAssertEqual(expanders.count, 1, "scrubbed transcript holds exactly this run's turn")
        expanders.firstMatch.tap()
        let tier = anyElement["chat.context.tier"]
        XCTAssertTrue(tier.waitForExistence(timeout: 10))
        XCTAssertTrue(tier.label.contains("On-device"))
    }

    @MainActor
    func testTierMenuOffersEnabledTiers() throws {
        // WP-32 switcher menu: the pccOn scenario enables On-device + PCC
        // (Claude neither consented nor keyed), so the menu offers exactly
        // those two — a tier that cannot serve never appears.
        let app = XCUIApplication()
        app.launchArguments = ["-UITestAIModels=pccOn"]
        app.launch()

        let anyElement = app.descendants(matching: .any)
        anyElement["tabbar.coach"].tap()
        XCTAssertTrue(anyElement["chat.screen"].waitForExistence(timeout: 10))
        anyElement["chat.tierSlot"].tap()
        XCTAssertTrue(anyElement["chat.tier.onDevice"].waitForExistence(timeout: 10))
        XCTAssertTrue(anyElement["chat.tier.privateCloudCompute"].exists)
        XCTAssertFalse(anyElement["chat.tier.claude"].exists)
        XCTAssertFalse(anyElement["chat.tier.gemini"].exists)
        // Picking an offered tier dismisses the menu without error.
        anyElement["chat.tier.privateCloudCompute"].tap()
        XCTAssertFalse(anyElement["chat.tier.onDevice"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testUnavailableStateRenders() throws {
        // `-UITestCoachUnavailable` forces `.modelNotReady`: the iOS 27
        // simulator's on-device model reports `.available` (verified via a
        // debug hierarchy dump), so live unavailability is not producible
        // here and the rendering path takes a forced state -- the same
        // approach as the scripted available path. The test asserts the
        // banner container plus both copy lines (not just existence), and
        // disabled input.
        let app = XCUIApplication()
        app.launchArguments = ["-UITestCoachUnavailable"]
        app.launch()

        let anyElement = app.descendants(matching: .any)
        XCTAssertTrue(anyElement["chat.screen"].waitForExistence(timeout: 10))
        // `ThemedCallout` combines its children into one accessibility
        // element, so both copy lines are asserted on the banner's label
        // rather than as separate static texts.
        let banner = anyElement["chat.unavailable"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        XCTAssertTrue(banner.label.contains("The on-device model is still downloading. Try again shortly."))
        XCTAssertTrue(banner.label.contains("Wait for the download to finish, or use a cloud coach tier once enabled."))
        XCTAssertFalse(anyElement["chat.input"].isEnabled, "input must be disabled while unavailable")
    }
}
