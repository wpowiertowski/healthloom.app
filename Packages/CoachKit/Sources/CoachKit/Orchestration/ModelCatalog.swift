// ModelCatalog.swift
//
// WP-27 (implementation-plan.md step 1): the table of model tiers -- display
// name, `makeModel()`, `runsOnDevice`, `requiresAPIKey`, `requiresConsent`,
// availability check -- with `isEnabled` gating each tier. This WP ships the
// catalog with only `.onDevice` live; WP-28 fills the other rows.
//
// Testability split (the package's pure/impure rule): everything except
// `makeModel()` is toolchain-independent -- gating truth table,
// availability mapping -- so it compiles and tests on both matrix
// toolchains. Only `makeModel()` mentions `any LanguageModel` and it sits
// behind `#if swift(>=6.4)` (see ModelTier.swift's header for why the gate
// is a compiler version, not `@available`).

import Foundation
import FoundationModels

/// Per-tier availability as reported to the UI. A `String` reason (not a
/// closed enum) because WP-28's rows bring provider-specific causes
/// (missing key, quota exhausted, no entitlement) that this WP can't
/// enumerate; call sites render the string verbatim.
public enum TierAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String)
}

/// Single edit point for the catalog's UI copy (WP-27 review R3): the
/// reasons used to be independent literals in source *and* duplicated on
/// the `#expect` side, so a copy edit was N coordinated edits. Tests
/// assert against these constants (verifying *which* blocker, not its
/// spelling); the deeper unification (one availability type) waits for
/// WP-29's Settings screen.
extension TierAvailability {
    static let notLive = "Ships in a later update."
    static let needsConsent = "Requires opt-in consent."
    static let needsKey = "Requires an API key."
    static let modelUnavailable = "Apple Intelligence is unavailable."
}

/// The tier table. Value type with injected seams: the catalog never touches
/// the Keychain, consent storage, or the model itself -- the app wires those
/// in (Keychain reads, `IncrementalConsentPresenter`, `AvailabilityGate`),
/// and tests inject fakes. That keeps the gating truth table (key x consent
/// x availability) a pure unit test on both toolchains.
public struct ModelCatalog: Sendable {
    /// Live on-device-model state. `@MainActor`-bound because the WP-22
    /// availability gate it usually reads is (like every coach type in this
    /// package); tests inject a constant. No default: a default argument
    /// evaluates in a nonisolated context, so it couldn't read the gate --
    /// callers wanting the live wiring use `live()` instead.
    public var onDeviceAvailable: @MainActor @Sendable () -> Bool
    /// Whether opt-in consent is recorded for a tier (D11). Defaults to
    /// false -- no tier is consented until the app records it.
    public var hasConsent: @Sendable (ModelTier) -> Bool
    /// Whether the tier's API key is present in the Keychain. Defaults to
    /// false; the app wires `KeychainStore.get(tier.secretKey) != nil`.
    public var hasKey: @Sendable (ModelTier) -> Bool
    /// PCC runtime state (WP-28a, D14.3/D14.4). Defaults to
    /// available/ok; the app's live wiring reads the real model (see
    /// `live()`), tests inject quota states to render warning/fallback.
    /// `@MainActor`-bound like `onDeviceAvailable`, no default (same
    /// nonisolated-default-arg reason).
    public var pccAvailable: @MainActor @Sendable () -> Bool
    public var pccQuota: @MainActor @Sendable () -> PCCQuota
    /// Rows that have shipped. Defaults to on-device only; WP-28 flips rows
    /// live by adding them to the default set. Tests inject extra rows to
    /// exercise cloud-tier gating (consent/key checks, tier-aware cache,
    /// no-escalation) without real providers.
    public var liveTiers: Set<ModelTier>

    public init(
        onDeviceAvailable: @MainActor @Sendable @escaping () -> Bool,
        hasConsent: @Sendable @escaping (ModelTier) -> Bool = { _ in false },
        hasKey: @Sendable @escaping (ModelTier) -> Bool = { _ in false },
        pccAvailable: @MainActor @Sendable @escaping () -> Bool = { true },
        pccQuota: @MainActor @Sendable @escaping () -> PCCQuota = { .ok },
        liveTiers: Set<ModelTier> = [.onDevice]
    ) {
        self.onDeviceAvailable = onDeviceAvailable
        self.hasConsent = hasConsent
        self.hasKey = hasKey
        self.pccAvailable = pccAvailable
        self.pccQuota = pccQuota
        self.liveTiers = liveTiers
    }

    /// Catalog with the live on-device gate wired (`AvailabilityGate`,
    /// WP-22). The app's default; tests construct `init` directly with a
    /// constant so availability is a test input, not environment.
    /// Explicit `@MainActor` (see `isEnabled`).
    @MainActor
    public static func live(
        hasConsent: @Sendable @escaping (ModelTier) -> Bool = { _ in false },
        hasKey: @Sendable @escaping (ModelTier) -> Bool = { _ in false },
        liveTiers: Set<ModelTier> = [.onDevice]
    ) -> ModelCatalog {
        ModelCatalog(
            onDeviceAvailable: { AvailabilityGate.current() == .available },
            hasConsent: hasConsent,
            hasKey: hasKey,
            pccAvailable: { Self.livePCCAvailability() },
            pccQuota: { Self.livePCCQuota() },
            liveTiers: liveTiers
        )
    }

    /// Live PCC model reads. The stable matrix toolchain can't name these
    /// symbols at all, so the stable variant reports unavailable/ok without
    /// touching the framework (PCC never dispatches there -- `makeModel` is
    /// gated too). The beta variant carries the SDK's own availability: it
    /// only executes on iOS/macOS 27+ (package tests on macOS 26 take the
    /// early return, never the model read).
    private static func livePCCAvailability() -> Bool {
#if swift(>=6.4)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) {
            return PrivateCloudComputeLanguageModel().isAvailable
        }
#endif
        return false
    }

    private static func livePCCQuota() -> PCCQuota {
#if swift(>=6.4)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) {
            return PCCQuota(PrivateCloudComputeLanguageModel().quotaUsage)
        }
#endif
        return .ok
    }

    /// Gate: on-device runs when the model is available; every other tier
    /// needs recorded consent AND (no key needed, or key in Keychain).
    /// The `isLive` conjunct dominates (WP-27 review §12): even a fully
    /// consented+keyed cloud tier stays off until WP-28 flips its row --
    /// every WP-28 diff touches that predicate, not this gate.
    ///
    /// Explicit `@MainActor` (WP-27 review §10): the package default
    /// isolation would infer it, but off-main callers (PCC quota checks,
    /// background insights) must see the hop without reading Package.swift.
    @MainActor
    public func isEnabled(_ tier: ModelTier) -> Bool {
        switch tier {
        case .onDevice:
            onDeviceAvailable()
        case .privateCloudCompute:
            isLive(tier) && pccAvailable() && hasConsent(tier)
        case .claude, .gemini:
            // Live-row check doubles as the WP-28 fill-in point: each row
            // goes live by returning its consent/key gate here instead of
            // false.
            isLive(tier) && hasConsent(tier) && (!tier.requiresAPIKey || hasKey(tier))
        }
    }

    /// Availability detail for UI copy. On-device reflects the live gate;
    /// off-device rows report their setup blocker (consent, key) or their
    /// not-yet-live state, so Settings can render *why* a tier is off.
    /// Explicit `@MainActor` (see `isEnabled`).
    @MainActor
    public func availability(for tier: ModelTier) -> TierAvailability {
        switch tier {
        case .onDevice:
            if onDeviceAvailable() {
                return TierAvailability.available
            }
            return TierAvailability.unavailable(reason: TierAvailability.modelUnavailable)
        case .privateCloudCompute:
            // PCC consults the model state (offline/entitlement surface as
            // unavailable, D14.4) before consent/key: no point consenting to
            // a tier that can't run.
            guard isLive(tier) else {
                return .unavailable(reason: TierAvailability.notLive)
            }
            guard pccAvailable() else {
                return .unavailable(reason: TierAvailability.modelUnavailable)
            }
            guard hasConsent(tier) else {
                return .unavailable(reason: TierAvailability.needsConsent)
            }
            return .available
        case .claude, .gemini:
            guard isLive(tier) else {
                return .unavailable(reason: TierAvailability.notLive)
            }
            guard hasConsent(tier) else {
                return .unavailable(reason: TierAvailability.needsConsent)
            }
            guard !tier.requiresAPIKey || hasKey(tier) else {
                return .unavailable(reason: TierAvailability.needsKey)
            }
            return .available
        }
    }

    /// Context window for a tier's turns (WP-27 review §5): the budget used
    /// to belong to each `respond` caller (defaulting to the 4K on-device
    /// window for every tier -- a forgotten override silently trimmed PCC
    /// turns to 4K or skipped on-device escalation). The catalog owns
    /// per-tier knowledge, so it owns the budget; `respond` keeps an
    /// explicit override for tests.
    /// Explicit `@MainActor` for the same reason as `isEnabled`.
    @MainActor
    public func tokenBudget(for tier: ModelTier) -> Int {
        switch tier {
        case .onDevice:
            ContextAssembler.onDeviceTokenBudget
        case .privateCloudCompute:
            ContextAssembler.privateCloudComputeTokenBudget
        case .claude, .gemini:
            ContextAssembler.largeCloudTokenBudget
        }
    }

#if swift(>=6.4)
    /// Builds the framework model for a tier -- the D9 seam: every tier
    /// answers as `any LanguageModel`, so sessions, streaming, `@Generable`
    /// guides and tool calls work identically across providers. Only
    /// `.onDevice` is live this WP; the other rows throw `.tierUnavailable`
    /// until WP-28 fills them (never a half-wired model).
    ///
    /// Carries the SDK's own availability: the protocol is a 27-SDK
    /// declaration, so this is unreachable below macOS/iOS 27 (the stable
    /// matrix toolchain can't even name the return type -- see
    /// ModelTier.swift's header).
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
    @available(tvOS, unavailable)
    public func makeModel(for tier: ModelTier) throws -> any LanguageModel {
        switch tier {
        case .onDevice:
            SystemLanguageModel.default
        case .privateCloudCompute:
            PrivateCloudComputeLanguageModel()
        case .claude, .gemini:
            throw CoachError.tierUnavailable(tier: tier, reason: TierAvailability.notLive)
        }
    }
#endif

    /// Live-row table. Single predicate (not per-row inline conditions)
    /// so `isEnabled`/`availability(for:)`/`makeModel` can never disagree
    /// about which rows are live. WP-28 flips rows by extending the default
    /// `liveTiers` set.
    private func isLive(_ tier: ModelTier) -> Bool {
        liveTiers.contains(tier)
    }
}
