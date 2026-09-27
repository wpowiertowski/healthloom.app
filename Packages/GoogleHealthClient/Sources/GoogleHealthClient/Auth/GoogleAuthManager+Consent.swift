// GoogleAuthManager+Consent.swift
//
// WP-04 step 2 (implementation-plan.md): presents `ASWebAuthenticationSession`
// to run the actual consent UI. This is the one part of WP-04 that is
// genuinely iOS UI and cannot run in a headless `swift test` process on
// macOS -- guarded so `swift test` on macOS stays green (task brief). Every
// other piece of the consent flow (PKCE, the authorization URL, the token
// exchange, Workspace detection) lives in the cross-platform
// `GoogleAuthManager.swift` and is fully unit-tested there.

#if os(iOS)
import AuthenticationServices
import CoreModel
import Foundation

extension GoogleAuthManager {
    /// Presents the Google consent UI, exchanges the resulting authorization
    /// code for tokens, stores the refresh token, and runs Workspace
    /// detection. Throws `.consentCancelled` if the user dismisses the sheet,
    /// `.invalidRedirect` if the callback doesn't carry a matching `code`.
    @MainActor
    public func beginConsent(
        scopes: [GoogleDataType.Scope],
        presentationContextProvider: any ASWebAuthenticationPresentationContextProviding
    ) async throws(GoogleAuthError) {
        let verifier = PKCE.generateCodeVerifier()
        let challenge = PKCE.codeChallenge(for: verifier)
        let state = PKCE.generateState()
        // `authorizationURL` and the `redirectURI*` properties are
        // `nonisolated` (they only read the immutable `config`), so no actor
        // hop -- and no `await` -- is needed for these three calls.
        let url = authorizationURL(scopes: scopes, state: state, codeChallenge: challenge)
        let scheme = redirectURIScheme

        let callbackURL: URL
        do {
            callbackURL = try await Self.presentWebAuthenticationSession(
                url: url,
                callbackURLScheme: scheme,
                presentationContextProvider: presentationContextProvider
            )
        } catch {
            throw .consentCancelled
        }

        guard let code = Self.extractAuthorizationCode(from: callbackURL, expectedState: state) else {
            throw .invalidRedirect
        }
        try await completeConsent(code: code, codeVerifier: verifier, redirectURI: redirectURI)
    }

    /// Triggers consent for exactly the scopes in `scopes` not already
    /// granted (WP-04 step 4: "`ensure(scopes:)` triggers consent only for
    /// missing ones"). Returns `true` if nothing was missing (no UI shown).
    @MainActor
    @discardableResult
    public func ensure(
        scopes: [GoogleDataType.Scope],
        presentationContextProvider: any ASWebAuthenticationPresentationContextProviding
    ) async throws(GoogleAuthError) -> Bool {
        let missing = await missingHealthScopesAfterLoadingGrants(from: scopes)
        guard !missing.isEmpty else { return true }
        try await beginConsent(scopes: Array(missing), presentationContextProvider: presentationContextProvider)
        return false
    }

    @MainActor
    private static func presentWebAuthenticationSession(
        url: URL,
        callbackURLScheme: String,
        presentationContextProvider: any ASWebAuthenticationPresentationContextProviding
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackURLScheme) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: error ?? GoogleAuthError.consentCancelled)
                }
            }
            session.presentationContextProvider = presentationContextProvider
            session.prefersEphemeralWebBrowserSession = true
            session.start()
        }
    }
}
#endif
