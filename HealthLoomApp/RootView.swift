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
//
// WP-50: onboarding runs once. A normal launch starts in the app once
// onboarding has finished on this install (`OnboardingCompletion`); a
// wipe clears that and brings it back.

import SwiftUI

struct RootView: View {
    @State private var isOnboarded: Bool
    private let initialRoute: InitialRoute
    /// `nil` when completion isn't persisted -- every `-UITest*` launch.
    private let completion: OnboardingCompletion?

    /// - Parameter initialRoute: `.default` runs onboarding-then-Today, or
    ///   straight to Today once onboarding has finished (`completion`);
    ///   `.data`/`.coach`/… skip onboarding and land on the named tab
    ///   (UI-test launches only); `.onboardingGoogle` runs onboarding starting
    ///   at the Google consent step (skip-path UI test only).
    /// - Parameter completion: the persisted "onboarding finished" flag, or
    ///   `nil` to ignore it (see `OnboardingCompletion.startsInApp`).
    init(initialRoute: InitialRoute = .default, completion: OnboardingCompletion? = nil) {
        _isOnboarded = State(initialValue: OnboardingCompletion.startsInApp(route: initialRoute, completion: completion))
        self.initialRoute = initialRoute
        self.completion = completion
    }

    var body: some View {
        if isOnboarded {
            HomeView(initialTab: initialRoute.homeTab)
        } else if let startStep = initialRoute.onboardingStep {
            OnboardingFlowView(initialStep: startStep, onFinished: finishOnboarding)
        } else {
            // Unreachable: a route without an onboarding step always starts in
            // the app (`OnboardingCompletion.startsInApp`). Kept as the honest
            // fallback rather than force-unwrapping — a future route mismatch
            // onboards from Welcome.
            OnboardingFlowView(onFinished: finishOnboarding)
        }
    }

    /// The flow's single exit. Persist first, so a crash right after
    /// finishing can't send the user back through onboarding.
    private func finishOnboarding() {
        completion?.markCompleted()
        isOnboarded = true
    }
}

#Preview {
    RootView()
        .environment(AppEnvironment())
}
