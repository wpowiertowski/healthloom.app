// CoachError.swift
//
// WP-27 (implementation-plan.md step 2): normalized coach failure -- the
// framework's `LanguageModelError` cases plus provider-specific errors,
// mapped onto UI-renderable cases. The UI switches on this enum, never on
// SDK error types, so WP-28's new providers extend the mapping without
// touching call sites.
//
// Split across the toolchain gate like the rest of WP-27: the enum itself
// is plain Swift (both toolchains); the `LanguageModelError` mapping sits
// behind `#if swift(>=6.4)` because that declaration doesn't exist in the
// macOS 26 SDK (see ModelTier.swift's header). Provider-specific mappings
// (`ClaudeError.missingCredential`, Gemini config errors) land in WP-28.

import Foundation

/// Everything a coach turn can fail with, normalized for the UI.
/// `Equatable` is synthesized (every payload is `Equatable`) so the
/// error-normalization table tests compare values directly.
public enum CoachError: Error, Sendable, Equatable {
    /// The tier can't run right now (gate off, not live, consent/key
    /// missing). `reason` renders verbatim -- same posture as
    /// `TierAvailability`'s string reason.
    case tierUnavailable(tier: ModelTier, reason: String)
    /// A key-gated tier was invoked without its Keychain key (defense in
    /// depth: the catalog gate should have stopped this first).
    case missingCredential(tier: ModelTier)
    /// The assembled context overflowed the model's window. `offerEscalation`
    /// is true only when a bigger tier exists to offer (D14.2) -- the
    /// orchestrator sets it, the UI renders the offer, the user decides.
    /// Never auto-switches.
    case contextOverflow(offerEscalation: Bool)
    /// Provider rate limit / quota. `retryAfter` nil means unknown.
    case rateLimited(retryAfter: Date?)
    case requestTimeout
    /// The model's safety systems refused (guardrail violation or refusal).
    /// Rendered as a neutral decline -- never the raw debug description.
    case declined
    /// The model can't do what the turn asked (unsupported capability, bad
    /// generation guide, unsupported locale/transcript content). Same
    /// already-sanitized contract as `underlying`.
    case unsupported(String)
    /// Anything else: store failures, transport errors, future SDK cases.
    /// The payload is an already-sanitized one-line summary (see
    /// `sanitizedSummary`), never a raw dump -- the redaction guarantee
    /// holds at construction, not by convention at some future render
    /// site (WP-27 review §7).
    case underlying(String)
}

/// Bounds an error payload for UI propagation (WP-27 review §7):
/// framework/store error text may echo prompt fragments or token counts,
/// so payloads are single-line and capped at 300 characters. Ungated
/// (pure Swift) so every construction site -- gated framework mapping
/// and ungated store/transport fallbacks alike -- sanitizes.
/// Internal for the normalization-table tests.
extension CoachError {
    static func sanitizedSummary(_ raw: String, limit: Int = 300) -> String {
        let singleLine = raw.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard singleLine.count > limit else { return singleLine }
        return String(singleLine.prefix(limit - 1)) + "…"
    }
}

#if swift(>=6.4)
    import FoundationModels

    extension CoachError {
        /// Maps the framework's error cases (checked against the iOS 27 SDK
        /// surface: contextSizeExceeded, rateLimited, guardrailViolation,
        /// refusal, unsupported*, timeout). The `default` arm is deliberate:
        /// future SDK cases degrade to `.underlying` instead of failing the
        /// build the day a new beta adds one.
        ///
        /// Tier-aware (F2): a mid-generation overflow on a cloud tier has
        /// nowhere bigger to escalate to, so the offer bit is set only for
        /// on-device turns. Default `.onDevice` preserves behavior for
        /// callers without a tier in scope -- but prefer passing it: a bare
        /// call silently offers escalation for cloud overflows.
        ///
        /// Same SDK availability as the mapped type (see `makeModel`).
        @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
        @available(tvOS, unavailable)
        public init(languageModelError error: LanguageModelError, on tier: ModelTier = .onDevice) {
            switch error {
            case .contextSizeExceeded:
                self = .contextOverflow(offerEscalation: tier == .onDevice)
            case .rateLimited(let limited):
                self = .rateLimited(retryAfter: limited.resetDate)
            case .timeout:
                self = .requestTimeout
            case .guardrailViolation, .refusal:
                self = .declined
            case .unsupportedCapability(let u):
                self = .unsupported(Self.sanitizedSummary(u.debugDescription))
            case .unsupportedTranscriptContent(let u):
                self = .unsupported(Self.sanitizedSummary(u.debugDescription))
            case .unsupportedGenerationGuide(let u):
                self = .unsupported(Self.sanitizedSummary(u.debugDescription))
            case .unsupportedLanguageOrLocale(let u):
                self = .unsupported(Self.sanitizedSummary(u.debugDescription))
            // Sanitized like every other arm (F1 -- this handles future
            // unknown SDK cases: unbounded, unreviewed debug text): it must
            // not be the one raw path.
            @unknown default:
                self = .underlying(Self.sanitizedSummary(String(describing: error)))
            }
        }
    }
#endif
