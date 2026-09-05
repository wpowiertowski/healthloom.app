// GoogleHealthClientError.swift
//
// WP-05 (implementation-plan.md): typed errors for the data client. Like
// `GoogleAuthError`, never carries a bearer token; only status codes and
// short, fixed descriptions.

nonisolated public enum GoogleHealthClientError: Error, Sendable, Equatable {
    /// A request failed with 401 even after one forced token refresh + retry
    /// (WP-05 step 5), or `GoogleAuthManager` itself could not produce a
    /// token.
    case unauthorized

    /// 429 persisted through `BackoffPolicy.maxAttempts` attempts.
    case rateLimited

    /// 5xx persisted through `BackoffPolicy.maxAttempts` attempts, or any
    /// other non-2xx/401/429/5xx status.
    case server(status: Int)

    /// The response body wasn't valid/expected JSON. Carries a short, fixed
    /// reason string -- never the raw payload (which could echo request
    /// content back) or any part of the request.
    case decodingFailed(String)

    /// No HTTP response was produced at all (offline, DNS failure, ...).
    /// Carries only the underlying error's type name.
    case transport(String)

    /// The request was cancelled (e.g. `BGAppRefreshTask.expirationHandler`)
    /// while backing off. A dedicated case -- not `.transport` -- so
    /// callers (and the sync log) can tell "asked to stop" apart from "the
    /// network failed". This toolchain's typed-`throws` does not admit a
    /// bare `CancellationError`, so cancellation surfaces as this instead
    /// of being swallowed by `try?`.
    case cancelled
}
