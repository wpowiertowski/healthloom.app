// WelcomeView.swift
//
// WP-10 (implementation-plan.md): onboarding step 1 of 4.
//
// Originally plain SwiftUI on the assumption that "Yacht club design lands
// in WP-33" (this WP's own scope note). WP-33 shipped scoped to the Today
// view only and never reached onboarding, so the design language now comes
// from `OnboardingScaffold.swift` -- see that file's header for the full
// account of the gap and of what is ported vs. derived.

import SwiftUI

struct WelcomeView: View {
    var onContinue: () -> Void

    var body: some View {
        OnboardingScaffold(
            step: .welcome,
            symbol: "heart.text.square",
            title: "Welcome to HealthLoom",
            message: "HealthLoom brings your Fitbit or Pixel Watch data -- steps, heart rate, weight, and sleep -- into Apple Health, so all your health data lives in one place.",
            actions: {
                OnboardingPrimaryButton(
                    title: "Get Started",
                    accessibilityIdentifier: "onboarding.welcome.continue",
                    action: onContinue
                )
            }
        )
        // No container-level identifier here: applying
        // `.accessibilityIdentifier` on the container was observed (via a
        // real `xcodebuild test` run) to override/replace the more specific
        // `onboarding.welcome.continue` identifier set on the button, rather
        // than coexisting with it -- see SyncTypeRow.swift's longer note on
        // the same behavior, first found there. `OnboardingPrimaryButton`
        // takes the identifier as a parameter and applies it directly to its
        // `Button` for the same reason.
    }
}

#Preview {
    WelcomeView(onContinue: {})
}
