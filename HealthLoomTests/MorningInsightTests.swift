// MorningInsightTests.swift
//
// WP-34 (implementation-plan.md) "Tests:" line: scheduling pure function,
// tier routing, notification redaction, and the runner's gate chain
// through scripted doubles — never the model, never HealthKit, never the
// real notification center. The permission-flow UI test lives in
// `HealthLoomUITests/InsightUITests.swift` (stubbed center).

import CoachKit
import CoreModel
import Foundation
import FoundationModels
import SwiftData
import Testing
@testable import HealthLoom

// MARK: - Scheduling (pure)

@Suite("InsightPreferences init")
struct InsightPreferencesInitTests {
    // Regression (found via iCloud-sync testing): `@Observable` `didSet`
    // fires during `init` on this toolchain, so assigning
    // `morningInsightsEnabled` persisted the still-default later fields
    // OVER their stored values — every launch reset lockDetails/viaCloud/
    // lastRun whenever insights were enabled. Init must be read-only.
    @Test("init from populated defaults preserves every field")
    func initPreservesAllFields() throws {
        let ephemeralInit = try EphemeralDefaults(prefix: "morninginsight-init")
        let defaults = ephemeralInit.defaults
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        let first = InsightPreferences(defaults: defaults)
        first.morningInsightsEnabled = true
        first.lockScreenDetails = true
        first.insightsViaCloud = true
        first.lastRun = stamp
        let second = InsightPreferences(defaults: defaults)
        #expect(second.morningInsightsEnabled)
        #expect(second.lockScreenDetails)
        #expect(second.insightsViaCloud)
        #expect(second.lastRun == stamp)
    }
}

@Suite("InsightScheduler")
struct InsightSchedulerTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func date(_ string: String) -> Date? {
        dateFormatter().date(from: string)
    }

    /// Fixed-locale parsing (N2): month names and separators must not depend
    /// on the test host's locale.
    private func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = calendar.timeZone
        return formatter
    }

    @Test("first run after 5am fires, before does not") func firstRunWindow() throws {
        let morning = try #require(date("2026-09-08 06:30"))
        let early = try #require(date("2026-09-08 04:59"))
        let boundary = try #require(date("2026-09-08 05:00"))
        #expect(InsightScheduler.shouldRun(lastRun: nil, now: morning, calendar: calendar))
        #expect(!InsightScheduler.shouldRun(lastRun: nil, now: early, calendar: calendar))
        #expect(InsightScheduler.shouldRun(lastRun: nil, now: boundary, calendar: calendar))
    }

    @Test("one run per calendar day") func onceDaily() throws {
        let todayMorning = try #require(date("2026-09-08 06:00"))
        let todayEvening = try #require(date("2026-09-08 18:00"))
        let tomorrowMorning = try #require(date("2026-09-09 06:00"))
        #expect(!InsightScheduler.shouldRun(lastRun: todayMorning, now: todayEvening, calendar: calendar))
        #expect(InsightScheduler.shouldRun(lastRun: todayMorning, now: tomorrowMorning, calendar: calendar))
    }

    @Test("sync gate needs a post-5am completion") func syncGate() throws {
        let now = try #require(date("2026-09-08 08:00"))
        #expect(!InsightScheduler.syncAllowsRun(lastSync: nil, now: now, calendar: calendar))
        let lastNight = try #require(date("2026-09-07 23:00"))
        #expect(!InsightScheduler.syncAllowsRun(lastSync: lastNight, now: now, calendar: calendar))
        let preDawn = try #require(date("2026-09-08 04:00"))
        #expect(!InsightScheduler.syncAllowsRun(lastSync: preDawn, now: now, calendar: calendar))
        let dawn = try #require(date("2026-09-08 06:00"))
        #expect(InsightScheduler.syncAllowsRun(lastSync: dawn, now: now, calendar: calendar))
        let future = try #require(date("2026-09-08 09:00"))
        #expect(!InsightScheduler.syncAllowsRun(lastSync: future, now: now, calendar: calendar))
    }
}

// MARK: - Tier routing (pure)

@Suite("InsightTierRouter")
struct InsightTierRouterTests {
    @Test("PCC needs tier, consent-gated enablement, and the separate opt-in")
    func pccNeedsAllThree() {
        #expect(InsightTierRouter.route(pccTierEnabled: true, viaCloudOptIn: true, onDeviceAvailable: true)
            == .privateCloudCompute)
        // Missing opt-in falls back to on-device — never widens silently.
        #expect(InsightTierRouter.route(pccTierEnabled: true, viaCloudOptIn: false, onDeviceAvailable: true)
            == .onDevice)
        #expect(InsightTierRouter.route(pccTierEnabled: false, viaCloudOptIn: true, onDeviceAvailable: true)
            == .onDevice)
    }

    @Test("nothing available routes nowhere")
    func noTier() {
        #expect(InsightTierRouter.route(pccTierEnabled: false, viaCloudOptIn: false, onDeviceAvailable: false)
            == nil)
        // PCC alone still serves when on-device is down.
        #expect(InsightTierRouter.route(pccTierEnabled: true, viaCloudOptIn: true, onDeviceAvailable: false)
            == .privateCloudCompute)
    }
}

// MARK: - Notification content (pure, redaction at construction)

@Suite("InsightNotificationContent")
struct InsightNotificationContentTests {
    @Test("headline-only mode carries no numeric tokens")
    func headlineOnlyRedacts() {
        let built = InsightNotificationContent.make(
            headline: "Resting heart rate is down 4 bpm on 8,240 steps",
            suggestions: ["Walk after lunch."],
            fullText: false
        )
        #expect(built.title == "Your morning insight is ready")
        #expect(!built.body.contains(where: { $0.isNumber }))
        #expect(built.body.contains("Resting heart rate is down"))
    }

    @Test("full-text mode is verbatim")
    func fullTextVerbatim() {
        let built = InsightNotificationContent.make(
            headline: "Steady day.",
            suggestions: ["Walk 8,240 steps.", "Lights out."],
            fullText: true
        )
        #expect(built.title == "Your morning insight")
        #expect(built.body.contains("8,240"))
    }

    @Test("redaction treats comma numbers as one token")
    func commaNumbers() {
        #expect(InsightNotificationContent.redacted("8,240 steps") == "• steps")
        #expect(InsightNotificationContent.redacted("172.4 lb") == "• lb")
    }
}

// MARK: - Runner (scripted doubles)

/// `CoachSession` returning one fixed insight (generation path without a
/// model). File scope: local types cannot carry protocol conformances.
private final class ScriptedInsightSession: CoachSession, Sendable {
    let insight: DailyInsight

    init(_ insight: DailyInsight) {
        self.insight = insight
    }

    var isResponding: Bool { false }
    func prewarm() {}
    func respond(to prompt: String) async throws -> String { "ok" }
    func respond<Content: Generable>(to prompt: String, generating type: Content.Type) async throws -> Content {
        guard let casted = insight as? Content else { throw StreamBoom() }
        return casted
    }
    func stream(to prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// Always-throwing session for the runner's failure path.
private final class ThrowingSession: CoachSession, Sendable {
    struct Boom: Error {}
    var isResponding: Bool { false }
    func prewarm() {}
    func respond(to prompt: String) async throws -> String { throw Boom() }
    func respond<Content: Generable>(to prompt: String, generating type: Content.Type) async throws -> Content {
        throw Boom()
    }
    func stream(to prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: Boom()) }
    }
}

/// Scripted route answers for the TOCTOU test. An actor (not a locked
/// class): the runner's route closure is async, so `await` fits
/// naturally, and actor isolation replaces the lock.
private actor TierScript {
    private var answers: [ModelTier?]

    init(_ answers: [ModelTier?]) {
        self.answers = answers
    }

    func next() -> ModelTier? {
        guard !answers.isEmpty else { return nil }
        return answers.removeFirst() ?? nil
    }
}

@Suite("MorningInsightRunner")
@MainActor
struct MorningInsightRunnerTests {
    static func makeDefaults() throws -> EphemeralDefaults {
        try EphemeralDefaults(prefix: "morninginsight")
    }

    static func at(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: string)
    }

    static func signalInputs() -> ReadinessInputs {
        var inputs = ReadinessInputs()
        inputs.hrvRatio = 1.0
        inputs.restingHRDeltaBeatsPerMinute = 0
        inputs.sleepHours = 7.5
        inputs.sleepEfficiency = 0.9
        return inputs
    }

    static func scriptedInsight() -> DailyInsight {
        DailyInsight(headline: "Steady at 78.", suggestions: ["Walk 8,240 steps."], effortLevel: "moderate")
    }

    static func testCatalog() -> ModelCatalog {
        ModelCatalog(
            onDeviceAvailable: { true },
            hasConsent: { _ in false },
            hasKey: { _ in false },
            pccAvailable: { false },
            pccQuota: { .ok },
            liveTiers: [.onDevice]
        )
    }

    private func makePrefs(in defaults: UserDefaults, enabled: Bool) -> InsightPreferences {
        let prefs = InsightPreferences(defaults: defaults)
        prefs.morningInsightsEnabled = enabled
        return prefs
    }

    private func makeRunner(
        container: ModelContainer,
        defaults: UserDefaults,
        prefs: InsightPreferences? = nil,
        enabled: Bool = true,
        notifier: StubInsightNotifier,
        tier: TierScript? = nil,
        inputs: ReadinessInputs? = nil,
        factory: CoachSessionFactory? = nil,
        now: Date
    ) -> (MorningInsightRunner, InsightPreferences) {
        let prefs = prefs ?? makePrefs(in: defaults, enabled: enabled)
        let session = ScriptedInsightSession(Self.scriptedInsight())
        let runner = MorningInsightRunner(deps: MorningInsightRunner.Dependencies(
            container: container,
            prefs: prefs,
            notifier: notifier,
            factory: factory ?? CoachSessionFactory(build: { _, _, _ in session }),
            assembler: ContextAssembler(modelContainer: container),
            promptManager: PromptManager(modelContainer: container),
            history: ReadinessScoreHistory(defaults: defaults),
            availability: FixedCoachAvailabilityChecker(availability: .available),
            catalog: Self.testCatalog(),
            // No script means on-device; a scripted nil stays nil (a
            // `?? .onDevice` here would mask the no-tier answer).
            routeTier: {
                guard let tier else { return .onDevice }
                return await tier.next()
            },
            // Nil inputs mean empty inputs (the `.noSignals` path) —
            // tests wanting signals pass them explicitly.
            readInputs: { await MainActor.run { inputs ?? ReadinessInputs() } },
            now: { now },
            calendar: .current
        ))
        return (runner, prefs)
    }

    private func seedSync(container: ModelContainer, at date: Date) throws {
        let context = ModelContext(container)
        context.insert(SyncState(dataType: GoogleDataType.steps.rawValue, lastSyncedAt: date))
        try context.save()
    }

    @Test("full run persists, notifies redacted, and records") func fullRun() async throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let ephemeral1 = try Self.makeDefaults()
        let defaults = ephemeral1.defaults
        let now = try #require(Self.at("2026-09-08 08:00"))
        let notifier = StubInsightNotifier(status: .authorized)
        try seedSync(container: container, at: try #require(Self.at("2026-09-08 06:00")))
        let (runner, prefs) = makeRunner(
            container: container, defaults: defaults, enabled: true,
            notifier: notifier, inputs: Self.signalInputs(), now: now
        )

        #expect(await runner.runIfDue() == .ran(tier: .onDevice))

        let context = ModelContext(container)
        let insights = try context.fetch(FetchDescriptor<DerivedInsight>())
        #expect(insights.count == 1)
        #expect(insights.first?.sourceProvider.hasPrefix("morningInsight") == true)
        // Headline-only default: numbers redacted on the lock-screen body.
        let body = try #require(notifier.scheduled.first?.body)
        #expect(!body.contains(where: { $0.isNumber }))
        #expect(prefs.lastRun != nil)
        // Once-daily: a second call skips.
        #expect(await runner.runIfDue() == .skipped(.notDue))
    }

    @Test("every gate skips with its own reason") func gates() async throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let syncDate = try #require(Self.at("2026-09-08 06:00"))
        let now = try #require(Self.at("2026-09-08 08:00"))

        // Disabled.
        let ephemeral2 = try Self.makeDefaults()
        let (offRunner, _) = makeRunner(
            container: container, defaults: ephemeral2.defaults, enabled: false,
            notifier: StubInsightNotifier(status: .authorized),
            inputs: Self.signalInputs(), now: now
        )
        #expect(await offRunner.runIfDue() == .skipped(.disabled))

        // Not due (ran today).
        let ephemeral3 = try Self.makeDefaults()
        let doneDefaults = ephemeral3.defaults
        let (doneRunner, donePrefs) = makeRunner(
            container: container, defaults: doneDefaults, enabled: true,
            notifier: StubInsightNotifier(status: .authorized),
            inputs: Self.signalInputs(), now: now
        )
        donePrefs.lastRun = now
        #expect(await doneRunner.runIfDue() == .skipped(.notDue))

        // No fresh sync.
        let ephemeral4 = try Self.makeDefaults()
        let (staleRunner, _) = makeRunner(
            container: container, defaults: ephemeral4.defaults, enabled: true,
            notifier: StubInsightNotifier(status: .authorized),
            inputs: Self.signalInputs(), now: now
        )
        #expect(await staleRunner.runIfDue() == .skipped(.noFreshSync))

        // Fresh sync from here on.
        try seedSync(container: container, at: syncDate)

        // No tier.
        let ephemeral5 = try Self.makeDefaults()
        let (noTierRunner, _) = makeRunner(
            container: container, defaults: ephemeral5.defaults, enabled: true,
            notifier: StubInsightNotifier(status: .authorized),
            tier: TierScript([nil]),
            inputs: Self.signalInputs(), now: now
        )
        #expect(await noTierRunner.runIfDue() == .skipped(.noTier))

        // Unauthorized (never requests inside the runner).
        let ephemeral6 = try Self.makeDefaults()
        let (deniedRunner, _) = makeRunner(
            container: container, defaults: ephemeral6.defaults, enabled: true,
            notifier: StubInsightNotifier(status: .denied),
            inputs: Self.signalInputs(), now: now
        )
        #expect(await deniedRunner.runIfDue() == .skipped(.unauthorized))

        // No signals.
        let ephemeral7 = try Self.makeDefaults()
        let (emptyRunner, _) = makeRunner(
            container: container, defaults: ephemeral7.defaults, enabled: true,
            notifier: StubInsightNotifier(status: .authorized), now: now
        )
        #expect(await emptyRunner.runIfDue() == .skipped(.noSignals))
    }

    @Test("runner sees Settings writes without relaunch (F1)") func seesFreshToggles() async throws {
        // The app wiring holds TWO instances on one defaults domain
        // (Settings' copy + the runner's); flipping through one must be
        // visible to the other after the runner's reload.
        let container = try CoreModel.makeContainer(inMemory: true)
        try seedSync(container: container, at: try #require(Self.at("2026-09-08 06:00")))
        let ephemeral8 = try Self.makeDefaults()
        let defaults = ephemeral8.defaults
        let now = try #require(Self.at("2026-09-08 08:00"))
        let settingsCopy = makePrefs(in: defaults, enabled: false)
        let (runner, runnerCopy) = makeRunner(
            container: container, defaults: defaults,
            prefs: InsightPreferences(defaults: defaults),
            notifier: StubInsightNotifier(status: .authorized),
            inputs: Self.signalInputs(), now: now
        )
        #expect(runnerCopy.morningInsightsEnabled == false)
        // The user enables in Settings (a different instance).
        settingsCopy.morningInsightsEnabled = true
        #expect(await runner.runIfDue() == .ran(tier: .onDevice))
    }

    @Test("tier flip mid-flight aborts") func toctou() async throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        try seedSync(container: container, at: try #require(Self.at("2026-09-08 06:00")))
        let ephemeral9 = try Self.makeDefaults()
        let defaults = ephemeral9.defaults
        let now = try #require(Self.at("2026-09-08 08:00"))
        let (runner, prefs) = makeRunner(
            container: container, defaults: defaults, enabled: true,
            notifier: StubInsightNotifier(status: .authorized),
            tier: TierScript([.onDevice, nil]),
            inputs: Self.signalInputs(), now: now
        )
        #expect(await runner.runIfDue() == .skipped(.tierChangedMidFlight))
        #expect(prefs.lastRun == nil)
    }

    @Test("notify failure keeps the row but unmarks the day (F5)") func notifyFailureDedupes() async throws {
        struct NotifyBoom: Error {}
        let container = try CoreModel.makeContainer(inMemory: true)
        try seedSync(container: container, at: try #require(Self.at("2026-09-08 06:00")))
        let ephemeral10 = try Self.makeDefaults()
        let defaults = ephemeral10.defaults
        let now = try #require(Self.at("2026-09-08 08:00"))
        let notifier = StubInsightNotifier(status: .authorized)
        notifier.scheduleError = NotifyBoom()
        let (runner, prefs) = makeRunner(
            container: container, defaults: defaults, enabled: true,
            notifier: notifier, inputs: Self.signalInputs(), now: now
        )
        // Persist happened, notify threw: failed, day unmarked.
        let outcome = await runner.runIfDue()
        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(prefs.lastRun == nil)
        let context = ModelContext(container)
        #expect(try context.fetch(FetchDescriptor<DerivedInsight>()).count == 1)
        // Retry after the outage: succeeds, still exactly one row.
        notifier.scheduleError = nil
        #expect(await runner.runIfDue() == .ran(tier: .onDevice))
        #expect(try context.fetch(FetchDescriptor<DerivedInsight>()).count == 1)
    }

    @Test("generation failure records nothing") func failure() async throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        try seedSync(container: container, at: try #require(Self.at("2026-09-08 06:00")))
        let ephemeral11 = try Self.makeDefaults()
        let defaults = ephemeral11.defaults
        let now = try #require(Self.at("2026-09-08 08:00"))
        let factory = CoachSessionFactory(build: { _, _, _ in ThrowingSession() })
        let (runner, prefs) = makeRunner(
            container: container, defaults: defaults, enabled: true,
            notifier: StubInsightNotifier(status: .authorized),
            inputs: Self.signalInputs(), factory: factory, now: now
        )
        let outcome = await runner.runIfDue()
        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(prefs.lastRun == nil)
    }
}
