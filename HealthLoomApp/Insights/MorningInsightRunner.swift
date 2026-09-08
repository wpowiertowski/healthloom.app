// MorningInsightRunner.swift
//
// WP-34 (implementation-plan.md): the unattended morning-insight pipeline.
// One function, ordered gates, each with a named skip reason:
//
//   enabled? → due today (5am+)? → sync fresh since 5am? → tier routed?
//   → notification authorized? → readiness signals? → tier re-checked at
//   dispatch (TOCTOU: gates can flip between scheduling and serving —
//   consent withdrawn mid-flight must not serve PCC) → generate → persist
//   → notify → record.
//
// The runner never requests notification permission itself: the only
// in-context moment is the Settings toggle ("in context, not at launch"),
// so an unauthorized status is a skip, not a prompt. Failures record
// nothing — the next launch retries.
//
// Invocation (both call the same entry; the once-daily guard dedupes):
// foreground `scenePhase(.active)` for the usual case, and the BG-sync
// completion path (via `InsightRunnerHost`, the Sendable holder below —
// the static BG context can't capture `AppEnvironment`) for overnights.
// PCC generation inside a BG task is attempted like any other tier; a
// time-box failure surfaces as `.failed` and the foreground retry covers
// it, since nothing is recorded on failure.

import CoachKit
import CoreModel
import Foundation
import SwiftData

@MainActor
struct MorningInsightRunner {
    /// `sourceProvider` stamped on persisted insights. A namespace, not a
    /// `ProviderID`: these rows are insight deliveries, and the tier that
    /// served is in the trace (WP-30 reads `ChatTurn`, not this).
    static let insightSourceProvider = "morningInsight"

    enum SkipReason: Equatable {
        case disabled
        case notDue
        case noFreshSync
        case noTier
        case tierChangedMidFlight
        case unauthorized
        case noSignals
    }

    // `failed` carries the message as a String (not Error) so the outcome
    // stays Equatable for tests — the message is diagnostics, identity is
    // the case.
    enum Outcome: Equatable {
        case ran(tier: ModelTier)
        case skipped(SkipReason)
        case failed(String)
    }

    struct Dependencies {
        var container: ModelContainer
        var prefs: InsightPreferences
        var notifier: any InsightNotifying
        var factory: CoachSessionFactory
        var assembler: ContextAssembler
        var promptManager: PromptManager
        var history: ReadinessScoreHistory
        var availability: any CoachAvailabilityChecking
        var catalog: ModelCatalog
        /// Fresh reads at call time (gates flip): evaluated at scheduling
        /// AND re-evaluated just before generation (TOCTOU). Async because
        /// on-device availability is a live async read, not a cached flag.
        var routeTier: () async -> ModelTier?
        /// HealthKit boundary seam: production reads the provider, tests
        /// inject inputs (simulator HealthKit is always empty, which
        /// would force `.noSignals` and make generation untestable).
        var readInputs: () async -> ReadinessInputs
        var now: () -> Date
        var calendar: Calendar
    }

    private let deps: Dependencies

    init(deps: Dependencies) {
        self.deps = deps
    }

    @discardableResult
    func runIfDue() async -> Outcome {
        guard deps.prefs.morningInsightsEnabled else { return .skipped(.disabled) }
        let now = deps.now()
        guard InsightScheduler.shouldRun(lastRun: deps.prefs.lastRun, now: now, calendar: deps.calendar) else {
            return .skipped(.notDue)
        }
        guard Self.syncFreshSince5am(in: deps.container, now: now, calendar: deps.calendar) else {
            return .skipped(.noFreshSync)
        }
        guard let tier = await deps.routeTier() else { return .skipped(.noTier) }
        guard await deps.notifier.authorizationStatus() == .authorized else {
            return .skipped(.unauthorized)
        }
        do {
            let inputs = await deps.readInputs()
            let readiness = ReadinessEngine.score(
                inputs: inputs,
                recentScores: deps.history.recentScores(today: now)
            )
            guard readiness.signalsUsed > 0 else { return .skipped(.noSignals) }
            // Dispatch re-check (TOCTOU): consent/toggles may have flipped
            // since scheduling. A changed or vanished tier aborts — a
            // withdrawn PCC consent must never serve PCC unattended.
            guard await deps.routeTier() == tier else { return .skipped(.tierChangedMidFlight) }

            let instructions = try deps.promptManager.effectivePrompt()
            let context = try deps.assembler.assemble(
                for: .dailyInsight,
                now: now,
                promptTokens: PromptManager.estimatedTokens(for: instructions)
            )
            let session = deps.factory.makeSession(
                for: .oneShot,
                instructions: instructions,
                tier: tier
            )
            let generator = DailyInsightGenerator {
                session
            }
            let insight = try await generator.insight(
                forPrompt: DailyInsight.prompt(readiness: readiness, context: context.context)
            )
            try Self.persist(insight, tier: tier, fields: context.context.fields, in: deps.container)
            let content = InsightNotificationContent.make(
                headline: insight.headline,
                suggestions: insight.suggestions,
                fullText: deps.prefs.lockScreenDetails
            )
            try await deps.notifier.schedule(title: content.title, body: content.body)
            deps.history.record(score: readiness.score, today: now)
            deps.prefs.lastRun = now
            return .ran(tier: tier)
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// Fresh-sync gate over existing `SyncState` rows: some sync completed
    /// since today's 5am. Pure over the fetched dates (the fetch is the
    /// only impure step) so tests drive it without SwiftData.
    static func syncFreshSince5am(lastSync: Date?, now: Date, calendar: Calendar) -> Bool {
        InsightScheduler.syncAllowsRun(lastSync: lastSync, now: now, calendar: calendar)
    }

    private static func syncFreshSince5am(in container: ModelContainer, now: Date, calendar: Calendar) -> Bool {
        let context = ModelContext(container)
        let states = (try? context.fetch(FetchDescriptor<SyncState>())) ?? []
        return syncFreshSince5am(
            lastSync: states.compactMap(\.lastSyncedAt).max(),
            now: now,
            calendar: calendar
        )
    }

    private static func persist(
        _ insight: DailyInsight,
        tier: ModelTier,
        fields: [ProfileField],
        in container: ModelContainer
    ) throws {
        let context = ModelContext(container)
        context.insert(DerivedInsight(
            text: ([insight.headline] + insight.suggestions).joined(separator: "\n"),
            createdAt: Date(),
            sourceProvider: "\(insightSourceProvider).\(tier.rawValue)",
            sourceFields: fields.map(\.key)
        ))
        try context.save()
    }
}

/// Sendable holder so the static background-sync context (which cannot
/// capture `AppEnvironment`) and the foreground scene-phase hook share one
/// configured runner. Set once in `AppEnvironment.init`; the once-daily
/// guard inside the runner dedupes BG + foreground double-invocation.
enum InsightRunnerHost {
    @MainActor static var runner: MorningInsightRunner?

    static func runIfDue() async {
        _ = await runner?.runIfDue()
    }
}
