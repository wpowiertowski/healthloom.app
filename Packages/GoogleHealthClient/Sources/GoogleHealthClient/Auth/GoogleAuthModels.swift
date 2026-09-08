// GoogleAuthModels.swift
//
// WP-04 (implementation-plan.md): wire shapes for the token and userinfo
// endpoints. These are Google/OpenID-standard response bodies (not something
// base-knowledge.md documents -- that doc is about the Health data API, not
// the generic OAuth token endpoint), so no `_comment` fixture-assumption note
// is needed here the way it is for Health API response fixtures.

import Foundation

/// Outcome of `GoogleAuthManager.revokeRefreshToken` (WP-35).
/// `.nothingStored` is success-with-nothing-to-do (never consented or
/// already wiped) -- never an error, so the wipe never special-cases it.
public enum RevocationOutcome: Equatable, Sendable {
    case revoked
    case nothingStored
}

/// `https://oauth2.googleapis.com/token` response body (standard OAuth 2.0
/// token response, RFC 6749 §5.1).
nonisolated struct TokenResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Double
    let scope: String?
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
        case tokenType = "token_type"
    }
}

/// Error body shape for a non-200 token-endpoint response (RFC 6749 §5.2).
/// `error` is the machine-readable code (`"invalid_grant"`, `"invalid_client"`, ...).
nonisolated struct TokenErrorResponse: Decodable, Sendable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

/// `https://openidconnect.googleapis.com/v1/userinfo` response body. `hd` is
/// present only for Google Workspace (hosted-domain) accounts -- its
/// presence is exactly the Workspace-detection signal WP-04 step 5 asks for.
nonisolated struct UserInfoResponse: Decodable, Sendable {
    let sub: String?
    let email: String?
    let hd: String?
}
