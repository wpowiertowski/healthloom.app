// CoachChatViewModelTests.swift
// HealthLoomTests
//
// WP-25 review round: unit coverage for the view-model rules the UI test
// can't reach deterministically -- newest-first cap ordering (#1),
// stop-before-first-token leaves no empty turn (#2), mid-stream errors
// persist the visible partial and report (#2), stop truncates the stream
// (#2/#3), and `send` reports queuing failures (#4).

import CoachKit
import CoreModel
import Foundation
import FoundationModels
import SwiftData
import SyncKit
import Testing
@testable import HealthLoom

// Shared doubles (`EmptyReadStore`, `TestCoachSession`, `StreamBoom`)
// live in TestDoubles.swift (WP-30 N3).

private struct WaitTimeout: Error {}

/// Structural fixture (round-3 item 12): owns the view model
/// AND its ephemeral suite. Call sites bind the FIXTURE (round-4 item
/// 6 — never a projection off a temporary) and read `.viewModel` off
/// the binding — bodies otherwise untouched, no defers.
@MainActor
final class CoachChatFixture {
    let viewModel: CoachChatViewModel
    private let ephemeral: EphemeralDefaults

    init(viewModel: CoachChatViewModel, ephemeral: EphemeralDefaults) {
        self.viewModel = viewModel
        self.ephemeral = ephemeral
    }
}

@MainActor
private func makeCoachViewModel(
    session: any CoachSession,
    availability: CoachAvailability = .available,
    container: ModelContainer? = nil
) throws -> CoachChatFixture {
    let container = try container ?? CoreModel.makeContainer(inMemory: true)
    // Round-3 item 12: the holder rides in the fixture (same
    // treatment as TierSwitcherFixture). The view model holds its
    // own defaults ref, so a fixture temporary at the call site is
    // safe (init pre-clean + janitor backstop — see TierSwitcher).
    let ephemeral = try EphemeralDefaults(prefix: "coachchat")
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
        factory: CoachSessionFactory(build: { _, _, _ in session }),
        availability: FixedCoachAvailabilityChecker(availability: availability),
        tierSettings: TierSettingsStore(defaults: ephemeral.defaults),
        tierCatalog: ModelCatalog(onDeviceAvailable: { true })
    ))
    return CoachChatFixture(viewModel: viewModel, ephemeral: ephemeral)
}
@MainActor
@Suite("CoachChatViewModel")
struct CoachChatViewModelTests {




    @Test("onAppear prewarms the session for first-token latency")
    func onAppearPrewarms() async throws {
        let probe = PrewarmProbeSession()
        let coachFixture = try makeCoachViewModel(session: probe)
        let viewModel = coachFixture.viewModel
        viewModel.onAppear()
        // The warm-up Task races the assertion; poll, don't assume.
        try await waitForCondition({ probe.prewarmCount > 0 })
        #expect(probe.prewarmCount == 1)
    }

    @Test("send streams the reply and links its context snapshot")
    func sendStreamsAndLinks() async throws {
        let coachFixture = try makeCoachViewModel(session: TestCoachSession())
        let viewModel = coachFixture.viewModel
        #expect(viewModel.send("hi") == true)
        try await waitForCondition({ !viewModel.isResponding })
        #expect(viewModel.turns.count == 2)
        #expect(viewModel.turns[0].role == "user")
        #expect(viewModel.turns[1].content == "Hello world.")
        #expect(viewModel.turns[1].contextSnapshotID != nil)
        #expect(viewModel.errorMessage == nil)
        // The linked snapshot decodes through the shared accessor.
        #expect(viewModel.resolveSharedContext(for: viewModel.turns[1]) == [])
    }

    @Test("history past the cap keeps the newest turns, not the oldest")
    func capKeepsNewest() async throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0 ..< (CoachChatViewModel.maxLoadedTurns + 5) {
            context.insert(ChatTurn(
                role: "user",
                content: "turn \(i)",
                createdAt: base.addingTimeInterval(Double(i))
            ))
        }
        try context.save()
        let coachFixture = try makeCoachViewModel(
            session: TestCoachSession(),
            container: container
        )
        let viewModel = coachFixture.viewModel
        viewModel.onAppear()
        #expect(viewModel.turns.count == CoachChatViewModel.maxLoadedTurns)
        #expect(viewModel.turns.first?.content == "turn 5")
        #expect(viewModel.turns.last?.content == "turn \(CoachChatViewModel.maxLoadedTurns + 4)")
    }

    @Test("stopping before the first token persists no empty turn")
    func stopBeforeFirstToken() async throws {
        let coachFixture = try makeCoachViewModel(session: TestCoachSession(suspendForever: true))
        let viewModel = coachFixture.viewModel
        #expect(viewModel.send("hi") == true)
        try await waitForCondition({ viewModel.isResponding })
        viewModel.stop()
        try await waitForCondition({ !viewModel.isResponding })
        #expect(viewModel.turns.count == 1)
        #expect(viewModel.turns[0].role == "user")
        #expect(viewModel.errorMessage == nil)
    }

    @Test("mid-stream error persists the visible partial and reports")
    func midStreamError() async throws {
        let coachFixture = try makeCoachViewModel(session: TestCoachSession(
            chunks: ["part ", "rest."],
            failAfterChunks: 1
        ))
        let viewModel = coachFixture.viewModel
        #expect(viewModel.send("hi") == true)
        try await waitForCondition({ !viewModel.isResponding })
        #expect(viewModel.turns.count == 2)
        #expect(viewModel.turns[1].content == "part ")
        #expect(viewModel.errorMessage?.contains("couldn't reply") == true)
    }

    @Test("stop truncates the stream to a non-empty partial")
    func stopTruncates() async throws {
        let coachFixture = try makeCoachViewModel(session: TestCoachSession(
            chunks: ["one ", "two ", "three ", "four."],
            chunkDelay: .milliseconds(200)
        ))
        let viewModel = coachFixture.viewModel
        #expect(viewModel.send("hi") == true)
        try await waitForCondition({ !viewModel.draft.isEmpty })
        viewModel.stop()
        try await waitForCondition({ !viewModel.isResponding })
        #expect(viewModel.turns.count == 2)
        let reply = viewModel.turns[1].content
        #expect(!reply.isEmpty)
        #expect(reply != "one two three four.")
        #expect(viewModel.errorMessage == nil)
    }

    @Test("send reports queuing failures without queueing")
    func sendReportsFailure() async throws {
        // Third-party F15: the .modelNotReady leg lived here AND in the
        // gate loop below — it belongs to the loop (allCases covers it),
        // so this test keeps only the blank-input case it owns.
        let coachFixture = try makeCoachViewModel(session: TestCoachSession())
        let viewModel = coachFixture.viewModel
        #expect(viewModel.send("   ") == false)
        #expect(viewModel.turns.isEmpty)
    }

    // Third-party F8: named for the leg it covers — the no-Apple-
    // Intelligence coach leg of the WP-38 degradation matrix. The other
    // three legs live where their seams are: no-Google-account in
    // DashboardSnapshotTests (nil-state row), HK-denied in
    // TodayMetricsTests (nil readings for every kind), offline sync in
    // SyncEngineTests (transport failure reports per-type error).
    @Test("coach leg: every non-available gate blocks sends with no turns")
    func unavailableGatesBlockCoachSends() async throws {
        for availability in CoachAvailability.allCases.filter({ $0 != .available }) {
            let coachFixture = try makeCoachViewModel(session: TestCoachSession(), availability: availability)
            let viewModel = coachFixture.viewModel
                viewModel.onAppear()
            try await waitForCondition({ viewModel.availability != .available }, timeout: 2)
            #expect(viewModel.send("hi") == false, "gate \(availability) let a send through")
            #expect(viewModel.turns.isEmpty)
        }
    }
}

@Suite("Coach stream survival + launch matrix (WP-25 round-2)")
@MainActor
struct CoachRoundTwoTests {
    @Test("tab switch mid-stream does not truncate the reply")
    func tabSwitchDoesNotTruncate() async throws {
        // Round-3 item 12: routed through the helper (constant session
        // per build ≡ the old constant factory) — the inline
        // construction and its holder are gone.
        let coachFixture = try makeCoachViewModel(
            session: TestCoachSession(chunks: ["one ", "two ", "three."], chunkDelay: .milliseconds(200))
        )
        let viewModel = coachFixture.viewModel
        #expect(viewModel.send("hi") == true)
        try await waitForCondition({ viewModel.isResponding })
        // The view unmounts and remounts; the view model (and its stream)
        // outlives both.
        viewModel.onDisappear()
        viewModel.onAppear()
        try await waitForCondition({ !viewModel.isResponding })
        #expect(viewModel.turns.count == 2)
        #expect(viewModel.turns[1].content == "one two three.")
        #expect(viewModel.errorMessage == nil)
    }

    @Test("stale cached availability aborts before streaming")
    func staleCacheAborts() async throws {
        // No onAppear: the cached value is still the optimistic `.available`
        // while the live gate reports `.modelNotReady`.
        // Round-3 item 12: routed through the helper — see above.
        let container = try CoreModel.makeContainer(inMemory: true)
        let coachFixture = try makeCoachViewModel(
            session: TestCoachSession(),
            availability: .modelNotReady,
            container: container
        )
        let viewModel = coachFixture.viewModel
        #expect(viewModel.send("hi") == true)
        try await waitForCondition({ !viewModel.isResponding })
        #expect(viewModel.errorMessage?.contains("isn't available") == true)
        // The already-queued user turn stays; no assistant turn streams.
        #expect(viewModel.turns.count == 1)
        #expect(viewModel.turns[0].role == "user")
    }

    @Test("launch flag matrix: route, store, and session mode")
    func launchMatrix() {
        // Plain launch: onboarding path, on-disk store, live session.
        var config = LaunchConfiguration.resolve(arguments: [])
        #expect(config.initialRoute == .default)
        #expect(config.useInMemoryContainer == false)
        #expect(config.coachSessionMode == .live)

        // Seed data: Data tab, in-memory.
        config = LaunchConfiguration.resolve(arguments: ["-UITestSeedData"])
        #expect(config.initialRoute == .data)
        #expect(config.useInMemoryContainer == true)

        // Stub Google alone: onboarding happy path untouched (round-2 #2
        // is about the route only -- the in-memory store rule predates
        // this diff and stays).
        config = LaunchConfiguration.resolve(arguments: ["-UITestStubGoogle"])
        #expect(config.initialRoute == .default)
        #expect(config.useInMemoryContainer == true)

        // Scripted coach: Coach tab, ON-DISK store (relaunch leg), scripted.
        config = LaunchConfiguration.resolve(arguments: ["-UITestScriptedCoach"])
        #expect(config.initialRoute == .coach)
        #expect(config.useInMemoryContainer == false)
        #expect(config.coachSessionMode == .scripted)

        // Forced unavailable: Coach tab, in-memory, forced case.
        config = LaunchConfiguration.resolve(arguments: ["-UITestCoachUnavailable"])
        #expect(config.initialRoute == .coach)
        #expect(config.useInMemoryContainer == true)
        #expect(config.coachSessionMode == .forced(.modelNotReady))

        config = LaunchConfiguration.resolve(arguments: ["-UITestCoachUnavailable=deviceNotEligible"])
        #expect(config.coachSessionMode == .forced(.deviceNotEligible))

        // Unknown forced value still renders an unavailable state.
        config = LaunchConfiguration.resolve(arguments: ["-UITestCoachUnavailable=bogus"])
        #expect(config.coachSessionMode == .forced(.modelNotReady))

        // Scripted + forced together: scripted keeps the on-disk store
        // (round-2 #7); forced wins the session (unavailable UI).
        config = LaunchConfiguration.resolve(arguments: ["-UITestScriptedCoach", "-UITestCoachUnavailable"])
        #expect(config.initialRoute == .coach)
        #expect(config.useInMemoryContainer == false)
        #expect(config.coachSessionMode == .forced(.modelNotReady))

        // WP-34: any -UITest* flag marks a UI-test launch (the morning
        // runner stays out); notification stubbing is opt-in per flag.
        config = LaunchConfiguration.resolve(arguments: [])
        #expect(config.isUITest == false)
        config = LaunchConfiguration.resolve(arguments: ["-UITestSeedData"])
        #expect(config.isUITest == true)
        #expect(config.stubNotifications == false)
        config = LaunchConfiguration.resolve(arguments: ["-UITestSeedData", "-UITestStubNotifications"])
        #expect(config.isUITest == true)
        #expect(config.stubNotifications == true)
        #expect(config.denyNotifications == false)
        config = LaunchConfiguration.resolve(arguments: ["-UITestNotificationsDenied"])
        #expect(config.denyNotifications == true)

        // Round-3 items 3+4+5: the tips-stub parser matrix — absent (no
        // stub, out of the container disjunction), bare `=` (legacy
        // single-empty), bare flag (mirrors aiModelsScenario), unknown
        // token (safe fallback), FIFO order, and the container rule.
        config = LaunchConfiguration.resolve(arguments: [])
        #expect(config.tipsStub == [])
        config = LaunchConfiguration.resolve(arguments: ["-UITestTipsStub="])
        #expect(config.tipsStub == [.emptyProducts])
        config = LaunchConfiguration.resolve(arguments: ["-UITestTipsStub"])
        #expect(config.tipsStub == [.emptyProducts])
        config = LaunchConfiguration.resolve(arguments: ["-UITestTipsStub=bogus"])
        #expect(config.tipsStub == [.emptyProducts])
        config = LaunchConfiguration.resolve(arguments: ["-UITestTipsStub=failed,empty"])
        #expect(config.tipsStub == [.failed, .emptyProducts])
        #expect(config.useInMemoryContainer == true)
        // Round-4 item 13: typo'd kin still stub (never strand on the
        // live fetch) — values parse uniformly off the matched name.
        config = LaunchConfiguration.resolve(arguments: ["-UITestTipStub=failed"])
        #expect(config.tipsStub == [.failed])
        #expect(config.useInMemoryContainer == true)
        config = LaunchConfiguration.resolve(arguments: ["-UITestTipStub"])
        #expect(config.tipsStub == [.emptyProducts])
        #expect(config.useInMemoryContainer == true)
    }
}

/// Shared poll helper for the chat suites (file scope so every suite in
/// this file can use it).
@MainActor
private func waitForCondition(
    _ condition: @MainActor @escaping () -> Bool,
    timeout: TimeInterval = 10
) async throws {
    let start = Date.now
    while !condition() {
        try await Task.sleep(for: .milliseconds(20))
        if Date.now.timeIntervalSince(start) > timeout {
            throw WaitTimeout()
        }
    }
}

@Suite("PromptEditorViewModel (WP-26)")
@MainActor
struct PromptEditorViewModelTests {
    private func makeEditor(factory: CoachSessionFactory? = nil) throws -> PromptEditorViewModel {
        let container = try CoreModel.makeContainer(inMemory: true)
        return PromptEditorViewModel(deps: PromptEditorViewModel.Dependencies(
            manager: PromptManager(modelContainer: container),
            factory: factory ?? CoachSessionFactory()
        ))
    }

    @Test("load starts from the shipped default with empty history")
    func loadDefaults() throws {
        let editor = try makeEditor()
        editor.load()
        #expect(editor.baseText == PromptManager.defaultPrompt)
        #expect(editor.history.isEmpty)
        #expect(editor.matchesDefault)
        #expect(editor.hasUnsavedChanges == false)
        #expect(editor.errorMessage == nil)
    }

    @Test("live values derive from the working copy")
    func liveValues() throws {
        let editor = try makeEditor()
        editor.load()
        editor.baseText += " More."
        #expect(editor.hasUnsavedChanges == true)
        #expect(editor.matchesDefault == false)
        #expect(editor.estimatedTokens == PromptManager.estimatedTokens(for: editor.baseText))
        #expect(editor.effectivePreview == PromptManager.effectivePrompt(base: editor.baseText))
        #expect(editor.effectivePreview.hasSuffix(SafetyLayer.text))
    }

    @Test("save persists, resets the dirty flag, and lists history")
    func saveFlow() throws {
        let editor = try makeEditor()
        editor.load()
        editor.baseText += " More."
        #expect(editor.save() == true)
        #expect(editor.hasUnsavedChanges == false)
        #expect(editor.history.count == 1)
        #expect(editor.history[0].body.hasSuffix("More."))
        #expect(editor.notice == "Saved.")
    }

    @Test("empty save fails loudly and writes nothing")
    func emptySaveFails() throws {
        let editor = try makeEditor()
        editor.load()
        editor.baseText = "   "
        #expect(editor.save() == false)
        #expect(editor.errorMessage == "The prompt can't be empty.")
        #expect(editor.history.isEmpty)
    }

    @Test("reset restores the default; restore reaches pre-reset edits")
    func resetAndRestore() throws {
        let editor = try makeEditor()
        editor.load()
        editor.baseText += " More."
        #expect(editor.save() == true)
        editor.resetToDefault()
        #expect(editor.baseText == PromptManager.defaultPrompt)
        #expect(editor.matchesDefault)
        #expect(editor.history.count == 2)
        editor.restore(editor.history[1])
        #expect(editor.baseText.hasSuffix("More."))
        #expect(editor.history.count == 3)
    }

    @Test("diff engine: identical, added, removed, mixed")
    func diffEngine() {
        typealias D = PromptEditorViewModel.DiffLine
        #expect(PromptEditorViewModel.diffLines(default: "a\nb", current: "a\nb") == [.common("a"), .common("b")])
        #expect(PromptEditorViewModel.diffLines(default: "a", current: "a\nb") == [.common("a"), .added("b")])
        #expect(PromptEditorViewModel.diffLines(default: "a\nb", current: "a") == [.common("a"), .removed("b")])
        #expect(PromptEditorViewModel.diffLines(default: "a\nb\nc", current: "a\nx\nc") == [
            .common("a"), .removed("b"), .added("x"), .common("c"),
        ])
        #expect(PromptEditorViewModel.diffLines(default: "", current: "") == [.common("")])
    }
}

@Suite("Prompt editor round-2 (WP-26 review)")
@MainActor
struct PromptEditorRoundTwoTests {
    private func makeEditor(factory: CoachSessionFactory? = nil) throws -> PromptEditorViewModel {
        let container = try CoreModel.makeContainer(inMemory: true)
        return PromptEditorViewModel(deps: PromptEditorViewModel.Dependencies(
            manager: PromptManager(modelContainer: container),
            factory: factory ?? CoachSessionFactory()
        ))
    }

    @Test("successful writes bust the cached conversation session")
    func writesBustSessionCache() throws {
        let factory = CoachSessionFactory(build: { _, _, _ in TestCoachSession() })
        let editor = try makeEditor(factory: factory)
        editor.load()
        // Same instructions twice: cached without an intervening write.
        let first = factory.makeSession(for: .conversation, instructions: "fixed", tools: [])
        let cached = factory.makeSession(for: .conversation, instructions: "fixed", tools: [])
        #expect(first === cached)
        editor.baseText += " More."
        #expect(editor.save() == true)
        let second = factory.makeSession(for: .conversation, instructions: "fixed", tools: [])
        #expect(second !== first)
    }

    @Test("a failed save clears the stale notice and writes nothing")
    func failedSaveClearsNotice() throws {
        let editor = try makeEditor()
        editor.load()
        editor.baseText += " More."
        #expect(editor.save() == true)
        #expect(editor.notice == "Saved.")
        editor.baseText = "   "
        #expect(editor.save() == false)
        #expect(editor.notice == nil)
        #expect(editor.errorMessage == "The prompt can't be empty.")
        #expect(editor.history.count == 1)
    }

    @Test("reset is disabled when it would change nothing")
    func resetGuard() throws {
        let editor = try makeEditor()
        editor.load()
        // Fresh: working copy matches the default, nothing unsaved.
        #expect(editor.canReset == false)
        editor.baseText += " More."
        #expect(editor.canReset == true)
        #expect(editor.save() == true)
        // Saved a real change: current differs from default.
        #expect(editor.canReset == true)
        editor.resetToDefault()
        // Post-reset: working copy matches default again.
        #expect(editor.canReset == false)
        #expect(editor.history.count == 2)
    }

    @Test("token estimate measures the validated trimmed string")
    func trimmedEstimate() throws {
        let editor = try makeEditor()
        editor.load()
        editor.baseText = "hello   \n\n"
        #expect(editor.estimatedTokens == PromptManager.estimatedTokens(for: "hello"))
    }

    @Test("preview base derives from the effective assembly")
    func previewBaseDerives() throws {
        let editor = try makeEditor()
        editor.load()
        editor.baseText += " More."
        #expect(editor.previewBase == editor.baseText)
        #expect(editor.effectivePreview == editor.previewBase + "\n\n" + SafetyLayer.text)
    }
}

@Suite("Prompt editor no-op writes + history cap (WP-26 round-2)")
@MainActor
struct PromptEditorNoOpTests {
    private func makeEditor(factory: CoachSessionFactory? = nil) throws -> PromptEditorViewModel {
        let container = try CoreModel.makeContainer(inMemory: true)
        return PromptEditorViewModel(deps: PromptEditorViewModel.Dependencies(
            manager: PromptManager(modelContainer: container),
            factory: factory ?? CoachSessionFactory()
        ))
    }

    @Test("whitespace-only save writes no row and normalizes")
    func whitespaceNoOp() throws {
        let factory = CoachSessionFactory(build: { _, _, _ in TestCoachSession() })
        let editor = try makeEditor(factory: factory)
        editor.load()
        editor.baseText = PromptManager.defaultPrompt + "   \n"
        #expect(editor.save() == true)
        #expect(editor.history.isEmpty)
        #expect(editor.baseText == PromptManager.defaultPrompt)
        #expect(editor.hasUnsavedChanges == false)
        #expect(editor.notice == "Already up to date.")
        #expect(editor.errorMessage == nil)
    }

    @Test("restoring the active version writes no row and keeps the session")
    func restoreCurrentNoOp() throws {
        let factory = CoachSessionFactory(build: { _, _, _ in TestCoachSession() })
        let editor = try makeEditor(factory: factory)
        editor.load()
        editor.baseText += " More."
        #expect(editor.save() == true)
        #expect(editor.history.count == 1)
        let active = factory.makeSession(for: .conversation, instructions: "fixed", tools: [])
        editor.restore(editor.history[0])
        #expect(editor.history.count == 1)
        #expect(editor.notice == "Already using this version.")
        // No-op restore must not disturb the cached session either.
        #expect(factory.makeSession(for: .conversation, instructions: "fixed", tools: []) === active)
    }

    @Test("reset with a dirty draft but default effect drops the draft rowless")
    func resetDiscardsDraft() throws {
        let editor = try makeEditor()
        editor.load()
        editor.baseText += " never mind"
        editor.resetToDefault()
        #expect(editor.baseText == PromptManager.defaultPrompt)
        #expect(editor.history.isEmpty)
        #expect(editor.notice == "Discarded unsaved changes.")
    }

    @Test("in-memory history honors the fetch's row bound")
    func historyCapped() throws {
        let editor = try makeEditor()
        editor.load()
        for i in 0 ..< 105 {
            editor.baseText = "version \(i)"
            #expect(editor.save() == true)
        }
        #expect(editor.history.count == 100)
        #expect(editor.history[0].body == "version 104")
    }
}
