// TierSwitcherTests.swift
//
// WP-32 (implementation-plan.md): the in-chat tier switcher contract —
// the menu offers enabled tiers only; a non-enabled pick is blocked at
// `selectTier` AND at `send` dispatch; the transcript survives switches
// with per-turn serving-tier stamps; the safety suffix is re-applied on
// every swap. Scripted sessions + ephemeral suites/containers: no model,
// no HealthKit, no network.

import CoachKit
import CoreModel
import Foundation
import SwiftData
import SyncKit
import Testing

@testable import HealthLoom

private struct SwitchTimeout: Error {}

@Suite("TierSwitcher")
@MainActor
struct TierSwitcherTests {
    /// Captured factory instructions across builds (lock-guarded: the
    /// build closure is `@Sendable`, the assertions read post-send).
    private final class InstructionLog: Sendable {
        private let lock = NSLock()
        private var values: [String] = []

        func append(_ instructions: String) {
            lock.withLock { values.append(instructions) }
        }

        var all: [String] {
            lock.withLock { values }
        }
    }

    private func makeViewModel(
        liveTiers: Set<ModelTier> = [.onDevice, .privateCloudCompute, .claude],
        log: InstructionLog = InstructionLog(),
        // WP-32 F1: per-tier routing. Nil (default) builds every tier into
        // identical doubles — enough for slot segregation, blind to model
        // identity. A non-nil mapping builds tier-tagged doubles, proving
        // which model served, not just which slot was picked.
        chunks: ((ModelTier) -> [String])? = nil
    ) throws -> (CoachChatViewModel, TierSettingsStore, CloudGateCache) {
        let container = try CoreModel.makeContainer(inMemory: true)
        let settings = TierSettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        let gates = CloudGateCache()
        let catalog = ModelCatalog(
            onDeviceAvailable: { true },
            hasConsent: { gates.hasConsent($0) },
            hasKey: { gates.hasKey($0) },
            pccAvailable: { true },
            pccQuota: { .ok },
            liveTiers: liveTiers
        )
        let store = KnowledgeStore(
            modelContainer: container,
            healthReadStore: EmptyReadStore(),
            healthKitAuth: HealthKitAuth()
        )
        let factory = CoachSessionFactory(build: { tier, instructions, _ in
            log.append(instructions)
            if let chunks {
                return TestCoachSession(chunks: chunks(tier))
            }
            return TestCoachSession()
        })
        let viewModel = CoachChatViewModel(deps: CoachChatViewModel.Dependencies(
            container: container,
            store: store,
            prompts: PromptManager(modelContainer: container),
            assembler: ContextAssembler(modelContainer: container),
            factory: factory,
            availability: FixedCoachAvailabilityChecker(availability: .available),
            tierSettings: settings,
            tierCatalog: catalog
        ))
        return (viewModel, settings, gates)
    }

    /// Enables a tier the way production does: consent + key presence in
    /// the gates, toggle in the store.
    private func enable(_ tier: ModelTier, settings: TierSettingsStore, gates: CloudGateCache) {
        if tier.requiresConsent {
            settings.recordConsent(for: tier)
            gates.setConsent(true, for: tier)
        }
        if tier.requiresAPIKey {
            gates.setKeyPresent(true, for: tier)
        }
        settings.setTurnedOn(true, for: tier)
    }

    private func waitForIdle(_ viewModel: CoachChatViewModel) async throws {
        let start = Date.now
        while viewModel.isResponding {
            try await Task.sleep(for: .milliseconds(20))
            if Date.now.timeIntervalSince(start) > 10 {
                throw SwitchTimeout()
            }
        }
    }

    @Test("the menu offers enabled tiers only, in ladder order")
    func menuOffersOnlyEnabledTiers() throws {
        let (viewModel, settings, gates) = try makeViewModel()
        enable(.privateCloudCompute, settings: settings, gates: gates)
        #expect(viewModel.enabledTiers == [.onDevice, .privateCloudCompute])
        #expect(viewModel.enabledTierNames == "On-device · Apple cloud (PCC)")
    }

    @Test("selecting a non-enabled tier fails and keeps the selection")
    func selectBlockedTierFails() throws {
        let (viewModel, settings, gates) = try makeViewModel()
        // Claude: live but neither consented nor keyed.
        #expect(viewModel.selectTier(.claude) == false)
        #expect(viewModel.selectedTier == .onDevice)
        #expect(viewModel.errorMessage != nil)
        // Consent withdrawn mid-chat blocks the same way.
        enable(.privateCloudCompute, settings: settings, gates: gates)
        #expect(viewModel.selectTier(.privateCloudCompute) == true)
        settings.withdrawConsent(for: .privateCloudCompute)
        gates.setConsent(false, for: .privateCloudCompute)
        #expect(viewModel.selectTier(.privateCloudCompute) == false)
        #expect(viewModel.selectedTier == .privateCloudCompute)
    }

    @Test("send on a tier disabled since selection is blocked at dispatch")
    func sendBlockedOnDisabledTier() throws {
        let (viewModel, settings, gates) = try makeViewModel()
        enable(.privateCloudCompute, settings: settings, gates: gates)
        #expect(viewModel.selectTier(.privateCloudCompute) == true)
        settings.withdrawConsent(for: .privateCloudCompute)
        gates.setConsent(false, for: .privateCloudCompute)
        #expect(viewModel.send("hi") == false)
        #expect(viewModel.errorMessage?.contains("Apple cloud (PCC)") == true)
        #expect(viewModel.turns.isEmpty)
    }

    @Test("replies are stamped with the serving tier")
    func providerStampsServingTier() async throws {
        let (viewModel, settings, gates) = try makeViewModel()
        enable(.privateCloudCompute, settings: settings, gates: gates)
        #expect(viewModel.selectTier(.privateCloudCompute) == true)
        #expect(viewModel.send("hi") == true)
        try await waitForIdle(viewModel)
        #expect(viewModel.turns.count == 2)
        #expect(viewModel.turns[1].provider == ModelTier.privateCloudCompute.rawValue)
    }

    @Test("the transcript survives switches with per-turn stamps")
    func transcriptPreservedAcrossSwitches() async throws {
        let (viewModel, settings, gates) = try makeViewModel()
        enable(.privateCloudCompute, settings: settings, gates: gates)
        #expect(viewModel.send("one") == true)
        try await waitForIdle(viewModel)
        #expect(viewModel.selectTier(.privateCloudCompute) == true)
        #expect(viewModel.send("two") == true)
        try await waitForIdle(viewModel)
        #expect(viewModel.turns.map(\.content) == ["one", "Hello world.", "two", "Hello world."])
        #expect(viewModel.turns[1].provider == ModelTier.onDevice.rawValue)
        #expect(viewModel.turns[3].provider == ModelTier.privateCloudCompute.rawValue)
    }

    @Test("the safety suffix is re-applied across a switch sequence")
    func suffixSurvivesSwitches() async throws {
        let log = InstructionLog()
        let (viewModel, settings, gates) = try makeViewModel(log: log)
        enable(.privateCloudCompute, settings: settings, gates: gates)
        enable(.claude, settings: settings, gates: gates)
        let enabled = viewModel.enabledTiers
        #expect(enabled.count == 3)

        // Deterministic pseudo-random switch order (LCG, fixed seed — a
        // property-style sweep without a flaky RNG).
        var state: UInt64 = 42
        var picks: [ModelTier] = []
        for _ in 0..<12 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            picks.append(enabled[Int(state >> 33) % enabled.count])
        }
        for tier in picks {
            #expect(viewModel.selectTier(tier) == true)
            #expect(viewModel.send("n") == true)
            try await waitForIdle(viewModel)
        }
        // Every built slot ran under suffixed instructions (cache hits
        // reuse the verified build — the instructions are part of the
        // factory's cache key, so a hit implies the same instructions).
        #expect(!log.all.isEmpty)
        #expect(log.all.allSatisfy { $0.contains(SafetyLayer.text) })
        #expect(viewModel.turns.count == 24)
        let stamps = stride(from: 1, to: viewModel.turns.count, by: 2).map { viewModel.turns[$0].provider }
        #expect(stamps == picks.map(\.rawValue))
        #expect(viewModel.selectedTier == picks.last)
    }

    @Test("replies come from the selected tier's model (F1 identity)")
    func routesToTierModel() async throws {
        let (viewModel, settings, gates) = try makeViewModel(chunks: { ["<\($0.rawValue)>"] })
        enable(.privateCloudCompute, settings: settings, gates: gates)
        #expect(viewModel.selectTier(.privateCloudCompute) == true)
        #expect(viewModel.send("hi") == true)
        try await waitForIdle(viewModel)
        #expect(viewModel.turns.last?.content == "<privateCloudCompute>")
        #expect(viewModel.turns.last?.provider == ModelTier.privateCloudCompute.rawValue)
        #expect(viewModel.selectTier(.onDevice) == true)
        #expect(viewModel.send("yo") == true)
        try await waitForIdle(viewModel)
        #expect(viewModel.turns.last?.content == "<onDevice>")
        #expect(viewModel.turns.last?.provider == ModelTier.onDevice.rawValue)
    }

    @Test("onAppear clamps a selection disabled while chat was away")
    func onAppearClampsStaleSelection() throws {
        let (viewModel, settings, gates) = try makeViewModel()
        enable(.privateCloudCompute, settings: settings, gates: gates)
        #expect(viewModel.selectTier(.privateCloudCompute) == true)
        settings.withdrawConsent(for: .privateCloudCompute)
        gates.setConsent(false, for: .privateCloudCompute)
        viewModel.onAppear()
        #expect(viewModel.selectedTier == .onDevice)
    }
}
