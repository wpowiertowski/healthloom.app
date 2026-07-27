// WorkspaceUnsupportedView.swift
//
// WP-10 (implementation-plan.md step 1) / architecture.md §6: "Workspace
// Google account -- Detected post-consent; clear 'personal accounts only'
// screen; sign-out." `GoogleAuthManager.completeConsent` already clears the
// stored tokens itself before throwing `.workspaceAccountUnsupported`
// (progress.md's WP-04 entry), so this screen only needs to explain the
// state and offer a retry -- there is nothing left here to sign out of.

import SwiftUI

struct WorkspaceUnsupportedView: View {
    var onTryDifferentAccount: () -> Void

    var body: some View {
        // No `step:` -- this is a branch off step 3, not a step of its own.
        OnboardingScaffold(
            symbol: "exclamationmark.triangle",
            title: "Personal Accounts Only",
            message: "The account you signed in with is a Google Workspace (work or school) account. Google's Health API only supports personal Google accounts. Please sign in with a personal account instead.",
            actions: {
                OnboardingSecondaryButton(
                    title: "Try a Different Account",
                    accessibilityIdentifier: "onboarding.workspace.retry",
                    action: onTryDifferentAccount
                )
            }
        )
        // No container-level identifier -- see WelcomeView.swift's note: it
        // would override the more specific `onboarding.workspace.retry`
        // identifier, which is passed into the themed button above and
        // applied directly to its own `Button`.
    }
}

#Preview {
    WorkspaceUnsupportedView(onTryDifferentAccount: {})
}
