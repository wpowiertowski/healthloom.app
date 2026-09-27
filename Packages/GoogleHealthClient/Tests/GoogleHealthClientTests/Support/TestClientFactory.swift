// TestClientFactory.swift
//
// Shared construction helpers for GoogleHealthClient (data client) tests.
// Pure decode/encode tests don't need real network at all -- `decodePage`/
// `buildRequest` are internal (test-visible via @testable import) pure
// functions, so most tests construct a client whose HTTPSession would
// `fatalError` if actually invoked, proving the test path never hits it.

import Foundation
@testable import GoogleHealthClient

nonisolated enum TestClientFactory {
    static let authConfig = GoogleAuthConfig(
        clientID: "test-client-id.apps.googleusercontent.com",
        redirectURI: "com.healthloom.app:/oauth2redirect",
        redirectURIScheme: "com.healthloom.app"
    )

    /// A client that must never actually send a request -- for pure decode/
    /// request-building tests.
    static func inertClient(config: GoogleHealthClientConfig = .init()) -> GoogleHealthClient {
        let inertHTTP = RecordingHTTPSession { _, _ in fatalError("no network expected in this test") }
        let auth = GoogleAuthManager(config: authConfig, httpSession: inertHTTP, tokenStore: FakeTokenStore())
        return GoogleHealthClient(config: config, httpSession: inertHTTP, auth: auth)
    }

    /// A query item's value from a request URL.
    static func query(_ name: String, in request: URLRequest) -> String? {
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return components.queryItems?.first { $0.name == name }?.value
    }

    static func tokenJSON(accessToken: String = "data-access-token") -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "access_token": accessToken,
            "expires_in": 3600,
            "token_type": "Bearer",
        ])
    }

    /// A client fully wired to `http` for both the auth token endpoint and
    /// the data endpoint (same session, routed by URL inside `http`'s
    /// handler) -- for pagination/resilience tests that exercise the real
    /// network loop.
    static func client(
        http: RecordingHTTPSession,
        config: GoogleHealthClientConfig = .init(),
        sleeper: any BackoffSleeper = RecordingSleeper(),
        jitter: any JitterSource = ZeroJitterSource()
    ) -> GoogleHealthClient {
        let auth = GoogleAuthManager(
            config: authConfig,
            httpSession: http,
            tokenStore: FakeTokenStore(refreshToken: "refresh-token-for-data-tests")
        )
        return GoogleHealthClient(config: config, httpSession: http, auth: auth, sleeper: sleeper, jitter: jitter)
    }

    static func isTokenRequest(_ request: URLRequest) -> Bool {
        request.url?.absoluteString.contains("oauth2.googleapis.com/token") == true
    }
}
