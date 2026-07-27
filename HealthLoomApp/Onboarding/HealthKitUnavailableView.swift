// HealthKitUnavailableView.swift
//
// WP-10 (implementation-plan.md step 1): the explicit HealthKit-unavailable
// state ("HKHealthStore.isHealthDataAvailable() false, e.g. iPad"). A
// terminal, informational screen -- HealthLoom's entire premise is writing
// into Apple Health, so there is no meaningful "continue anyway" path.
// `project.yml` restricts P0's `TARGETED_DEVICE_FAMILY` to iPhone only, so
// this state is not reachable from the App Store build today, but the
// WP-06/WP-10 briefs both require it to exist and degrade gracefully rather
// than crash or hang on a silent spinner if it ever is.

import SwiftUI

struct HealthKitUnavailableView: View {
    var body: some View {
        // No `step:` -- a dead end isn't a step on the four-step path.
        OnboardingScaffold(
            symbol: "xmark.octagon",
            title: "Apple Health Isn't Available",
            message: "This device doesn't support Apple Health, so HealthLoom can't import your Fitbit or Pixel Watch data here. Try HealthLoom on a compatible iPhone."
        )
        // Safe to identify the container here, unlike the other onboarding
        // screens: this is a terminal, actionless screen with no more
        // specific child identifier for it to override (see
        // WelcomeView.swift's note).
        .accessibilityIdentifier("onboarding.healthKitUnavailable")
    }
}

#Preview {
    HealthKitUnavailableView()
}
