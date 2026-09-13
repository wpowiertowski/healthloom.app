// OnboardingFlowView.swift
//
// WP-10 (implementation-plan.md step 1): "welcome -> HealthKit permission ->
// Google consent -> first sync. Include the Workspace-unsupported and
// HK-unavailable states." Plain, explicit state machine -- no navigation
// stack needed since onboarding is strictly linear except for two
// dead-end/retry branches (architecture.md §6).

import SwiftUI

/// Onboarding-skip-Google: the skip is representable HERE, not as a loose `Bool` some
/// path forgets. `firstSync` carries whether Google was skipped: the consented leg
/// passes `false` (syncs P0 from Google); the skip leg passes `true` (honest
/// Google-less copy, no `syncAll` call). Exhaustive `switch` keeps every leg honest.
enum OnboardingStep: Equatable {
    case welcome
    case healthKitPermission
    case healthKitUnavailable
    case googleConsent
    case workspaceUnsupported
    case firstSync(googleSkipped: Bool)
}

struct OnboardingFlowView: View {
    @State private var step: OnboardingStep
    var onFinished: () -> Void

    /// Test-only entry step (`-UITestOnboardingGoogle` lands on consent, bypassing
    /// the out-of-process HealthKit sheet the UI suite cannot drive). Production
    /// always starts at `.welcome` (the default).
    init(initialStep: OnboardingStep = .welcome, onFinished: @escaping () -> Void) {
        _step = State(initialValue: initialStep)
        self.onFinished = onFinished
    }

    var body: some View {
        Group {
            switch step {
            case .welcome:
                WelcomeView(onContinue: { step = .healthKitPermission })
            case .healthKitPermission:
                HealthKitPermissionView(
                    onUnavailable: { step = .healthKitUnavailable },
                    onGranted: { step = .googleConsent }
                )
            case .healthKitUnavailable:
                HealthKitUnavailableView()
            case .googleConsent:
                GoogleConsentView(
                    onWorkspaceUnsupported: { step = .workspaceUnsupported },
                    onSuccess: { step = .firstSync(googleSkipped: false) },
                    // Skip leg: persist FIRST (single source), then forward with the
                    // flag carried structurally — `firstSync` cannot render without it.
                    onSkip: {
                        GoogleConnectionSetting().setSkipped()
                        step = .firstSync(googleSkipped: true)
                    }
                )
            case .workspaceUnsupported:
                WorkspaceUnsupportedView(onTryDifferentAccount: { step = .googleConsent })
            case .firstSync(let googleSkipped):
                FirstSyncView(googleSkipped: googleSkipped, onFinished: onFinished)
            }
        }
        // WP-37: step transitions animate unless Reduce Motion is on —
        // an explicit `.animation` does not follow the reduce-motion
        // setting on its own (only system transitions do).
        .animation(.default, value: animatedStep)
    }

    /// Nil when Reduce Motion is on, suppressing the transition above.
    private var animatedStep: OnboardingStep? {
        reduceMotion ? nil : step
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
}
