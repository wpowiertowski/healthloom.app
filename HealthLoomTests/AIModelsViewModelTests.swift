// AIModelsViewModelTests.swift
//
// WP-29 (implementation-plan.md): the enable-flow truth table -- blocked
// without consent, blocked without key, invalid/transport keys never
// stored, key delete and consent withdrawal drop the effective state while
// the toggle preference survives, and toggle-off keeps consent + key for
// cheap re-enable. Ephemeral `UserDefaults` suites + in-memory keys +
// stub validator: no Keychain, no network.

import CoachKit
import Foundation
import Secrets
import Testing

@testable import HealthLoom

@MainActor
/// Attributable test-shape failure (round-7 item 15).
private enum AIModelsTestError: Error {
    case missingOption(String)
}

struct AIModelsViewModelTests {
    // Round-3 item 10: throwing factory — a `try!` here would trap
    // the whole xctest process on the (impossible) failure. Call sites
    // pay one `try` each instead.
    private func makeSuite() throws -> EphemeralDefaults {
        try EphemeralDefaults(prefix: "aimodels")
    }

    /// Row lookup that FAILS the test instead of trapping (round-7 item
    /// 15): every `first(where:)!` in this file routes through here, so
    /// a missing row records an attributable issue, never a fatal error.
    private func row(_ tier: ModelTier, in viewModel: AIModelsViewModel) throws -> AIModelsViewModel.TierRow {
        try #require(
            viewModel.rows().first(where: { $0.tier == tier }),
            "missing settings row for \(tier)"
        )
    }

    /// Indexed access that FAILS instead of trapping (round-7 item 15):
    /// the model-option `[1]` subscripts route through here.
    private func element<T>(_ array: [T], _ index: Int, what: String) throws -> T {
        guard array.indices.contains(index) else {
            throw AIModelsTestError.missingOption(what)
        }
        return array[index]
    }

    /// Catalog with scripted gate inputs; consent/key read the test's
    /// settings + key store through the same gate-cache shape production
    /// uses, so these tests exercise the real wiring (not a parallel
    /// reimplementation of the gate).
    private func makeViewModel(
        suite: UserDefaults,
        keys: InMemoryCloudKeyStore = InMemoryCloudKeyStore(),
        validatorResult: CloudKeyValidation = .valid,
        liveTiers: Set<ModelTier> = [.onDevice, .privateCloudCompute, .claude],
        pccAvailable: Bool = true
    ) -> (AIModelsViewModel, TierSettingsStore, CloudGateCache) {
        let settings = TierSettingsStore(defaults: suite)
        let gates = CloudGateCache()
        let catalog = ModelCatalog(
            onDeviceAvailable: { true },
            hasConsent: { gates.hasConsent($0) },
            hasKey: { gates.hasKey($0) },
            pccAvailable: { pccAvailable },
            pccQuota: { .ok },
            liveTiers: liveTiers
        )
        let viewModel = AIModelsViewModel(deps: AIModelsViewModel.Dependencies(
            catalog: catalog,
            settings: settings,
            gates: gates,
            keys: keys,
            validator: StubCloudKeyValidator(result: validatorResult)
        ))
        return (viewModel, settings, gates)
    }

    @Test("PCC enable without consent presents the sheet and stays off")
    func pccBlockedWithoutConsent() async throws {
        let ephemeral1 = try makeSuite()
        let (viewModel, settings, _) = makeViewModel(suite: ephemeral1.defaults)
        await viewModel.refresh()
        viewModel.setTurnedOn(true, for: .privateCloudCompute)
        #expect(viewModel.sheet == .consent(.privateCloudCompute))
        #expect(!settings.isTurnedOn(.privateCloudCompute))
        #expect(!(try row(.privateCloudCompute, in: viewModel).effectivelyOn))
    }

    @Test("declining consent leaves the tier off with nothing recorded")
    func dismissConsentStaysOff() async throws {
        let ephemeral2 = try makeSuite()
        let (viewModel, settings, _) = makeViewModel(suite: ephemeral2.defaults)
        await viewModel.refresh()
        viewModel.setTurnedOn(true, for: .privateCloudCompute)
        viewModel.dismissSheet()
        #expect(viewModel.sheet == nil)
        #expect(!settings.hasConsent(for: .privateCloudCompute))
        #expect(!settings.isTurnedOn(.privateCloudCompute))
    }

    @Test("accepting consent records a timestamp and flips PCC on (no key needed)")
    func acceptConsentEnablesPCC() async throws {
        let ephemeral3 = try makeSuite()
        let (viewModel, settings, _) = makeViewModel(suite: ephemeral3.defaults)
        await viewModel.refresh()
        viewModel.setTurnedOn(true, for: .privateCloudCompute)
        viewModel.acceptConsent()
        #expect(viewModel.sheet == nil)
        #expect(settings.consentDate(for: .privateCloudCompute) != nil)
        let row = try row(.privateCloudCompute, in: viewModel)
        #expect(row.effectivelyOn)
        #expect(row.availability == .available)
    }

    @Test("Claude enable walks consent then key entry, storing only after validation")
    func claudeConsentThenKeyFlow() async throws {
        let keys = InMemoryCloudKeyStore()
        let ephemeral4 = try makeSuite()
        let (viewModel, settings, _) = makeViewModel(suite: ephemeral4.defaults, keys: keys)
        await viewModel.refresh()
        viewModel.setTurnedOn(true, for: .claude)
        #expect(viewModel.sheet == .consent(.claude))
        viewModel.acceptConsent()
        // Consent done, key missing: key sheet, still off, nothing stored.
        #expect(viewModel.sheet == .keyEntry(.claude))
        #expect(!settings.isTurnedOn(.claude))
        #expect(try await keys.get(.claudeAPIKey) == nil)
        // Valid ping stores and enables.
        viewModel.keyDraft = "sk-ant-test"
        await viewModel.saveKey()
        #expect(viewModel.sheet == nil)
        #expect(try await keys.get(.claudeAPIKey) == "sk-ant-test")
        #expect(try row(.claude, in: viewModel).effectivelyOn)
    }

    @Test("a rejected key is never stored and the tier stays off")
    func invalidKeyStoresNothing() async throws {
        let keys = InMemoryCloudKeyStore()
        let ephemeral5 = try makeSuite()
        let (viewModel, _, _) = makeViewModel(
            suite: ephemeral5.defaults, keys: keys, validatorResult: .invalidKey)
        await viewModel.refresh()
        viewModel.setTurnedOn(true, for: .claude)
        viewModel.acceptConsent()
        viewModel.keyDraft = "sk-ant-wrong"
        await viewModel.saveKey()
        #expect(viewModel.sheet == .keyEntry(.claude), "sheet stays open for correction")
        #expect(viewModel.keyError?.contains("rejected") == true)
        #expect(try await keys.get(.claudeAPIKey) == nil)
        #expect(!(try row(.claude, in: viewModel).effectivelyOn))
    }

    @Test("a transport failure is not reported as an invalid key and stores nothing")
    func transportErrorStoresNothing() async throws {
        let keys = InMemoryCloudKeyStore()
        let ephemeral6 = try makeSuite()
        let (viewModel, _, _) = makeViewModel(
            suite: ephemeral6.defaults, keys: keys,
            validatorResult: .transportError("offline"))
        await viewModel.refresh()
        viewModel.setTurnedOn(true, for: .claude)
        viewModel.acceptConsent()
        viewModel.keyDraft = "sk-ant-maybe"
        await viewModel.saveKey()
        #expect(viewModel.keyError?.contains("not stored") == true)
        #expect(viewModel.keyError?.contains("rejected") == false)
        #expect(try await keys.get(.claudeAPIKey) == nil)
    }

    @Test("key deletion drops the effective state but keeps toggle + consent")
    func keyDeleteDisablesTier() async throws {
        let keys = InMemoryCloudKeyStore(values: [.claudeAPIKey: "sk-ant-test"])
        let ephemeral7 = try makeSuite()
        let (viewModel, settings, gates) = makeViewModel(suite: ephemeral7.defaults, keys: keys)
        settings.recordConsent(for: .claude)
        settings.setTurnedOn(true, for: .claude)
        await viewModel.refresh()
        #expect(try row(.claude, in: viewModel).effectivelyOn)
        await viewModel.deleteKey(for: .claude)
        let row = try row(.claude, in: viewModel)
        #expect(!row.effectivelyOn)
        // WP-29 F3: assert *which* blocker via the now-public constant.
        #expect(row.availability == .unavailable(reason: TierAvailability.needsKey))
        // Preference + consent survive: re-entering a key re-enables
        // without re-consenting.
        #expect(settings.isTurnedOn(.claude))
        #expect(settings.hasConsent(for: .claude))
        #expect(!gates.hasKey(.claude))
    }

    @Test("withdrawing consent drops the effective state")
    func withdrawConsentDisables() async throws {
        let ephemeral8 = try makeSuite()
        let (viewModel, settings, _) = makeViewModel(suite: ephemeral8.defaults)
        settings.recordConsent(for: .privateCloudCompute)
        settings.setTurnedOn(true, for: .privateCloudCompute)
        await viewModel.refresh()
        #expect(try row(.privateCloudCompute, in: viewModel).effectivelyOn)
        viewModel.withdrawConsent(for: .privateCloudCompute)
        let row = try row(.privateCloudCompute, in: viewModel)
        #expect(!row.effectivelyOn)
        #expect(row.availability == .unavailable(reason: TierAvailability.needsConsent))
    }

    @Test("toggle-off keeps consent and key; re-enable skips both sheets")
    func toggleOffKeepsCredentials() async throws {
        let keys = InMemoryCloudKeyStore(values: [.claudeAPIKey: "sk-ant-test"])
        let ephemeral9 = try makeSuite()
        let (viewModel, settings, _) = makeViewModel(suite: ephemeral9.defaults, keys: keys)
        settings.recordConsent(for: .claude)
        settings.setTurnedOn(true, for: .claude)
        await viewModel.refresh()
        viewModel.setTurnedOn(false, for: .claude)
        #expect(!(try row(.claude, in: viewModel).effectivelyOn))
        #expect(settings.hasConsent(for: .claude))
        #expect(try await keys.get(.claudeAPIKey) != nil)
        // Re-enable: gate already passes, no sheets.
        viewModel.setTurnedOn(true, for: .claude)
        #expect(viewModel.sheet == nil)
        #expect(viewModel.sheet == nil)
        #expect(try row(.claude, in: viewModel).effectivelyOn)
    }

    @Test("model override round-trips; non-keyed tiers have no options")
    func modelPicker() async throws {
        let ephemeral10 = try makeSuite()
        let (viewModel, settings, _) = makeViewModel(suite: ephemeral10.defaults)
        await viewModel.refresh()
        let claude = try row(.claude, in: viewModel)
        #expect(claude.modelID == CloudModelOptions.claudeDefault)
        let claudeSecond = try element(CloudModelOptions.claudeOptions, 1, what: "claudeOptions[1]")
        viewModel.setModel(claudeSecond, for: .claude)
        #expect(settings.modelOverride(for: .claude) == claudeSecond)
        #expect(try row(.claude, in: viewModel).modelID == claudeSecond)
        // WP-29 F5: the Gemini row is deferred, not absent — pin its
        // default/options so the undeferral has a failing-then-passing twin.
        let gemini = try row(.gemini, in: viewModel)
        #expect(gemini.modelID == CloudModelOptions.geminiDefault)
        #expect(gemini.modelOptions == CloudModelOptions.geminiOptions)
        let geminiSecond = try element(CloudModelOptions.geminiOptions, 1, what: "geminiOptions[1]")
        viewModel.setModel(geminiSecond, for: .gemini)
        #expect(try row(.gemini, in: viewModel).modelID == geminiSecond)
        #expect(try row(.onDevice, in: viewModel).modelOptions.isEmpty)
        #expect(try row(.privateCloudCompute, in: viewModel).modelOptions.isEmpty)
    }

    @Test("a non-live tier cannot start the enable flow (F3 decision a)")
    func nonLiveTierStaysOff() async throws {
        let ephemeral11 = try makeSuite()
        let (viewModel, settings, _) = makeViewModel(suite: ephemeral11.defaults, liveTiers: [.onDevice])
        await viewModel.refresh()
        let row = try row(.claude, in: viewModel)
        #expect(!row.isLive)
        #expect(row.availability == .unavailable(reason: TierAvailability.notLive))
        viewModel.setTurnedOn(true, for: .claude)
        #expect(viewModel.sheet == nil, "no consent sheet for a tier that cannot serve")
        #expect(!settings.isTurnedOn(.claude))
        #expect(!settings.hasConsent(for: .claude))
        // WP-29 F9 side door: direct key entry is a no-op for non-live rows.
        viewModel.beginKeyEntry(for: .claude)
        #expect(viewModel.sheet == nil, "no key sheet for a tier that cannot serve")
    }

    @Test("consent copy exists for every off-device tier and none for on-device")
    func consentCopyCoverage() {
        #expect(TierConsentCopy.forTier(.onDevice) == nil)
        for tier in ModelTier.allCases where tier.requiresConsent {
            let copy = TierConsentCopy.forTier(tier)
            #expect(copy != nil)
            #expect(!(copy?.destination.isEmpty ?? true))
            #expect(!(copy?.forgetNote.isEmpty ?? true))
        }
        let destinations = Set(ModelTier.allCases.compactMap { TierConsentCopy.forTier($0)?.destination })
        #expect(destinations.count == 3, "each off-device tier names its own destination")
    }

    @Test("store defaults, record/withdraw, and resetAll")
    func settingsStore() throws {
        let ephemeral12 = try makeSuite()
        let suite = ephemeral12.defaults
        let settings = TierSettingsStore(defaults: suite)
        #expect(settings.isTurnedOn(.onDevice))
        #expect(!settings.isTurnedOn(.privateCloudCompute))
        #expect(!settings.hasConsent(for: .claude))
        settings.recordConsent(for: .claude)
        #expect(settings.hasConsent(for: .claude))
        settings.setTurnedOn(true, for: .claude)
        TierSettingsStore.resetAll(in: suite)
        // `resetAll` is a static wipe — live instances resync (WP-29 F1).
        settings.resyncFromDefaults()
        #expect(!settings.hasConsent(for: .claude))
        #expect(!settings.isTurnedOn(.claude))
        #expect(settings.isTurnedOn(.onDevice), "reset restores defaults, not blanket-off")
    }
}
