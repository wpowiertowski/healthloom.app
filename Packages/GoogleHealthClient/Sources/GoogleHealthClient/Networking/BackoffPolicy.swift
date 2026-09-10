// BackoffPolicy.swift
//
// WP-05 step 5 (implementation-plan.md): "on 429/5xx → exponential backoff
// with jitter (base 1s, cap 60s, max 5 attempts) then throw; honor
// Retry-After if present." Timing must be testable (per the task brief: "a
// clock/sleeper abstraction rather than calling Task.sleep directly"), so the
// actual `Task.sleep` call and the jitter's randomness are both behind
// injectable protocols. Tests inject a `BackoffSleeper` that records the
// requested durations without actually waiting (a "virtual clock") and a
// `JitterSource` that returns a fixed fraction, making the exact backoff
// schedule assertable.

import Foundation

/// Sleeps for a computed backoff duration. Production sleeps for real;
/// tests record durations and return immediately.
nonisolated public protocol BackoffSleeper: Sendable {
    nonisolated func sleep(seconds: Double) async throws
}

/// Production sleeper: a real `Task.sleep`.
nonisolated public struct SystemSleeper: BackoffSleeper {
    public init() {}
    public func sleep(seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

/// Supplies the random jitter fraction mixed into each backoff delay.
/// Production is genuinely random; tests inject a fixed value so the
/// resulting delay schedule is an exact, assertable sequence.
nonisolated public protocol JitterSource: Sendable {
    /// A value in `0..<1`. `0` means "no jitter added" (see
    /// `BackoffPolicy.delay(forAttempt:retryAfter:jitterFraction:)`).
    nonisolated func nextFraction() -> Double
}

/// Production jitter source: uniformly random in `0..<1`.
nonisolated public struct SystemJitterSource: JitterSource {
    public init() {}
    public func nextFraction() -> Double { Double.random(in: 0..<1) }
}

/// The 429/5xx retry schedule (WP-05 step 5). Exponential with a cap, plus a
/// bounded random jitter multiplier so many clients backing off at once don't
/// retry in lockstep. A server-supplied `Retry-After` always wins outright
/// over the computed schedule — the server knows its own recovery time
/// better than our guess.
nonisolated public struct BackoffPolicy: Sendable, Equatable {
    public var baseDelay: Double
    public var capDelay: Double
    public var maxAttempts: Int
    /// Upper bound on the jitter multiplier: delay is scaled by
    /// `1 + jitterFraction * jitterMaxFraction`, so with the default 0.25 the
    /// final delay is the base exponential value plus up to 25% extra.
    public var jitterMaxFraction: Double

    public init(
        baseDelay: Double = 1.0,
        capDelay: Double = 60.0,
        maxAttempts: Int = 5,
        jitterMaxFraction: Double = 0.25
    ) {
        self.baseDelay = baseDelay
        self.capDelay = capDelay
        self.maxAttempts = maxAttempts
        self.jitterMaxFraction = jitterMaxFraction
    }

    /// Delay (seconds) before retrying after a failed `attempt` (1-based:
    /// the attempt that just failed). `retryAfter`, when the server sent
    /// one, wins over the exponential schedule — but CLAMPED to
    /// `capDelay` (round-7 item 8): honored verbatim, a `Retry-After:
    /// 86400` parks a foreground Sync Now for a day (stuck spinner,
    /// kill-app-only recovery). The server's signal still wins WITHIN
    /// the cap.
    public func delay(forAttempt attempt: Int, retryAfter: Double?, jitterFraction: Double) -> Double {
        if let retryAfter {
            return min(max(0, retryAfter), capDelay)
        }
        let exponential = baseDelay * pow(2.0, Double(attempt - 1))
        let capped = min(exponential, capDelay)
        return capped * (1.0 + jitterFraction * jitterMaxFraction)
    }
}
