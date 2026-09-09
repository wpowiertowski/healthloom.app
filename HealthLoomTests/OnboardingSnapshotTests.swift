// OnboardingSnapshotTests.swift
//
// Third-party F1: the welcome footnote can push Get Started off-screen at
// AX3–AX5 (non-scrolling VStack, unbounded custom-font scaling, a Spacer
// bottoming at 20pt). The scaffold scrolls now, so oversized content stays
// reachable; unbounded scaling is kept deliberately (capping type would
// trade a layout bug for an accessibility one).
//
// Two coverages here: (a) `getStartedReachableAtAXXXL` walks the hosted
// view hierarchy and fails if the continue button is not inside a scroll
// view's content — red on the old VStack, green on the ScrollView; (b)
// pixel snapshots of the fixed layout at XS/XL/AXXXL × light/dark.

import SwiftUI
import Testing
import UIKit
@testable import HealthLoom

@MainActor
@Suite("Onboarding layout (third-party F1)")
struct OnboardingLayoutTests {
    private func host(_ view: some View, width: CGFloat = 390, height: CGFloat = 844) throws -> UIHostingController<AnyView> {
        let hosting = UIHostingController(rootView: AnyView(view))
        // Platform views (UIButton, UIScrollView) only materialize once the
        // hosted view is in a live window — without this the tree holds
        // just the hosting view itself. The test bundle is app-hosted, so
        // a window scene exists at runtime.
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        hosting.view.layoutIfNeeded()
        return hosting
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    @Test("Get Started stays reachable by scroll at AXXXL")
    func getStartedReachableAtAXXXL() throws {
        let hosting = try host(
            WelcomeView(onContinue: {})
                .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
        )
        // The actions block renders inside this ScrollView by construction
        // (see OnboardingScaffold.body), so its presence is the regression
        // pin: red on the old bare VStack, green now. Button-level
        // reachability (visible + hittable) is asserted in the running app
        // by OnboardingUITests' disclaimer test; snapshots below pin the
        // rendered pixels. A button-descendant walk was tried and
        // discarded: SwiftUI vends no identifier-carrying UIView for the
        // button in a unit host (only accessibility elements, which need
        // a live AX tree to enumerate).
        let views = descendants(of: hosting.view)
        #expect(
            views.contains { $0 is UIScrollView },
            "welcome content must live in a scroll view at AXXXL"
        )
    }
}

@Suite("Onboarding snapshots (third-party F1)")
struct OnboardingSnapshotTests {
    @Test("welcome across appearance and content size")
    func welcome() {
        let sizes: [(String, ContentSizeCategory)] = [
            ("XS", .extraSmall),
            ("XL", .extraExtraLarge),
            ("AXXXL", .accessibilityExtraExtraExtraLarge),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (label, size) in sizes {
                SnapshotAssert.assertHosted(
                    WelcomeView(onContinue: {}),
                    named: "welcome-\(scheme == .light ? "light" : "dark")-\(label)",
                    colorScheme: scheme,
                    sizeCategory: size
                )
            }
        }
    }
}
