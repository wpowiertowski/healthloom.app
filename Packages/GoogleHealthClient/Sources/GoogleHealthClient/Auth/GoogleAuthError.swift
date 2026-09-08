// GoogleAuthError.swift
//
// WP-04 / architecture.md D11: like `Secrets.SecretsError`, every case here
// must be safe to log -- no token, code, or URL-with-code ever appears in an
// associated value or in `description`.

nonisolated public enum GoogleAuthError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Refresh failed with `invalid_grant` (refresh token revoked/expired).
    /// Tokens have already been cleared from storage; the caller should show
    /// the re-consent UI (architecture.md §6).
    case reconsentRequired

    /// The `hd` claim was present on the userinfo response after consent --
    /// a Google Workspace account, which the Health API does not support
    /// (implementation-plan.md P-1.5, architecture.md §6). Tokens have
    /// already been cleared.
    case workspaceAccountUnsupported

    /// No refresh token is stored (never consented, or storage was wiped).
    case missingRefreshToken

    /// The token endpoint returned a non-200, non-`invalid_grant` response.
    /// Carries only the HTTP status.
    case tokenExchangeFailed(status: Int)

    /// The revocation endpoint returned a non-200 (WP-35 disconnect).
    /// Carries only the HTTP status — local state was still cleared.
    case revocationFailed(status: Int)

    /// The userinfo endpoint returned something other than a decodable 200.
    case invalidResponse

    /// The `ASWebAuthenticationSession` redirect URL didn't carry a `code`
    /// for the `state` we sent (missing/mismatched state, or no code at all).
    case invalidRedirect

    /// The user dismissed the consent sheet without completing it.
    case consentCancelled

    /// `GoogleTokenStoring` itself threw (e.g. underlying Keychain failure).
    /// Never carries the underlying error's description, since some
    /// Keychain-layer errors could in principle echo back query parameters.
    case tokenStorageFailure

    /// Transport-level failure (no HTTP response at all). Carries only the
    /// underlying error's *type* name, never its description (which for
    /// `URLError` can include the request URL).
    case transport(String)

    public var description: String {
        switch self {
        case .reconsentRequired: return "GoogleAuthError.reconsentRequired"
        case .workspaceAccountUnsupported: return "GoogleAuthError.workspaceAccountUnsupported"
        case .missingRefreshToken: return "GoogleAuthError.missingRefreshToken"
        case .tokenExchangeFailed(let status): return "GoogleAuthError.tokenExchangeFailed(status: \(status))"
        case .revocationFailed(let status): return "GoogleAuthError.revocationFailed(status: \(status))"
        case .invalidResponse: return "GoogleAuthError.invalidResponse"
        case .invalidRedirect: return "GoogleAuthError.invalidRedirect"
        case .consentCancelled: return "GoogleAuthError.consentCancelled"
        case .tokenStorageFailure: return "GoogleAuthError.tokenStorageFailure"
        case .transport(let typeName): return "GoogleAuthError.transport(\(typeName))"
        }
    }
}
