// GoogleAuthManagerTests.swift
//
// WP-04 required tests (implementation-plan.md): token exchange request
// encoding; refresh single-flight (10 concurrent callers ⇒ 1 refresh
// request); expiry margin honored; `invalid_grant` ⇒ `.reconsentRequired`;
// Workspace `hd` claim detection. All run against `FakeTokenStore` +
// `RecordingHTTPSession` -- no real network, no real Keychain (task brief).

import CoreModel
import Foundation
import Secrets
import Testing
@testable import GoogleHealthClient

private actor CallCounter {
    private(set) var count = 0
    @discardableResult
    func increment() -> Int {
        count += 1
        return count
    }
}

@Suite("GoogleAuthManager")
struct GoogleAuthManagerTests {
    static let testConfig = GoogleAuthConfig(
        clientID: "test-client-id.apps.googleusercontent.com",
        redirectURI: "com.healthloom.app:/oauth2redirect",
        redirectURIScheme: "com.healthloom.app"
    )

    nonisolated private static func tokenResponseJSON(
        accessToken: String,
        refreshToken: String? = nil,
        expiresIn: Double = 3600,
        scope: String? = nil
    ) -> Data {
        var dict: [String: Any] = [
            "access_token": accessToken,
            "expires_in": expiresIn,
            "token_type": "Bearer",
        ]
        if let refreshToken { dict["refresh_token"] = refreshToken }
        if let scope { dict["scope"] = scope }
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    nonisolated private static func parseFormBody(_ data: Data) -> [String: String] {
        let string = String(data: data, encoding: .utf8) ?? ""
        guard !string.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for pair in string.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            result[String(parts[0]).removingPercentEncoding ?? String(parts[0])] =
                String(parts[1]).removingPercentEncoding ?? String(parts[1])
        }
        return result
    }

    // MARK: - Token exchange request encoding

    @Test("authorization-code token exchange encodes exactly the expected form fields")
    func authorizationCodeRequestEncoding() {
        let manager = GoogleAuthManager(
            config: Self.testConfig,
            httpSession: RecordingHTTPSession { _, _ in fatalError("no network expected") },
            tokenStore: FakeTokenStore()
        )
        let request = manager.buildTokenRequest(
            .authorizationCode(code: "auth-code-1", verifier: "verifier-1", redirectURI: "com.healthloom.app:/oauth2redirect")
        )

        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(request.url?.absoluteString == "https://oauth2.googleapis.com/token")

        let body = Self.parseFormBody(request.httpBody ?? Data())
        #expect(body == [
            "client_id": "test-client-id.apps.googleusercontent.com",
            "code": "auth-code-1",
            "code_verifier": "verifier-1",
            "grant_type": "authorization_code",
            "redirect_uri": "com.healthloom.app:/oauth2redirect",
        ])
    }

    @Test("refresh-token exchange encodes exactly the expected form fields")
    func refreshTokenRequestEncoding() {
        let manager = GoogleAuthManager(
            config: Self.testConfig,
            httpSession: RecordingHTTPSession { _, _ in fatalError("no network expected") },
            tokenStore: FakeTokenStore()
        )
        let request = manager.buildTokenRequest(.refreshToken("refresh-abc"))

        let body = Self.parseFormBody(request.httpBody ?? Data())
        #expect(body == [
            "client_id": "test-client-id.apps.googleusercontent.com",
            "refresh_token": "refresh-abc",
            "grant_type": "refresh_token",
        ])
    }

    // MARK: - Refresh single-flight

    @Test("10 concurrent validAccessToken() calls with no cached token trigger exactly one refresh request")
    func refreshSingleFlight() async throws {
        let http = RecordingHTTPSession { _, _ in
            (Self.tokenResponseJSON(accessToken: "access-token-1"), httpResponse(statusCode: 200))
        }
        let manager = GoogleAuthManager(
            config: Self.testConfig,
            httpSession: http,
            tokenStore: FakeTokenStore(refreshToken: "refresh-abc")
        )

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 {
                group.addTask { try await manager.validAccessToken() }
            }
            var results: [String] = []
            for try await token in group { results.append(token) }
            return results
        }

        #expect(tokens.count == 10)
        #expect(Set(tokens) == ["access-token-1"])
        let requestCount = await http.requests.count
        #expect(requestCount == 1)
    }

    // MARK: - Expiry margin

    @Test("cached token is reused while >60s from expiry, refreshed once inside the margin")
    func expiryMarginHonored() async throws {
        let clock = ManualClock(Date(timeIntervalSince1970: 1_000_000))
        let counter = CallCounter()
        let http = RecordingHTTPSession { _, _ in
            let n = await counter.increment()
            return (Self.tokenResponseJSON(accessToken: "token-\(n)", expiresIn: 3600), httpResponse(statusCode: 200))
        }
        let manager = GoogleAuthManager(
            config: Self.testConfig,
            httpSession: http,
            tokenStore: FakeTokenStore(refreshToken: "refresh-abc"),
            clock: clock
        )

        let first = try await manager.validAccessToken()
        #expect(first == "token-1")

        // 100s elapsed of a 3600s token: 3500s remaining, well outside the
        // 60s margin -> cached token reused, no second refresh.
        clock.advance(by: 100)
        let second = try await manager.validAccessToken()
        #expect(second == "token-1")
        var count = await counter.count
        #expect(count == 1)

        // Advance so only ~30s remain -- inside the 60s margin -> must refresh.
        clock.advance(by: 3600 - 100 - 30)
        let third = try await manager.validAccessToken()
        #expect(third == "token-2")
        count = await counter.count
        #expect(count == 2)
    }

    // MARK: - invalid_grant

    @Test("invalid_grant on refresh clears tokens and throws .reconsentRequired")
    func invalidGrantThrowsReconsentRequired() async throws {
        let tokenStore = FakeTokenStore(refreshToken: "revoked-refresh", accessToken: "stale-access")
        let http = RecordingHTTPSession { _, _ in
            let body = try! JSONSerialization.data(withJSONObject: [
                "error": "invalid_grant",
                "error_description": "Token has been expired or revoked.",
            ])
            return (body, httpResponse(statusCode: 400))
        }
        let manager = GoogleAuthManager(config: Self.testConfig, httpSession: http, tokenStore: tokenStore)

        do {
            _ = try await manager.validAccessToken()
            Issue.record("Expected .reconsentRequired to be thrown")
        } catch {
            // `validAccessToken()` is `throws(GoogleAuthError)`, so `error`
            // is already narrowed to the concrete type here.
            #expect(error == .reconsentRequired)
        }

        let remainingRefresh = try await tokenStore.refreshToken()
        let remainingAccess = try await tokenStore.accessToken()
        #expect(remainingRefresh == nil)
        #expect(remainingAccess == nil)
    }

    // MARK: - Workspace `hd` claim detection

    @Test("consent completion detects a Workspace account via the hd claim and clears tokens")
    func workspaceDetectionViaHDClaim() async throws {
        let tokenStore = FakeTokenStore()
        let http = RecordingHTTPSession { request, _ in
            if request.url!.absoluteString.contains("oauth2.googleapis.com/token") {
                return (
                    Self.tokenResponseJSON(accessToken: "access-1", refreshToken: "refresh-1", scope: "openid email"),
                    httpResponse(statusCode: 200)
                )
            } else {
                let body = try! JSONSerialization.data(withJSONObject: [
                    "sub": "12345", "email": "user@example.com", "hd": "example.com",
                ])
                return (body, httpResponse(statusCode: 200))
            }
        }
        let manager = GoogleAuthManager(config: Self.testConfig, httpSession: http, tokenStore: tokenStore)

        do {
            try await manager.completeConsent(code: "auth-code", codeVerifier: "verifier", redirectURI: Self.testConfig.redirectURI)
            Issue.record("Expected .workspaceAccountUnsupported to be thrown")
        } catch {
            #expect(error == .workspaceAccountUnsupported)
        }

        let remainingRefresh = try await tokenStore.refreshToken()
        #expect(remainingRefresh == nil)
    }

    @Test("consent completion succeeds normally for a personal account (no hd claim)")
    func personalAccountConsentSucceeds() async throws {
        let tokenStore = FakeTokenStore()
        let http = RecordingHTTPSession { request, _ in
            if request.url!.absoluteString.contains("oauth2.googleapis.com/token") {
                return (
                    Self.tokenResponseJSON(accessToken: "access-1", refreshToken: "refresh-1", scope: "openid email"),
                    httpResponse(statusCode: 200)
                )
            } else {
                let body = try! JSONSerialization.data(withJSONObject: ["sub": "12345", "email": "user@example.com"])
                return (body, httpResponse(statusCode: 200))
            }
        }
        let manager = GoogleAuthManager(config: Self.testConfig, httpSession: http, tokenStore: tokenStore)

        try await manager.completeConsent(code: "auth-code", codeVerifier: "verifier", redirectURI: Self.testConfig.redirectURI)

        let storedRefresh = try await tokenStore.refreshToken()
        #expect(storedRefresh == "refresh-1")
    }

    @Test("consent completion stores nothing when userinfo verification fails")
    func userinfoFailureStoresNothing() async throws {
        // Token exchange succeeds, then userinfo fails transiently: the
        // pre-fix code had already persisted the refresh token, leaving an
        // unverified account fully authenticated on next launch.
        let tokenStore = FakeTokenStore()
        let http = RecordingHTTPSession { request, _ in
            if request.url!.absoluteString.contains("oauth2.googleapis.com/token") {
                return (
                    Self.tokenResponseJSON(accessToken: "access-1", refreshToken: "refresh-1", scope: "openid email"),
                    httpResponse(statusCode: 200)
                )
            } else {
                return (Data(), httpResponse(statusCode: 500))
            }
        }
        let manager = GoogleAuthManager(config: Self.testConfig, httpSession: http, tokenStore: tokenStore)

        await #expect {
            try await manager.completeConsent(code: "auth-code", codeVerifier: "verifier", redirectURI: Self.testConfig.redirectURI)
        } throws: { _ in true }

        #expect(try await tokenStore.refreshToken() == nil)
        #expect(try await tokenStore.accessToken() == nil)
    }

    // MARK: - Incremental scopes

    @Test("missingHealthScopes reflects scopes granted by the most recent refresh")
    func missingHealthScopesAfterRefresh() async throws {
        let grantedScope = GoogleOAuthScope.urlString(for: .activityAndFitness)
        let http = RecordingHTTPSession { _, _ in
            (Self.tokenResponseJSON(accessToken: "a", scope: grantedScope), httpResponse(statusCode: 200))
        }
        let manager = GoogleAuthManager(config: Self.testConfig, httpSession: http, tokenStore: FakeTokenStore(refreshToken: "r"))
        _ = try await manager.validAccessToken()

        let missingBefore = await manager.missingHealthScopes(from: [.activityAndFitness, .sleep])
        #expect(missingBefore == [.sleep])
        let missingNone = await manager.missingHealthScopes(from: [.activityAndFitness])
        #expect(missingNone.isEmpty)
    }

    // MARK: - Redaction tripwire (test-plan.md §2.4)

    @Test("no GoogleAuthError description ever contains the refresh token or authorization code")
    func errorsNeverLeakSecrets() async throws {
        let secretToken = "super-secret-refresh-token-value"
        let secretCode = "super-secret-auth-code-value"

        let tokenStore = FakeTokenStore(refreshToken: secretToken)
        let http = RecordingHTTPSession { _, _ in
            let body = try! JSONSerialization.data(withJSONObject: ["error": "invalid_grant"])
            return (body, httpResponse(statusCode: 400))
        }
        let manager = GoogleAuthManager(config: Self.testConfig, httpSession: http, tokenStore: tokenStore)

        do {
            _ = try await manager.validAccessToken()
        } catch {
            #expect(!error.description.contains(secretToken))
            #expect(!error.description.contains(secretCode))
        }

        // Redirect-extraction failure path: state mismatch, code present in URL.
        let redirect = URL(string: "com.healthloom.app:/oauth2redirect?code=\(secretCode)&state=wrong")!
        let extracted = GoogleAuthManager.extractAuthorizationCode(from: redirect, expectedState: "expected")
        #expect(extracted == nil)
    }

    // MARK: - Thin Keychain adapter (compile-time conformance only -- see
    // KeychainStore+GoogleTokenStoring.swift's header for why this package
    // doesn't attempt a real-Keychain I/O test).

    @Test("KeychainStore conforms to GoogleTokenStoring")
    func keychainStoreConformsToGoogleTokenStoring() {
        let store: any GoogleTokenStoring = KeychainStore()
        _ = store
    }
// MARK: - Revocation (WP-35 disconnect)

    @Test("revocation request encodes the token against the revoke endpoint")
    func revocationRequestEncoding() {
        let manager = GoogleAuthManager(
            config: Self.testConfig,
            httpSession: RecordingHTTPSession { _, _ in fatalError("no network expected") },
            tokenStore: FakeTokenStore()
        )
        let request = manager.buildRevocationRequest("refresh-xyz")
        #expect(request.url?.absoluteString == "https://oauth2.googleapis.com/revoke")
        #expect(request.httpMethod == "POST")
        let body = Self.parseFormBody(request.httpBody ?? Data())
        #expect(body == ["token": "refresh-xyz"])
    }

    @Test("successful revocation clears the store and reports revoked")
    func revocationClearsStore() async throws {
        let http = RecordingHTTPSession { request, _ in
            (Data(), httpResponse(url: request.url!, statusCode: 200))
        }
        let store = FakeTokenStore(refreshToken: "refresh-abc", accessToken: "stale-access")
        let manager = GoogleAuthManager(config: Self.testConfig, httpSession: http, tokenStore: store)
        #expect(try await manager.revokeRefreshToken() == .revoked)
        #expect(await http.requestCount(urlContains: "oauth2.googleapis.com/revoke") == 1)
        #expect(try await store.refreshToken() == nil)
        #expect(try await store.accessToken() == nil)
    }

    @Test("nothing stored is success without a request")
    func revocationNothingStored() async throws {
        let http = RecordingHTTPSession { _, _ in fatalError("no network expected") }
        let manager = GoogleAuthManager(config: Self.testConfig, httpSession: http, tokenStore: FakeTokenStore())
        #expect(try await manager.revokeRefreshToken() == .nothingStored)
        #expect(await http.requestCount(urlContains: "revoke") == 0)
    }

    @Test("non-200 revocation still clears locally and reports the status")
    func revocationFailureStillClears() async throws {
        let http = RecordingHTTPSession { request, _ in
            (Data(), httpResponse(url: request.url!, statusCode: 400))
        }
        let store = FakeTokenStore(refreshToken: "refresh-abc")
        let manager = GoogleAuthManager(config: Self.testConfig, httpSession: http, tokenStore: store)
        await #expect(throws: GoogleAuthError.revocationFailed(status: 400)) {
            try await manager.revokeRefreshToken()
        }
        #expect(try await store.refreshToken() == nil)
    }
}
