// GoogleHealthClientConfig.swift
//
// WP-05 (implementation-plan.md) / base-knowledge.md §2: "Base URL:
// https://health.googleapis.com/v4/."

import Foundation

nonisolated public struct GoogleHealthClientConfig: Sendable {
    public var baseURL: String
    public var backoff: BackoffPolicy
    /// The zone civil filter times and daily dates are read in -- the user's,
    /// since the API's civil times are the wearer's local clock.
    public var civilTimeZone: TimeZone

    /// The only base URL production code may use (third-party F13): the
    /// legacy Fitbit Web API host is unrepresentable as a default, and
    /// the reconcile test below proves requests actually go here.
    public static let defaultBaseURL = "https://health.googleapis.com/v4/"

    public init(
        baseURL: String = GoogleHealthClientConfig.defaultBaseURL,
        backoff: BackoffPolicy = BackoffPolicy(),
        civilTimeZone: TimeZone = .current
    ) {
        self.baseURL = baseURL
        self.backoff = backoff
        self.civilTimeZone = civilTimeZone
    }
}
