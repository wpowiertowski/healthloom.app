// GoogleAuthConfig.swift
//
// WP-04 (implementation-plan.md): everything environment/client-specific
// about the OAuth flow, gathered in one injectable value so tests never
// depend on a real Google Cloud OAuth client existing (P-1.3, still a human
// prerequisite -- see progress.md).

import Foundation

nonisolated public struct GoogleAuthConfig: Sendable {
    /// The iOS OAuth client ID issued by Google Cloud (P-1.3). No client
    /// secret: installed-app / native clients authenticate via PKCE only.
    public var clientID: String

    /// Redirect URI registered with the OAuth client. Google's guidance for
    /// iOS installed-app clients is the reversed-client-ID custom scheme
    /// (e.g. `com.googleusercontent.apps.XXXX:/oauth2redirect`); WP-01 left a
    /// placeholder scheme (`com.healthloom.app`) pending the real client
    /// (progress.md WP-01 note (4)). Keep `redirectURI` and
    /// `redirectURIScheme` reconciled with whatever the real client issues.
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
}
