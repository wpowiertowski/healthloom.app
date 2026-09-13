// RootView.swift
//
// WP-10 (implementation-plan.md): the app's root router -- onboarding until
// completed, the main app after. Replaces WP-01's placeholder `ContentView`.
//
// WP-33: post-onboarding now routes to `HomeView` (the Yacht club tab
// shell, Today/HomeView.swift) instead of bare `DashboardView`. The
// pre-existing `startOnDashboard` launch flag (`-UITestSeedData`, see
// LaunchConfiguration.swift) keeps both of its jobs -- skip onboarding
// *and* land on the sync dashboard -- by selecting the Data tab as the
// initial tab, so `DashboardUITests`' seeded launches still find
// `dashboard.syncNow` immediately, no test churn. A normal launch lands
// on Today.

import SwiftUI

struct RootView: View {
    @State private var isOnboarded: Bool
    private let initialRoute: InitialRoute

    /// - Parameter initialRoute: `.default` runs onboarding-then-Today;
    ///   `.data`/`.coach`/… skip onboarding and land on the named tab
    ///   (UI-test launches only); `.onboardingGoogle` runs onboarding starting
    ///   at the Google consent step (skip-path UI test only).
    init(initialRoute: InitialRoute = .default) {
        _isOnboarded = State(initialValue: initialRoute.onboardingStep == nil)
        self.initialRoute = initialRoute
    }

    var body: some View {
        if isOnboarded {
            HomeView(initialTab: initialRoute.homeTab)
        } else if let startStep = initialRoute.onboardingStep {
            OnboardingFlowView(initialStep: startStep, onFinished: { isOnboarded = true })
        } else {
            // Unreachable: `isOnboarded` is true exactly when `onboardingStep` is
            // nil (see `init`). Kept as the honest fallback rather than force-
            // unwrapping — a future route mismatch onboards from Welcome.
            OnboardingFlowView(onFinished: { isOnboarded = true })
        }
    }
}

#Preview {
    RootView()
        .environment(AppEnvironment())
}
