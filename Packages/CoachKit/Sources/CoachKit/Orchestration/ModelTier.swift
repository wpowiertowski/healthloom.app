// ModelTier.swift
//
// WP-27 (implementation-plan.md): the coach model ladder (architecture.md
// D14). Four tiers behind one seam; this WP ships only `.onDevice` live and
// WP-28 fills the other rows.
//
// Deliberately free of FoundationModels symbols: the `LanguageModel`
// protocol only exists in the iOS/macOS 27 SDK, while this package's `swift
// test` matrix also builds on macOS 26 (stable Xcode 26.4.1 toolchain),
// where that declaration is absent entirely and `@available` cannot gate a
// missing symbol. Everything protocol-touching lives behind the
// `#if swift(>=6.4)` toolchain gate in ModelCatalog.swift (stable = Swift
// 6.3.1, beta = Swift 6.4); if a future toolchain ever breaks that proxy
// the failure is a loud compile error, never silent misbehavior.

import Foundation
import Secrets

/// One rung of the coach model ladder (D14).
public enum ModelTier: String, Sendable, Hashable, CaseIterable, Identifiable {
    case onDevice
    case privateCloudCompute
    case claude
    case gemini

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .onDevice: "On-device"
        case .privateCloudCompute: "Apple cloud (PCC)"
        case .claude: "Claude (your key)"
        case .gemini: "Gemini (your key)"
        }
    }

    /// Privacy posture for consent copy: only `.onDevice` never leaves the
    /// device (D14.1 PCC leaves it for Apple's servers; Claude/Gemini for
    /// third parties).
    public var runsOnDevice: Bool {
        self == .onDevice
    }

    /// Whether the tier needs a user-supplied API key in the Keychain before
    /// it can run. PCC needs none (quota is per-iCloud-account, D14.3).
    public var requiresAPIKey: Bool {
        switch self {
        case .claude, .gemini: true
        case .onDevice, .privateCloudCompute: false
        }
    }

    /// Keychain identity for key-gated tiers, nil otherwise. Raw values stay
    /// inside the `provider.*` namespace (`SecretKey`'s documented
    /// invariant), so `deleteAll(matching: "provider.")` revokes every cloud
    /// AI key without touching Google OAuth tokens.
    public var secretKey: SecretKey? {
        switch self {
        case .claude: .claudeAPIKey
        case .gemini: .geminiAPIKey
        case .onDevice, .privateCloudCompute: nil
        }
    }

    /// Whether enabling the tier must record opt-in consent first. Every
    /// off-device hop is opt-in (D11); on-device needs none.
    public var requiresConsent: Bool {
        !runsOnDevice
    }
}
