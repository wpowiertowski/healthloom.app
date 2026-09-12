// GoogleConsentView.swift
//
// WP-10 (implementation-plan.md): onboarding step 3 of 4 -- calls
// `AppEnvironment.consentCoordinator.beginConsent(scopes:)`
// (`GoogleConsentCoordinator.swift`), which is either the real
// `LiveGoogleConsentCoordinator` (presents `ASWebAuthenticationSession` via
// `GoogleAuthManager.beginConsent`) or, under `-UITestStubGoogle`, the
// hermetic `StubGoogleConsentCoordinator` -- this view has no idea which one
// it's talking to, by design.
//
// Scopes requested: the union of every P0 type's `GoogleDataType.Scope`
// (steps/heartRate -> activityAndFitness/healthMetrics, weight ->
// healthMetrics, sleep -> sleep), matching `HealthKitAuth.p0WriteTypes`'s
// data-type set rather than hand-duplicating it.

import CoreModel
import SwiftUI

struct GoogleConsentView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    var onWorkspaceUnsupported: () -> Void
    var onSuccess: () -> Void
    /// Secondary escape hatch (onboarding-skip-Google): testers/users without a
    /// Google account proceed without OAuth. Reports intent only — the caller
    /// persists the skip (`GoogleConnectionSetting`) and routes forward.
    var onSkip: () -> Void = {}

    @State private var isConsenting = false
    @State private var errorMessage: String?

    var body: some View {
        OnboardingScaffold(
            step: .google,
            symbol: "person.badge.key",
            title: "Connect Google",
            message: "Sign in with the personal Google account linked to your Fitbit or Pixel Watch. Google Workspace (work or school) accounts aren't supported."
        ) {
            if let errorMessage {
                OnboardingErrorPanel(
                    message: errorMessage,
                    accessibilityIdentifier: "onboarding.google.error"
                )
                .padding(.top, 20)
            }
        } actions: {
            OnboardingPrimaryButton(
                title: "Sign in with Google",
                isLoading: isConsenting,
                accessibilityIdentifier: "onboarding.google.signIn",
                action: beginConsent
            )
            .disabled(isConsenting)
            OnboardingSecondaryButton(
                title: "Continue without Google",
                accessibilityIdentifier: "onboarding.google.skip",
                action: onSkip
            )
            .disabled(isConsenting)
        }
        // No container-level identifier -- see WelcomeView.swift's note:
        // it would override the more specific `onboarding.google.signIn`/
        // `.error` identifiers, which are passed into the themed components
        // above and applied directly to their own leaf views.
    }

    private func beginConsent() {
        isConsenting = true
        errorMessage = nil
        let scopes = Array(Set(AppEnvironment.p0Types.map(\.scope)))
        Task {
            let result = await appEnvironment.consentCoordinator.beginConsent(scopes: scopes)
            isConsenting = false
            switch result {
            case .success:
                onSuccess()
            case .workspaceUnsupported:
                onWorkspaceUnsupported()
            case .cancelled:
                break
            case .failure(let message):
                errorMessage = message
            }
        }
    }
}

#Preview {
    GoogleConsentView(onWorkspaceUnsupported: {}, onSuccess: {})
        .environment(AppEnvironment())
}
