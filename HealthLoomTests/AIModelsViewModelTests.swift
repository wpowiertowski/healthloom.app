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
struct AIModelsViewModelTests {
    private func makeSuite() -> UserDefaults {
        UserDefaults(suiteName: "test.\(UUID().uuidString)")!
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
    func pccBlockedWithoutConsent() async {
        let (viewModel, settings, _) = makeViewModel(suite: makeSuite())
        await viewModel.refresh()
        viewModel.setTurnedOn(true, for: .privateCloudCompute)
        #expect(viewModel.sheet == .consent(.privateCloudCompute))
        #expect(!settings.isTurnedOn(.privateCloudCompute))
        #expect(!viewModel.rows().first(where: { $0.tier == .privateCloudCompute })!.effectivelyOn)
    }

    @Test("declining consent leaves the tier off with nothing recorded")
    func dismissConsentStaysOff() async {
        let (viewModel, settings, _) = makeViewModel(suite: makeSuite())
        await viewModel.refresh()
        viewModel.setTurnedOn(true, for: .privateCloudCompute)
        viewModel.dismissSheet()
        #expect(viewModel.sheet == nil)
        #expect(!settings.hasConsent(for: .privateCloudCompute))
        #expect(!settings.isTurnedOn(.privateCloudCompute))
    }

    @Test("accepting consent records a timestamp and flips PCC on (no key needed)")
    func acceptConsentEnablesPCC() async {
        let (viewModel, settings, _) = makeViewModel(suite: makeSuite())
        await viewModel.refresh()
        viewModel.setTurnedOn(true, for: .privateCloudCompute)
        viewModel.acceptConsent()
        #expect(viewModel.sheet == nil)
        #expect(settings.consentDate(for: .privateCloudCompute) != nil)
        let row = viewModel.rows().first(where: { $0.tier == .privateCloudCompute })!
        #expect(row.effectivelyOn)
        #expect(row.availability == .available)
    }

    @Test("Claude enable walks consent then key entry, storing only after validation")
    func claudeConsentThenKeyFlow() async throws {
        let keys = InMemoryCloudKeyStore()
        let (viewModel, settings, _) = makeViewModel(suite: makeSuite(), keys: keys)
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
        #expect(viewModel.rows().first(where: { $0.tier == .claude })!.effectivelyOn)
    }

    @Test("a rejected key is never stored and the tier stays off")
    func invalidKeyStoresNothing() async throws {
        let keys = InMemoryCloudKeyStore()
        let (viewModel, _, _) = makeViewModel(
            suite: makeSuite(), keys: keys, validatorResult: .invalidKey)
        await viewModel.refresh()
        viewModel.setTurnedOn(true, for: .claude)
        viewModel.acceptConsent()
        viewModel.keyDraft = "sk-ant-wrong"
        await viewModel.saveKey()
        #expect(viewModel.sheet == .keyEntry(.claude), "sheet stays open for correction")
        #expect(viewModel.keyError?.contains("rejected") == true)
        #expect(try await keys.get(.claudeAPIKey) == nil)
        #expect(!viewModel.rows().first(where: { $0.tier == .claude })!.effectivelyOn)
    }

    @Test("a transport failure is not reported as an invalid key and stores nothing")
    func transportErrorStoresNothing() async throws {
        let keys = InMemoryCloudKeyStore()
        let (viewModel, _, _) = makeViewModel(
            suite: makeSuite(), keys: keys,
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
        let (viewModel, settings, gates) = makeViewModel(suite: makeSuite(), keys: keys)
        settings.recordConsent(for: .claude)
        settings.setTurnedOn(true, for: .claude)
        await viewModel.refresh()
        #expect(viewModel.rows().first(where: { $0.tier == .claude })!.effectivelyOn)
        await viewModel.deleteKey(for: .claude)
        let row = viewModel.rows().first(where: { $0.tier == .claude })!
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
    func withdrawConsentDisables() async {
        let (viewModel, settings, _) = makeViewModel(suite: makeSuite())
        settings.recordConsent(for: .privateCloudCompute)
        settings.setTurnedOn(true, for: .privateCloudCompute)
        await viewModel.refresh()
        #expect(viewModel.rows().first(where: { $0.tier == .privateCloudCompute })!.effectivelyOn)
        viewModel.withdrawConsent(for: .privateCloudCompute)
        let row = viewModel.rows().first(where: { $0.tier == .privateCloudCompute })!
        #expect(!row.effectivelyOn)
        #expect(row.availability == .unavailable(reason: TierAvailability.needsConsent))
    }

    @Test("toggle-off keeps consent and key; re-enable skips both sheets")
    func toggleOffKeepsCredentials() async throws {
        let keys = InMemoryCloudKeyStore(values: [.claudeAPIKey: "sk-ant-test"])
        let (viewModel, settings, _) = makeViewModel(suite: makeSuite(), keys: keys)
        settings.recordConsent(for: .claude)
        settings.setTurnedOn(true, for: .claude)
        await viewModel.refresh()
        viewModel.setTurnedOn(false, for: .claude)
        #expect(!viewModel.rows().first(where: { $0.tier == .claude })!.effectivelyOn)
        #expect(settings.hasConsent(for: .claude))
        #expect(try await keys.get(.claudeAPIKey) != nil)
        // Re-enable: gate already passes, no sheets.
        viewModel.setTurnedOn(true, for: .claude)
        #expect(viewModel.sheet == nil)
        #expect(viewModel.sheet == nil)
        #expect(viewModel.rows().first(where: { $0.tier == .claude })!.effectivelyOn)
    }

    @Test("model override round-trips; non-keyed tiers have no options")
    func modelPicker() async {
        let (viewModel, settings, _) = makeViewModel(suite: makeSuite())
        await viewModel.refresh()
        let claude = viewModel.rows().first(where: { $0.tier == .claude })!
        #expect(claude.modelID == CloudModelOptions.claudeDefault)
        viewModel.setModel(CloudModelOptions.claudeOptions[1], for: .claude)
        #expect(settings.modelOverride(for: .claude) == CloudModelOptions.claudeOptions[1])
        #expect(viewModel.rows().first(where: { $0.tier == .claude })!.modelID == CloudModelOptions.claudeOptions[1])
        // WP-29 F5: the Gemini row is deferred, not absent — pin its
        // default/options so the undeferral has a failing-then-passing twin.
        let gemini = viewModel.rows().first(where: { $0.tier == .gemini })!
        #expect(gemini.modelID == CloudModelOptions.geminiDefault)
        #expect(gemini.modelOptions == CloudModelOptions.geminiOptions)
        viewModel.setModel(CloudModelOptions.geminiOptions[1], for: .gemini)
        #expect(viewModel.rows().first(where: { $0.tier == .gemini })!.modelID == CloudModelOptions.geminiOptions[1])
        #expect(viewModel.rows().first(where: { $0.tier == .onDevice })!.modelOptions.isEmpty)
        #expect(viewModel.rows().first(where: { $0.tier == .privateCloudCompute })!.modelOptions.isEmpty)
    }

    @Test("a non-live tier cannot start the enable flow (F3 decision a)")
    func nonLiveTierStaysOff() async {
        let (viewModel, settings, _) = makeViewModel(suite: makeSuite(), liveTiers: [.onDevice])
        await viewModel.refresh()
        let row = viewModel.rows().first(where: { $0.tier == .claude })!
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
    func settingsStore() {
        let suite = makeSuite()
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
