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
    /// Factory-instruction log (internal so the fixture can hold it;
    /// same-file test helper otherwise).
    final class InstructionLog: Sendable {
        private let lock = NSLock()
        private var values: [String] = []

        func append(_ instructions: String) {
            lock.withLock { values.append(instructions) }
        }

        var all: [String] {
            lock.withLock { values }
        }
    }

    /// Structural fixture (round-3 item 12): owns the view model
    /// triple AND its ephemeral suite — no smuggled 4th tuple element.
    /// Call sites bind the FIXTURE (round-4 item 6 — never a
    /// projection off a temporary, so no future write-inside-the-
    /// helper can strand state past a temporary's death) and
    /// destructure `.values` off the binding for zero-churn bodies.
    final class TierSwitcherFixture {
        let viewModel: CoachChatViewModel
        let settings: TierSettingsStore
        let gates: CloudGateCache
        /// Factory-build log (round-7 item 13): proves whether a turn
        /// built a session at all (offers must not). Outside `.values`
        /// so existing destructuring is untouched. Private (file-scoped
        /// visibility covers the same-file tests).
        let log: InstructionLog

        /// Log reader for the orchestrator tests (the property stays
        /// private — `InstructionLog` is private to this file).
        func factoryBuilds() -> [String] { log.all }
        private let ephemeral: EphemeralDefaults

        var values: (CoachChatViewModel, TierSettingsStore, CloudGateCache) {
            (viewModel, settings, gates)
        }

        init(viewModel: CoachChatViewModel, settings: TierSettingsStore, gates: CloudGateCache, log: InstructionLog, ephemeral: EphemeralDefaults) {
            self.viewModel = viewModel
            self.settings = settings
            self.gates = gates
            self.log = log
            self.ephemeral = ephemeral
        }
    }

    /// Call-counted key gate for the TOCTOU defense test (round-7 item
    /// 13): file scope because local types cannot carry Sendable
    /// conformance. Answers true for the first N calls, then false —
    /// modeling a key deleted between the send-guard and dispatch.
    private final class FlipFlopKeyGate: @unchecked Sendable {
        private let lock = NSLock()
        nonisolated(unsafe) private var calls = 0
        private let trueForFirstCalls: Int
        init(trueForFirstCalls: Int) { self.trueForFirstCalls = trueForFirstCalls }
        nonisolated func hasKey(_ tier: ModelTier) -> Bool {
            lock.withLock {
                calls += 1
                return calls <= trueForFirstCalls
            }
        }
    }

    private func makeViewModel(
        liveTiers: Set<ModelTier> = [.onDevice, .privateCloudCompute, .claude],
        log: InstructionLog = InstructionLog(),
        // WP-32 F1: per-tier routing. Nil (default) builds every tier into
        // identical doubles — enough for slot segregation, blind to model
        // identity. A non-nil mapping builds tier-tagged doubles, proving
        // which model served, not just which slot was picked.
        chunks: ((ModelTier) -> [String])? = nil,
        // Round-7 item 13: scripted quota + key presence for the
        // fallback/defense tests (defaults mirror production setup).
        pccQuota: PCCQuota = .ok,
        keyPresent: (@Sendable (ModelTier) -> Bool)? = nil
    ) throws -> TierSwitcherFixture {
        let container = try CoreModel.makeContainer(inMemory: true)
        // Round-3 item 12: the holder rides in the fixture (same commit
        // introduced TipStoreFixture to avoid smuggling it through the
        // tuple). Call sites bind the fixture for the test's duration
        // (round-4 item 6): the holder then outlives every write by
        // construction — no death-before-writes luck, no temporary.
        // Init pre-clean guarantees freshness against same-named
        // survivors; the janitor closes the leak at exit.
        let ephemeral = try EphemeralDefaults(prefix: "tierswitcher")
        let settings = TierSettingsStore(defaults: ephemeral.defaults)
        let gates = CloudGateCache()
        let catalog = ModelCatalog(
            onDeviceAvailable: { true },
            hasConsent: { gates.hasConsent($0) },
            hasKey: keyPresent ?? { gates.hasKey($0) },
            pccAvailable: { true },
            pccQuota: { pccQuota },
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
        return TierSwitcherFixture(viewModel: viewModel, settings: settings, gates: gates, log: log, ephemeral: ephemeral)
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
        let fixture = try makeViewModel()
        let (viewModel, settings, gates) = fixture.values
        enable(.privateCloudCompute, settings: settings, gates: gates)
        #expect(viewModel.enabledTiers == [.onDevice, .privateCloudCompute])
        #expect(viewModel.enabledTierNames == "On-device · Apple cloud (PCC)")
    }

    @Test("selecting a non-enabled tier fails and keeps the selection")
    func selectBlockedTierFails() throws {
        let fixture = try makeViewModel()
        let (viewModel, settings, gates) = fixture.values
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
        let fixture = try makeViewModel()
        let (viewModel, settings, gates) = fixture.values
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
        let fixture = try makeViewModel()
        let (viewModel, settings, gates) = fixture.values
        enable(.privateCloudCompute, settings: settings, gates: gates)
        #expect(viewModel.selectTier(.privateCloudCompute) == true)
        #expect(viewModel.send("hi") == true)
        try await waitForIdle(viewModel)
        #expect(viewModel.turns.count == 2)
        #expect(viewModel.turns[1].provider == ModelTier.privateCloudCompute.rawValue)
    }

    @Test("the transcript survives switches with per-turn stamps")
    func transcriptPreservedAcrossSwitches() async throws {
        let fixture = try makeViewModel()
        let (viewModel, settings, gates) = fixture.values
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
        let fixture = try makeViewModel(log: log)
        let (viewModel, settings, gates) = fixture.values
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
        let fixture = try makeViewModel(chunks: { ["<\($0.rawValue)>"] })
        let (viewModel, settings, gates) = fixture.values
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

    @Test("an unwired tier send surfaces the named error with no reply turn (F1)")
    func unwiredSendIsNamedAndPersistsNothing() async throws {
        // Default-build factory (no injected build): the PCC arm touches
        // no model. PCC live + consented + keyed + toggled, so both guards
        // pass and the fail-closed arm is what answers.
        let container = try CoreModel.makeContainer(inMemory: true)
        let ephemeral = try EphemeralDefaults(prefix: "tierswitcher")
        let settings = TierSettingsStore(defaults: ephemeral.defaults)
        let gates = CloudGateCache()
        let catalog = ModelCatalog(
            onDeviceAvailable: { true },
            hasConsent: { gates.hasConsent($0) },
            hasKey: { gates.hasKey($0) },
            pccAvailable: { true },
            pccQuota: { .ok },
            liveTiers: [.onDevice, .privateCloudCompute]
        )
        let store = KnowledgeStore(
            modelContainer: container,
            healthReadStore: EmptyReadStore(),
            healthKitAuth: HealthKitAuth()
        )
        let viewModel = CoachChatViewModel(deps: CoachChatViewModel.Dependencies(
            container: container,
            store: store,
            prompts: PromptManager(modelContainer: container),
            assembler: ContextAssembler(modelContainer: container),
            factory: CoachSessionFactory(),
            availability: FixedCoachAvailabilityChecker(availability: .available),
            tierSettings: settings,
            tierCatalog: catalog
        ))
        settings.recordConsent(for: .privateCloudCompute)
        gates.setConsent(true, for: .privateCloudCompute)
        settings.setTurnedOn(true, for: .privateCloudCompute)
        #expect(viewModel.selectTier(.privateCloudCompute) == true)
        #expect(viewModel.send("hi") == true)
        try await waitForIdle(viewModel)
        #expect(viewModel.errorMessage == "Apple cloud (PCC) isn't available right now (\(UnwiredTierSession.unwiredReason)).")
        #expect(viewModel.turns.count == 1)
        #expect(viewModel.turns.first?.role == "user")
    }

    @Test("onAppear clamps a selection disabled while chat was away")
    func onAppearClampsStaleSelection() throws {
        let fixture = try makeViewModel()
        let (viewModel, settings, gates) = fixture.values
        enable(.privateCloudCompute, settings: settings, gates: gates)
        #expect(viewModel.selectTier(.privateCloudCompute) == true)
        settings.withdrawConsent(for: .privateCloudCompute)
        gates.setConsent(false, for: .privateCloudCompute)
        viewModel.onAppear()
        #expect(viewModel.selectedTier == .onDevice)
    }

    // MARK: - Orchestrator on the real path (round-7 item 13)

    @Test("exhausted PCC quota falls back to on-device on the real path")
    func quotaFallbackFiresOnRealPath() async throws {
        // Round-7 item 13: PCC selected, quota exhausted — the turn
        // must be SERVED on-device (not blocked, not died) with the
        // provider stamp telling the truth. Pre-routing, quota never
        // ran for real turns (the orchestrator had no caller).
        let fixture = try makeViewModel(pccQuota: .exhausted(resetDate: nil))
        let (viewModel, settings, gates) = fixture.values
        enable(.privateCloudCompute, settings: settings, gates: gates)
        #expect(viewModel.selectTier(.privateCloudCompute) == true)
        #expect(viewModel.send("hi") == true)
        try await waitForCondition({ !viewModel.isResponding })
        #expect(viewModel.turns.count == 2)
        #expect(viewModel.turns[1].content == "Hello world.")
        #expect(viewModel.turns[1].provider == ModelTier.onDevice.rawValue)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("deeper-analysis ask renders an offer row, streams nothing")
    func escalationOfferFiresOnRealPath() async throws {
        // Round-7 item 13: an explicit deeper-analysis ask on-device
        // renders an offer row (with trace snapshot) instead of an
        // answer — and builds no session at all.
        let fixture = try makeViewModel()
        let viewModel = fixture.viewModel
        #expect(viewModel.send("please go deeper into this") == true)
        try await waitForCondition({ !viewModel.isResponding })
        #expect(viewModel.turns.count == 2)
        #expect(viewModel.turns[1].content == CoachChatViewModel.offerMessage(for: .deeperAnalysisRequested, tier: .onDevice))
        #expect(viewModel.turns[1].contextSnapshotID != nil)
        #expect(viewModel.draft.isEmpty)
        #expect(fixture.factoryBuilds().isEmpty)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("key deleted mid-flight fails named, never dispatches keyless")
    func keylessDefenseFiresOnRealPath() async throws {
        // Round-7 item 13: the TOCTOU key deletion between the
        // send-guard (call 2: still present) and dispatch (call 3:
        // gone) must throw before any session build — named error, no
        // reply, no keyless dispatch. The flip-flop models the race
        // deterministically (gated on the current call-count contract
        // of `isEnabled`: one `hasKey` read per evaluation).
        let gate = FlipFlopKeyGate(trueForFirstCalls: 2)
        let fixture = try makeViewModel(keyPresent: gate.hasKey)
        let (viewModel, settings, gates) = fixture.values
        enable(.claude, settings: settings, gates: gates)
        #expect(viewModel.selectTier(.claude) == true)
        #expect(viewModel.send("hi") == true)
        try await waitForCondition({ !viewModel.isResponding })
        #expect(viewModel.turns.count == 1) // user turn only — nothing answered
        #expect(viewModel.errorMessage?.contains("API key") == true)
        #expect(fixture.factoryBuilds().isEmpty)
    }
}
