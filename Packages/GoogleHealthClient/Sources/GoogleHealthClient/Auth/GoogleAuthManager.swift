// GoogleAuthManager.swift
//
// WP-04 (implementation-plan.md): consent, token exchange, silent refresh,
// Workspace detection. Everything in this file is pure/injectable and runs
// on both iOS and macOS (the task brief: "the PKCE math, URL building, token
// exchange, refresh single-flight, and Workspace detection must all be
// pure/injectable and fully tested on macOS"). The one iOS-only piece --
// presenting `ASWebAuthenticationSession` -- lives in
// `GoogleAuthManager+Consent.swift`, guarded `#if os(iOS)`, and calls back
// into `completeConsent(code:codeVerifier:redirectURI:)` below.
//
// Concurrency: an `actor`, matching architecture.md §3's list of
// actor-isolated off-main types. All token state (cached access token,
// expiry, granted scopes, in-flight refresh) is actor-isolated so concurrent
// callers are naturally serialized -- the single-flight refresh (WP-04 step
// 3) falls out of that serialization rather than needing a separate lock.

import CoreModel
import Foundation

public actor GoogleAuthManager {
    /// Cached access token is treated as usable if it has more than this
    /// many seconds left before expiry (WP-04 step 3's "expiry margin").
    static let expiryMargin: TimeInterval = 60

    private let config: GoogleAuthConfig
    private let httpSession: any HTTPSession
    private let tokenStore: any GoogleTokenStoring
    private let clock: any TokenClock

    private var cachedAccessToken: String?
    private var cachedExpiry: Date?
    private(set) var grantedScopes: Set<String> = []

    /// The in-flight refresh, if any. Concurrent callers to `validAccessToken()`
    /// / `forceRefresh()` that find this non-nil await the same `Task` instead
    /// of starting their own refresh (WP-04 step 3: "single-flight").
    private var refreshTask: Task<String, Error>?

    public init(
        config: GoogleAuthConfig,
        httpSession: any HTTPSession,
        tokenStore: any GoogleTokenStoring,
        clock: any TokenClock = SystemTokenClock()
    ) {
        self.config = config
        self.httpSession = httpSession
        self.tokenStore = tokenStore
        self.clock = clock
    }

    /// The set of full scope URLs (`GoogleOAuthScope.urlString`) granted by
    /// the most recent consent/refresh response's `scope` field. Empty until
    /// the first successful consent or refresh in this process (not
    /// persisted across launches -- see progress.md's WP-04 note on this).
    public var currentGrantedScopes: Set<String> { grantedScopes }

    /// Exposed (read-only, nonisolated -- `config` is an immutable `let`) so
    /// the iOS-only `+Consent` extension, in a separate file, can read them
    /// without needing to hop onto the actor.
    nonisolated var redirectURIScheme: String { config.redirectURIScheme }
    nonisolated var redirectURI: String { config.redirectURI }

    // MARK: - Access token

    /// Returns a usable access token, refreshing first if the cached one is
    /// within `expiryMargin` seconds of expiring (or absent).
    public func validAccessToken() async throws(GoogleAuthError) -> String {
        if let token = cachedAccessToken,
           let expiry = cachedExpiry,
           expiry.timeIntervalSince(clock.now()) > Self.expiryMargin {
            return token
        }
        return try await coalescedRefresh()
    }

    /// Forces a refresh regardless of cached expiry. Used by `GoogleHealthClient`
    /// (the data client) after a 401 from the Health API itself -- the server
    /// may reject a token our local expiry math still considers valid (e.g.
    /// server-side revocation), so a 401 always earns one real refresh
    /// attempt (WP-05 step 5).
    func forceRefresh() async throws(GoogleAuthError) -> String {
        try await coalescedRefresh()
    }

    private func coalescedRefresh() async throws(GoogleAuthError) -> String {
        if let existing = refreshTask {
            return try await Self.awaitTyped(existing)
        }
        let task = Task<String, Error> { [self] in
            try await performRefresh()
        }
        refreshTask = task
        // Whichever call created the task is the one that clears it, after
        // its own await completes (success or failure) -- see the file
        // header for why this is race-free under actor isolation.
        do {
            let token = try await Self.awaitTyped(task)
            refreshTask = nil
            return token
        } catch {
            refreshTask = nil
            throw error
        }
    }

    /// `Task<String, Error>.value` is untyped-throwing (this toolchain's
    /// `Task` typed-throws initializer requires `Failure == any Error`
    /// unless constructed with a matching typed-throws operation in a way
    /// this package didn't get to compile cleanly); `performRefresh()`
    /// itself only ever throws `GoogleAuthError`, so this narrows the catch
    /// back to the typed error this actor's API promises.
    private static func awaitTyped(_ task: Task<String, Error>) async throws(GoogleAuthError) -> String {
        do {
            return try await task.value
        } catch let error as GoogleAuthError {
            throw error
        } catch {
            throw .transport(String(describing: type(of: error)))
        }
    }

    private func performRefresh() async throws(GoogleAuthError) -> String {
        guard let refreshToken = try await loadRefreshToken() else {
            throw .missingRefreshToken
        }
        let request = buildTokenRequest(.refreshToken(refreshToken))
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            if let errorBody = try? JSONDecoder().decode(TokenErrorResponse.self, from: data),
               errorBody.error == "invalid_grant" {
                await clearTokens()
                throw .reconsentRequired
            }
            throw .tokenExchangeFailed(status: response.statusCode)
        }
        let decoded = try decodeTokenResponse(data)
        applyTokenResponse(decoded)
        if let newRefreshToken = decoded.refreshToken {
            // Loud, not `try?`: a Keychain write failure (e.g. device locked
            // during a background refresh) must surface as a storage error,
            // not silently leave the superseded token on disk -- every later
            // refresh would then fail `invalid_grant` and sign the user out
            // with no log line explaining why.
            do {
                try await tokenStore.setRefreshToken(newRefreshToken)
            } catch {
                throw GoogleAuthError.tokenStorageFailure
            }
        }
        // Best-effort, deliberately: the access-token Keychain slot is a
        // write-only cache nothing in production reads back (serving comes
        // from the in-memory entry `applyTokenResponse` just set), so a
        // refused write here must not abort an otherwise successful refresh
        // -- the previous loud version failed whole background runs with a
        // valid in-memory token in hand.
        try? await tokenStore.setAccessToken(decoded.accessToken)
        return decoded.accessToken
    }

    private func loadRefreshToken() async throws(GoogleAuthError) -> String? {
        do {
            return try await tokenStore.refreshToken()
        } catch {
            throw .tokenStorageFailure
        }
    }

    private func applyTokenResponse(_ decoded: TokenResponse) {
        cachedAccessToken = decoded.accessToken
        cachedExpiry = clock.now().addingTimeInterval(decoded.expiresIn)
        if let scope = decoded.scope {
            grantedScopes = Set(scope.split(separator: " ").map(String.init))
        }
    }

    private func clearTokens() async {
        cachedAccessToken = nil
        cachedExpiry = nil
        grantedScopes = []
        try? await tokenStore.setRefreshToken(nil)
        try? await tokenStore.setAccessToken(nil)
    }

    // MARK: - Consent completion (called by the iOS-only presentation layer,
    // and directly by tests -- see the file header).

    /// Exchanges an authorization `code` (from the redirect URL) for tokens,
    /// verifies the account is not a Workspace account, and only then stores
    /// anything (WP-04 steps 2 & 5). Throws `.workspaceAccountUnsupported`
    /// (nothing stored) if the account's userinfo carries an `hd` claim --
    /// and a failed userinfo call likewise stores nothing, so a transient
    /// failure can't leave an unverified account fully authenticated.
    func completeConsent(code: String, codeVerifier: String, redirectURI: String) async throws(GoogleAuthError) {
        let request = buildTokenRequest(.authorizationCode(code: code, verifier: codeVerifier, redirectURI: redirectURI))
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw .tokenExchangeFailed(status: response.statusCode)
        }
        let decoded = try decodeTokenResponse(data)
        guard let refreshToken = decoded.refreshToken else {
            throw .missingRefreshToken
        }

        // Verify BEFORE persisting: the userinfo call needs only the
        // in-memory access token. A failure here (transport, invalid
        // response) throws with nothing stored -- the next launch finds no
        // token and re-prompts, instead of syncing an unverified account.
        let info = try await fetchUserInfo(accessToken: decoded.accessToken)
        if info.hd != nil {
            // Wipe first, even though this call stored nothing yet: a stale
            // grant from an earlier session (or an interrupted consent) may
            // still sit in the Keychain, and leaving it means the next
            // launch silently syncs under the old grant instead of landing
            // unauthenticated as this error implies.
            await clearTokens()
            throw .workspaceAccountUnsupported
        }

        applyTokenResponse(decoded)
        do {
            try await tokenStore.setRefreshToken(refreshToken)
        } catch {
            await clearTokens()
            throw GoogleAuthError.tokenStorageFailure
        }
        // Best-effort (see `performRefresh`): the session is fully usable
        // from the in-memory token; a refused Keychain write just means the
        // next launch refreshes from the stored refresh token again.
        try? await tokenStore.setAccessToken(decoded.accessToken)
    }

    /// Revokes the stored refresh token (WP-35 disconnect-and-wipe).
    /// Sends the RFC 7009 revocation request, then clears local state
    /// (actor cache + token store) in ALL cases -- a network failure still
    /// leaves nothing locally, and the wipe's keychain step clears the
    /// same keys again for defense in depth. Callers continue the wipe on
    /// `.revocationFailed` (log only); the token is already unusable.
    public func revokeRefreshToken() async throws(GoogleAuthError) -> RevocationOutcome {
        let stored: String?
        do {
            stored = try await tokenStore.refreshToken()
        } catch {
            throw .tokenStorageFailure
        }
        guard let refreshToken = stored else { return .nothingStored }
        defer {
            cachedAccessToken = nil
            cachedExpiry = nil
            grantedScopes = []
        }
        let (_, response) = try await send(buildRevocationRequest(refreshToken))
        do {
            try await tokenStore.setRefreshToken(nil)
            try await tokenStore.setAccessToken(nil)
        } catch {
            throw .tokenStorageFailure
        }
        guard response.statusCode == 200 else { throw .revocationFailed(status: response.statusCode) }
        return .revoked
    }

    /// Builds the RFC 7009 revocation POST. `nonisolated` like
    /// `buildTokenRequest` so the encoding golden test calls it directly.
    /// Takes the token as a parameter (never read from the store here) so
    /// the request carries exactly what the caller revoked -- and the token
    /// itself never appears in logs (see `GoogleAuthError`'s header).
    nonisolated func buildRevocationRequest(_ refreshToken: String) -> URLRequest {
        var request = URLRequest(url: URL(string: config.revocationEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formURLEncode(["token": refreshToken]).utf8)
        return request
    }

    private func fetchUserInfo(accessToken: String) async throws(GoogleAuthError) -> UserInfoResponse {
        guard let url = URL(string: config.userInfoEndpoint) else { throw .invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else { throw .invalidResponse }
        do {
            return try JSONDecoder().decode(UserInfoResponse.self, from: data)
        } catch {
            throw .invalidResponse
        }
    }

    // MARK: - Incremental scopes (WP-04 step 4)

    /// Health scopes from `requested` not already present in
    /// `grantedScopes`. Pure/testable; the iOS-only `ensure(scopes:)`
    /// (see +Consent) uses this to decide whether consent needs presenting.
    func missingHealthScopes(from requested: [GoogleDataType.Scope]) -> Set<GoogleDataType.Scope> {
        Set(requested.filter { !grantedScopes.contains(GoogleOAuthScope.urlString(for: $0)) })
    }

    // MARK: - Authorization URL (WP-04 step 2)

    /// Builds the `accounts.google.com` authorization-request URL. Pure/
    /// testable; only touches `config` (an immutable `let`), so it's safe as
    /// `nonisolated`.
    nonisolated func authorizationURL(scopes: [GoogleDataType.Scope], state: String, codeChallenge: String) -> URL {
        var components = URLComponents(string: config.authorizationEndpoint)!
        let scopeString = (scopes.map { GoogleOAuthScope.urlString(for: $0) } + config.additionalScopes)
            .joined(separator: " ")
        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopeString),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    /// Parses the OAuth redirect URL's `code`/`state` query items, requiring
    /// `state` to match what we sent (CSRF protection). Pure/testable; no UI
    /// dependency at all.
    nonisolated static func extractAuthorizationCode(from redirectURL: URL, expectedState: String) -> String? {
        guard let components = URLComponents(url: redirectURL, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              let state = items.first(where: { $0.name == "state" })?.value,
              state == expectedState
        else {
            return nil
        }
        return items.first(where: { $0.name == "code" })?.value
    }

    // MARK: - Token endpoint request encoding (WP-04 step 2/3)

    enum GrantRequest {
        case authorizationCode(code: String, verifier: String, redirectURI: String)
        case refreshToken(String)
    }

    /// Builds the `application/x-www-form-urlencoded` POST to the token
    /// endpoint. `nonisolated` (only touches immutable `config`) so the
    /// request-encoding golden test can call it directly without `await`.
    nonisolated func buildTokenRequest(_ grant: GrantRequest) -> URLRequest {
        var request = URLRequest(url: URL(string: config.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var params: [String: String] = ["client_id": config.clientID]
        switch grant {
        case .authorizationCode(let code, let verifier, let redirectURI):
            params["code"] = code
            params["code_verifier"] = verifier
            params["grant_type"] = "authorization_code"
            params["redirect_uri"] = redirectURI
        case .refreshToken(let refreshToken):
            params["refresh_token"] = refreshToken
            params["grant_type"] = "refresh_token"
        }
        request.httpBody = Data(Self.formURLEncode(params).utf8)
        return request
    }

    private nonisolated static func formURLEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return params.sorted { $0.key < $1.key }
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
    }

    // MARK: - Networking helpers

    private func send(_ request: URLRequest) async throws(GoogleAuthError) -> (Data, HTTPURLResponse) {
        do {
            return try await httpSession.send(request)
        } catch {
            throw .transport(String(describing: type(of: error)))
        }
    }

    private func decodeTokenResponse(_ data: Data) throws(GoogleAuthError) -> TokenResponse {
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw .invalidResponse
        }
    }
}
