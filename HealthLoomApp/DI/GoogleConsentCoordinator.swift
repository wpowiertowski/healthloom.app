// GoogleConsentCoordinator.swift
//
// WP-10 (implementation-plan.md): app-level seam over
// `GoogleAuthManager.beginConsent` so onboarding's Google-consent screen
// depends on a small, app-owned protocol rather than the concrete actor
// directly. This is what lets `-UITestStubGoogle` substitute a stub that
// never presents `ASWebAuthenticationSession` or touches the network
// (test-plan.md §5), while the real path (`LiveGoogleConsentCoordinator`)
// talks to the real Google Cloud iOS OAuth client (P-1.3,
// `AppEnvironment.googleAuthConfig`).
//
// Real API discovered here (progress.md's WP-04 entry,
// `GoogleAuthManager+Consent.swift`): `beginConsent` is `@MainActor`,
// iOS-only (`#if os(iOS)`), and requires an
// `ASWebAuthenticationPresentationContextProviding`; it throws typed
// `GoogleAuthError`, whose `.workspaceAccountUnsupported` /
// `.consentCancelled` cases are exactly the two non-generic-failure states
// architecture.md §6 and this WP's brief call out by name.

import AuthenticationServices
import CoreModel
import GoogleHealthClient
import UIKit

/// Onboarding's narrow view of "sign in with Google" -- framed around the
/// exact states architecture.md §6 and implementation-plan.md WP-10 call
/// out: success, Workspace-account-unsupported, user-cancelled, or a generic
/// failure to render inline.
@MainActor
protocol GoogleConsentCoordinating: AnyObject {
    func beginConsent(scopes: [GoogleDataType.Scope]) async -> OnboardingConsentResult
}

enum OnboardingConsentResult: Equatable, Sendable {
    case success
    case workspaceUnsupported
    case cancelled
    case failure(String)
}

/// Real implementation: presents the actual `ASWebAuthenticationSession` via
/// `GoogleAuthManager.beginConsent(scopes:presentationContextProvider:)`
/// and maps its typed `GoogleAuthError` onto `OnboardingConsentResult`.
@MainActor
final class LiveGoogleConsentCoordinator: NSObject, GoogleConsentCoordinating {
    private let authManager: GoogleAuthManager

    init(authManager: GoogleAuthManager) {
        self.authManager = authManager
    }

    func beginConsent(scopes: [GoogleDataType.Scope]) async -> OnboardingConsentResult {
        do {
            try await authManager.beginConsent(scopes: scopes, presentationContextProvider: self)
            return .success
        } catch {
            // `beginConsent` is `throws(GoogleAuthError)` (typed throws), so
            // `error` here is already `GoogleAuthError` -- no `as` cast needed.
            switch error {
            case .workspaceAccountUnsupported: return .workspaceUnsupported
            case .consentCancelled: return .cancelled
            default: return .failure(error.description)
            }
        }
    }
}

extension LiveGoogleConsentCoordinator: ASWebAuthenticationPresentationContextProviding {
    /// `ASWebAuthenticationSession` calls this on the main thread (Apple's
    /// documented behavior), but the protocol requirement itself is not
    /// actor-isolated -- with this app target's `SWIFT_DEFAULT_ACTOR_ISOLATION:
    /// MainActor` setting (project.yml), a plain implementation here would
    /// otherwise be implicitly MainActor-isolated and fail to satisfy the
    /// (non-isolated) protocol requirement. `MainActor.assumeIsolated` bridges
    /// the documented main-thread guarantee into this MainActor-isolated
    /// type without needing an `await` the synchronous protocol can't provide.
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let keyWindow = scenes.flatMap(\.windows).first(where: { $0.isKeyWindow }) {
                return keyWindow
            }
            // `ASPresentationAnchor()` (bare `UIWindow()`) is deprecated in
            // iOS 26 ("Use init(windowScene:) instead") -- fall back to a
            // fresh window on *some* connected scene rather than the
            // sceneless initializer. This only runs while the app is
            // foregrounded to present consent UI, so a connected scene is
            // always expected to exist.
            guard let scene = scenes.first else {
                preconditionFailure("No UIWindowScene available to anchor ASWebAuthenticationSession")
            }
            return UIWindow(windowScene: scene)
        }
    }
}

/// Stub used only under `-UITestStubGoogle` (LaunchConfiguration.swift):
/// always succeeds after a short, deterministic delay, never presents a web
/// view, never touches the network -- keeps the onboarding happy-path UI
/// test fast and hermetic (test-plan.md §5's explicit "stub layers" design).
@MainActor
final class StubGoogleConsentCoordinator: GoogleConsentCoordinating {
    func beginConsent(scopes: [GoogleDataType.Scope]) async -> OnboardingConsentResult {
        try? await Task.sleep(for: .milliseconds(200))
        return .success
    }
}
