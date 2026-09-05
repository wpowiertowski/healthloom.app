// PCCQuota.swift
//
// WP-28a (implementation-plan.md): Private Cloud Compute quota state
// (architecture.md D14.3). The framework's `QuotaUsage` is 27-SDK-only, so
// -- like the rest of WP-27/28's provider seam -- the enum is plain Swift
// (both toolchains) and only the mapping sits behind `#if swift(>=6.4)`.

import Foundation

/// PCC daily-quota state as the orchestrator sees it.
public enum PCCQuota: Sendable, Equatable {
    /// Quota remains; dispatch normally.
    case ok
    /// Approaching the per-user daily limit: dispatch, but the UI says so
    /// (the reply carries the warning bit, D14.3).
    case nearLimit(resetDate: Date?)
    /// At the limit: the turn falls back to on-device (D14.3), surfacing
    /// `resetDate` when the framework provides one.
    case exhausted(resetDate: Date?)
}

/// Decision table, framework-free so it tests ungated on both matrix
/// toolchains: limit-reached dominates (exhausted even when the status
/// payload lags), otherwise approaching-limit distinguishes near-limit
/// from ok.
extension PCCQuota {
    public init(isLimitReached: Bool, isApproachingLimit: Bool, resetDate: Date? = nil) {
        if isLimitReached {
            self = .exhausted(resetDate: resetDate)
        } else if isApproachingLimit {
            self = .nearLimit(resetDate: resetDate)
        } else {
            self = .ok
        }
    }
}

#if swift(>=6.4)
    import FoundationModels

    extension PCCQuota {
        /// Thin adapter over the decision table (same SDK availability as
        /// the mapped type). Untestable by construction on this SDK -- the
        /// framework publishes no public `QuotaUsage` init, so tests cover
        /// the table above and this delegates.
        @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
        @available(tvOS, unavailable)
        public init(_ usage: PrivateCloudComputeLanguageModel.QuotaUsage) {
            self.init(
                isLimitReached: usage.isLimitReached,
                isApproachingLimit: {
                    guard case .belowLimit(let below) = usage.status else { return false }
                    return below.isApproachingLimit
                }(),
                resetDate: usage.resetDate
            )
        }
    }
#endif
