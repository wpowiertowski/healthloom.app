// AvailabilityGate.swift
//
// WP-22 (implementation-plan.md): maps `SystemLanguageModel.default.availability`
// onto the UI states the coach surfaces, each with user-facing copy and the
// next-tier fallback suggestion.
//
// Shaped for WP-28a (architecture.md D14.3-4): PCC-era states (offline /
// entitlement-missing / quota near-limit / at-limit) extend this same enum --
// they are documented on `CoachAvailability` but not introduced here, so this
// WP adds no quota or entitlement machinery. Real generation is covered by
// on-device manual tests (test plan §7); unit tests inject each availability
// case through `status(for:)` and never touch the model.

import Foundation
import FoundationModels

/// UI-facing coach availability. Today this covers the on-device model only;
/// WP-28a extends it with PCC states (see the `pccNotes` extension point below)
/// without reshaping call sites.
public enum CoachAvailability: Equatable, Sendable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    /// The framework reported unavailability for a reason this SDK doesn't
    /// know (future OS reason). Deliberately neutral copy: it must not name
    /// a download or any other specific cause, since the cause is unknown
    /// and the wait it would imply may never end.
    case unavailable

    /// What the UI shows for this state.
    public var userMessage: String {
        switch self {
        case .available:
            "Coach is ready."
        case .deviceNotEligible:
            "This device doesn't support the on-device coach model."
        case .appleIntelligenceNotEnabled:
            "Apple Intelligence is turned off. Turn it on in Settings to use the coach."
        case .modelNotReady:
            "The on-device model is still downloading. Try again shortly."
        case .unavailable:
            "The on-device coach isn't available right now. Try again later."
        }
    }

    /// The next-tier fallback the UI suggests for this state (D14: PCC/cloud
    /// tiers arrive in P3; until then the suggestion names the direction, and
    /// WP-28 wires the actual tier switch).
    public var fallbackSuggestion: String {
        switch self {
        case .available:
            ""
        case .deviceNotEligible:
            "A cloud coach tier can still work on this device once enabled."
        case .appleIntelligenceNotEnabled:
            "You can enable Apple Intelligence in Settings, or use a cloud coach tier once enabled."
        case .modelNotReady:
            "Wait for the download to finish, or use a cloud coach tier once enabled."
        case .unavailable:
            "You can retry, or use a cloud coach tier once enabled."
        }
    }
}

/// Pure mapping from the framework's availability to the UI state (WP-22 step 1).
/// Static and model-free so every case is unit-testable by injection.
public enum AvailabilityGate {
    public static func status(for availability: SystemLanguageModel.Availability) -> CoachAvailability {
        switch availability {
        case .available:
            .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                .deviceNotEligible
            case .appleIntelligenceNotEnabled:
                .appleIntelligenceNotEnabled
            case .modelNotReady:
                .modelNotReady
            @unknown default:
                // Future OS reasons (device management, region lock, ...) get
                // the neutral case, never a state whose copy names a specific
                // cause like a download that may never complete.
                .unavailable
            }
        }
    }

    /// Live reading for the UI (WP-25): the on-device model's current state.
    public static func current() -> CoachAvailability {
        status(for: SystemLanguageModel.default.availability)
    }
}
