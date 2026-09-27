// GoogleAuthConfig.swift
//
// WP-04 (implementation-plan.md): everything environment/client-specific
// about the OAuth flow, gathered in one injectable value so tests never
// depend on the real Google Cloud OAuth client. The app builds its config
// with `iOSClient(clientID:)` from the real client (P-1.3, created
// 2026-09-27), which derives the redirect from the ID.

import Foundation

nonisolated public struct GoogleAuthConfig: Sendable {
    /// The iOS OAuth client ID issued by Google Cloud (P-1.3). No client
    /// secret: installed-app / native clients authenticate via PKCE only.
    public var clientID: String

    /// Redirect URI registered with the OAuth client. For an iOS client it's
    /// the reversed-client-ID custom scheme
    /// (`com.googleusercontent.apps.XXXX:/oauth2redirect`) -- build it with
    /// `iOSClient(clientID:)` rather than by hand, so it can't drift from the
    /// ID. The app's `CFBundleURLSchemes` must list the same scheme.
    public var redirectURI: String

    /// The URL scheme portion of `redirectURI`, passed to
    /// `ASWebAuthenticationSession(url:callbackURLScheme:completionHandler:)`.
    public var redirectURIScheme: String

    public var authorizationEndpoint: String
    public var tokenEndpoint: String

    /// RFC 7009 revocation endpoint (WP-35 disconnect).
    public var revocationEndpoint: String

    /// Google's OpenID Connect userinfo endpoint -- queried once after first
    /// consent to read the `hd` (hosted domain) claim for Workspace-account
    /// detection (WP-04 step 5). Requires the `openid`/`email` scopes to be
    /// present on the token (see `additionalScopes`).
    public var userInfoEndpoint: String

    /// Scopes requested alongside the caller's Google Health scopes on every
    /// consent, needed only to make the userinfo/`hd`-claim call meaningful.
    /// Not a health scope; not shown to `ensure(scopes:)`'s incremental-scope
    /// bookkeeping (see `GoogleAuthManager.missingHealthScopes`).
    public var additionalScopes: [String]

    public init(
        clientID: String,
        redirectURI: String,
        redirectURIScheme: String,
        authorizationEndpoint: String = "https://accounts.google.com/o/oauth2/v2/auth",
        tokenEndpoint: String = "https://oauth2.googleapis.com/token",
        revocationEndpoint: String = "https://oauth2.googleapis.com/revoke",
        userInfoEndpoint: String = "https://openidconnect.googleapis.com/v1/userinfo",
        additionalScopes: [String] = ["openid", "email"]
    ) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.redirectURIScheme = redirectURIScheme
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.revocationEndpoint = revocationEndpoint
        self.userInfoEndpoint = userInfoEndpoint
        self.additionalScopes = additionalScopes
    }

    /// The config for a Google iOS OAuth client, from its client ID alone:
    /// Google's iOS convention is a redirect on the reversed client ID
    /// (`com.googleusercontent.apps.<id>:/oauth2redirect`, one slash).
    public static func iOSClient(clientID: String) -> GoogleAuthConfig {
        let scheme = reversedClientIDScheme(for: clientID)
        return GoogleAuthConfig(
            clientID: clientID,
            redirectURI: "\(scheme):/oauth2redirect",
            redirectURIScheme: scheme
        )
    }

    /// `123-abc.apps.googleusercontent.com` → `com.googleusercontent.apps.123-abc`.
    public static func reversedClientIDScheme(for clientID: String) -> String {
        let suffix = ".apps.googleusercontent.com"
        let id = clientID.hasSuffix(suffix) ? String(clientID.dropLast(suffix.count)) : clientID
        return "com.googleusercontent.apps.\(id)"
    }
}
