// GoogleAuthURLTests.swift
//
// WP-04 required test: "token exchange request encoding" (the auth-URL half
// of it: "auth-URL parameter set exact" per test-plan.md §2.4). Also covers
// the redirect-URL code/state extraction the iOS-only consent flow relies on
// -- pure URL parsing, so testable here without any UI.

import CoreModel
import Foundation
import Testing
@testable import GoogleHealthClient

@Suite("GoogleAuthManager authorization URL + redirect parsing")
struct GoogleAuthURLTests {
    private func makeManager() -> GoogleAuthManager {
        GoogleAuthManager(
            config: GoogleAuthConfig(
                clientID: "test-client-id.apps.googleusercontent.com",
                redirectURI: "com.healthloom.app:/oauth2redirect",
                redirectURIScheme: "com.healthloom.app"
            ),
            httpSession: RecordingHTTPSession { _, _ in fatalError("no network expected") },
            tokenStore: FakeTokenStore()
        )
    }

    @Test("authorization URL carries exactly the expected parameter set")
    func authorizationURLParameterSet() {
        let manager = makeManager()
        let url = manager.authorizationURL(
            scopes: [.activityAndFitness, .sleep],
            state: "state-123",
            codeChallenge: "challenge-abc"
        )

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        #expect(components.scheme == "https")
        #expect(components.host == "accounts.google.com")

        var params: [String: String] = [:]
        for item in components.queryItems ?? [] { params[item.name] = item.value }

        #expect(params["client_id"] == "test-client-id.apps.googleusercontent.com")
        #expect(params["redirect_uri"] == "com.healthloom.app:/oauth2redirect")
        #expect(params["response_type"] == "code")
        #expect(params["code_challenge"] == "challenge-abc")
        #expect(params["code_challenge_method"] == "S256")
        #expect(params["access_type"] == "offline")
        #expect(params["include_granted_scopes"] == "true")
        #expect(params["state"] == "state-123")

        let scopeString = params["scope"] ?? ""
        let requestedScopes = Set(scopeString.split(separator: " ").map(String.init))
        #expect(requestedScopes.contains(GoogleOAuthScope.urlString(for: .activityAndFitness)))
        #expect(requestedScopes.contains(GoogleOAuthScope.urlString(for: .sleep)))
        #expect(requestedScopes.contains("openid"))
        #expect(requestedScopes.contains("email"))

        // Exactly the parameter *names* above -- no extras, nothing missing.
        #expect(Set(params.keys) == [
            "client_id", "redirect_uri", "response_type", "scope",
            "code_challenge", "code_challenge_method", "access_type", "include_granted_scopes",
            "prompt", "state",
        ])
    }

    // catches: a hand-built redirect drifting from the client ID -- Google
    // rejects a redirect that isn't the reversed ID of the iOS client.
    @Test("an iOS client's redirect is its reversed client ID")
    func iOSClientRedirectIsReversedClientID() {
        let config = GoogleAuthConfig.iOSClient(clientID: "123-abc.apps.googleusercontent.com")
        #expect(config.clientID == "123-abc.apps.googleusercontent.com")
        #expect(config.redirectURIScheme == "com.googleusercontent.apps.123-abc")
        #expect(config.redirectURI == "com.googleusercontent.apps.123-abc:/oauth2redirect")
    }

    @Test("redirect code extraction requires a matching state and yields the code")
    func extractsCodeWhenStateMatches() {
        let redirect = URL(string: "com.healthloom.app:/oauth2redirect?code=auth-code-xyz&state=expected-state")!
        let code = GoogleAuthManager.extractAuthorizationCode(from: redirect, expectedState: "expected-state")
        #expect(code == "auth-code-xyz")
    }

    @Test("redirect code extraction rejects a mismatched state")
    func rejectsMismatchedState() {
        let redirect = URL(string: "com.healthloom.app:/oauth2redirect?code=auth-code-xyz&state=wrong-state")!
        let code = GoogleAuthManager.extractAuthorizationCode(from: redirect, expectedState: "expected-state")
        #expect(code == nil)
    }

    @Test("redirect code extraction returns nil when there is no code")
    func returnsNilWhenNoCode() {
        let redirect = URL(string: "com.healthloom.app:/oauth2redirect?state=expected-state")!
        let code = GoogleAuthManager.extractAuthorizationCode(from: redirect, expectedState: "expected-state")
        #expect(code == nil)
    }
}
