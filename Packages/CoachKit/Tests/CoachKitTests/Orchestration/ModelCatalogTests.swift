// ModelCatalogTests.swift
//
// WP-27 "Tests" line: catalog gating truth table (key x consent x
// availability). All ungated -- no model, no 27-SDK-only symbols -- except
// the `makeModel` row-liveness test, which is behind the same toolchain
// gate as the API itself.

#if swift(>=6.4)
    import FoundationModels
#endif
import Testing

@testable import CoachKit

@Suite("ModelCatalog gating")
@MainActor
struct ModelCatalogTests {
    /// Ladder contract (R-table fold): only the rows with behavioral
    /// weight -- key-gated tiers map into the `provider.*` Keychain
    /// namespace, keyless tiers map nowhere, every off-device hop needs
    /// consent. Getter echoes (`displayName`, per-tier booleans) are not
    /// re-asserted here; they transcribe the switch bodies with no behavior.
    @Test("ladder key/consent contract")
    func ladderContract() {
        #expect(ModelTier.claude.secretKey?.rawValue.hasPrefix("provider.") == true)
        #expect(ModelTier.gemini.secretKey?.rawValue.hasPrefix("provider.") == true)
        #expect(ModelTier.onDevice.secretKey == nil)
        #expect(ModelTier.privateCloudCompute.secretKey == nil)
        #expect(!ModelTier.privateCloudCompute.requiresAPIKey)
        #expect(ModelTier.allCases.filter(\.requiresConsent).count == 3)
    }

    @Test("on-device enablement follows model availability only")
    func onDeviceFollowsAvailability() {
        #expect(ModelCatalog(onDeviceAvailable: { true }).isEnabled(.onDevice))
        #expect(!ModelCatalog(onDeviceAvailable: { false }).isEnabled(.onDevice))
    }

    /// Truth table for a key-gated tier: consent x key. (Availability only
    /// gates on-device -- cloud rows report setup blockers through
    /// `availability(for:)` instead.)
    @Test("key-gated tier needs consent and key", arguments: [
        (false, false, false),
        (false, true, false),
        (true, false, false),
        // (true, true) absent: consented+keyed cloud rows staying off is
        // `nonLiveRowsDisabled`'s proposition, asserted once below.
    ])
    func keyGatedTruthTable(consent: Bool, key: Bool, expected: Bool) {
        let catalog = ModelCatalog(onDeviceAvailable: { true }, hasConsent: { _ in consent }, hasKey: { _ in key })
        #expect(catalog.isEnabled(.claude) == expected)
        #expect(catalog.isEnabled(.gemini) == expected)
    }

    @Test("non-live rows stay disabled even when fully set up")
    func nonLiveRowsDisabled() {
        let catalog = ModelCatalog(
            onDeviceAvailable: { true },
            hasConsent: { _ in true },
            hasKey: { _ in true }
        )
        for tier in [ModelTier.privateCloudCompute, .claude, .gemini] {
            #expect(!catalog.isEnabled(tier))
        }
    }

    @Test("availability names the blocker")
    func availabilityReasons() {
        #expect(ModelCatalog(onDeviceAvailable: { true }).availability(for: .onDevice) == .available)
        #expect(ModelCatalog(onDeviceAvailable: { false }).availability(for: .onDevice)
            == .unavailable(reason: TierAvailability.modelUnavailable))
        // Fully set up but not live: the row state dominates consent/key.
        // (Consent-before-key blocker order becomes reachable when WP-28
        // flips the rows live; the `availability(for:)` source pins the
        // order, and this test will extend to cover it then.)
        let ready = ModelCatalog(onDeviceAvailable: { true }, hasConsent: { _ in true }, hasKey: { _ in true })
        #expect(ready.availability(for: .claude) == .unavailable(reason: TierAvailability.notLive))
    }

    @Test("live-row blockers surface consent before key")
    func blockerOrder() {
        let noConsent = ModelCatalog(
            onDeviceAvailable: { true },
            hasConsent: { _ in false },
            hasKey: { _ in true },
            liveTiers: [.onDevice, .claude]
        )
        #expect(noConsent.availability(for: .claude) == .unavailable(reason: TierAvailability.needsConsent))
        let noKey = ModelCatalog(
            onDeviceAvailable: { true },
            hasConsent: { _ in true },
            hasKey: { _ in false },
            liveTiers: [.onDevice, .claude]
        )
        #expect(noKey.availability(for: .claude) == .unavailable(reason: TierAvailability.needsKey))
    }

    @Test("each tier owns its window")
    func tierBudgets() {
        let catalog = ModelCatalog(onDeviceAvailable: { true })
        #expect(catalog.tokenBudget(for: .onDevice) == ContextAssembler.onDeviceTokenBudget)
        #expect(catalog.tokenBudget(for: .privateCloudCompute) == ContextAssembler.privateCloudComputeTokenBudget)
        #expect(catalog.tokenBudget(for: .claude) == ContextAssembler.largeCloudTokenBudget)
        #expect(catalog.tokenBudget(for: .gemini) == ContextAssembler.largeCloudTokenBudget)
    }

#if swift(>=6.4)
    /// Compile-checked on the beta toolchain; executes only on macOS 27+
    /// hosts (package tests run on macOS 26, where the 27-only declaration
    /// can't run -- the guard returns early there instead of crashing).
    @Test("makeModel builds on-device, refuses non-live rows")
    func makeModelLiveness() throws {
        guard #available(macOS 27, *) else { return }
        let catalog = ModelCatalog(onDeviceAvailable: { true })
        #expect(try catalog.makeModel(for: .onDevice) is SystemLanguageModel)
        #expect(try catalog.makeModel(for: .privateCloudCompute) is PrivateCloudComputeLanguageModel)
        for tier in [ModelTier.claude, .gemini] {
            #expect(throws: CoachError.tierUnavailable(tier: tier, reason: TierAvailability.notLive)) {
                try catalog.makeModel(for: tier)
            }
        }
    }
#endif
}
