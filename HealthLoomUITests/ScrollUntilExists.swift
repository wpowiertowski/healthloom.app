// ScrollUntilExists.swift
//
// Shared scroll-into-view helper for both UI test suites. Extracted from
// DashboardUITests (which previously had a private `swipeUp()`-based
// version, with OnboardingUITests carrying an inline copy of the same
// loop) when the loop started failing on CI's iOS 27 simulator:
//
// `XCUIApplication.swipeUp()` scrolls roughly a full screen per call. The
// dashboard's List is virtualized (SwiftUI backs it with a
// UICollectionView), and a row that gets flung *past* the viewport is
// evicted from the accessibility tree just like one that was never reached
// -- so a full-screen swipe can jump clean over the row being looked for
// and the loop then keeps swiping further away from it forever. Observed
// on the xcode-27 CI runner (PR #7): `dashboard.row.weight.name` sat just
// below the fold, the first swipe overshot it, and five attempts later the
// test failed while rows *further down* the same List were reachable.
//
// The fix is to scroll in small increments (~30% of the app frame) with
// the existence check between each step, so a row always spends at least
// one check inside the materialized window and overshooting is impossible.
// A drag via coordinates is used instead of `swipeUp(velocity:)` because a
// drag ends with no fling deceleration -- the distance scrolled is exactly
// the distance dragged, keeping the step size deterministic.

import XCTest

extension XCTestCase {
    /// Scrolls `app` upward in small fixed increments until `element` is
    /// hittable (not merely existing -- non-lazy stacks materialize every
    /// row, so existence alone never implies tappability), or gives up
    /// after `maxAttempts`. Same fling-free drag as below.
    @MainActor
    func scrollToHittable(_ element: XCUIElement, in app: XCUIApplication, maxAttempts: Int = 20) {
        var attempts = 0
        while !element.isHittable, attempts < maxAttempts {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            start.press(forDuration: 0.05, thenDragTo: end)
            attempts += 1
        }
    }

    /// Scrolls `app` upward in small fixed increments until `element`
    /// exists, or gives up after `maxAttempts` -- the caller's subsequent
    /// assertion reports the failure. ~0.3 screens per attempt, so the
    /// default covers several screens of content from wherever the previous
    /// call left the scroll position.
    @MainActor
    func scrollUntilExists(_ element: XCUIElement, in app: XCUIApplication, maxAttempts: Int = 20) {
        var attempts = 0
        while !element.exists && attempts < maxAttempts {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            start.press(forDuration: 0.05, thenDragTo: end)
            attempts += 1
        }
    }
}
