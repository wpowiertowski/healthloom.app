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
// it, since nothing is recorded on failure. Deliberately no on-device
// fallback when the routed tier fails (F4): fail-closed — a PCC-preferring
// user gets no insight rather than a wrong-tier one — and the `.failed`
// log above makes that choice observable instead of silent.

import CoachKit
import CoreModel
import Foundation
import os
import SwiftData

@MainActor
struct MorningInsightRunner {
    // F4: failures are logged here (the only place outcomes are produced),
    // so both discarding call sites (the host and the scene-phase hook)
    // stay thin. The message is the failure case — static reasons, counts,
    // typed model errors — never insight text or health values.
    private static let logger = Logger(subsystem: "app.healthloom", category: "MorningInsight")
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
        let container: ModelContainer
        let prefs: InsightPreferences
        let notifier: any InsightNotifying
        let factory: CoachSessionFactory
        let assembler: ContextAssembler
        let promptManager: PromptManager
        let history: ReadinessScoreHistory
        let availability: any CoachAvailabilityChecking
        let catalog: ModelCatalog
        /// Fresh reads at call time (gates flip): evaluated at scheduling
        /// AND re-evaluated just before generation (TOCTOU). Async because
        /// on-device availability is a live async read, not a cached flag.
        let routeTier: () async -> ModelTier?
        /// HealthKit boundary seam: production reads the provider, tests
        /// inject inputs (simulator HealthKit is always empty, which
        /// would force `.noSignals` and make generation untestable).
        let readInputs: () async -> ReadinessInputs
        let now: () -> Date
        let calendar: Calendar
    }

    private let deps: Dependencies

    init(deps: Dependencies) {
        self.deps = deps
    }

    @discardableResult
    func runIfDue() async -> Outcome {
        let outcome = await run()
        // F4: a persistent failure (PCC pre-flip, assembler regression)
        // would otherwise be invisible — daily, silent, unmeasured.
        if case .failed(let message) = outcome {
            Self.logger.error("morning insight failed: \(message, privacy: .public)")
        }
        return outcome
    }

    private func run() async -> Outcome {
        // F1: the runner's prefs instance is not the one Settings writes
        // (it lives for days) — reload from defaults first so a fresh
        // toggle is visible without relaunch.
        deps.prefs.reload()
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
            // Dispatch re-check (round-7 item 1, true-once): another
            // run may have completed between this run's gate and now —
            // the gate read a stale `lastRun`, but inference takes long
            // enough (BG + foreground overlap) for a full run to land
            // in between. Reload and re-verify the once-daily guard: a
            // set `lastRun` skips instead of double-persisting +
            // double-notifying (which would also contradict the
            // header's dedupe claim).
            deps.prefs.reload()
            guard InsightScheduler.shouldRun(lastRun: deps.prefs.lastRun, now: deps.now(), calendar: deps.calendar) else {
                return .skipped(.notDue)
            }
            try Self.persist(insight, tier: tier, fields: context.context.fields, now: now, in: deps.container, calendar: deps.calendar)
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

    /// Same-day predicate for the F5 replace-don't-duplicate rule
    /// (round-4-sync item 11): pure so tests pin it under explicit
    /// non-system calendars — the boundary is the INJECTED calendar,
    /// never ambient `Calendar.current`.
    static func isSameInsightDay(_ a: Date, _ b: Date, calendar: Calendar) -> Bool {
        calendar.isDate(a, inSameDayAs: b)
    }

    private static func persist(
        _ insight: DailyInsight,
        tier: ModelTier,
        fields: [ProfileField],
        now: Date,
        in container: ModelContainer,
        calendar: Calendar
    ) throws {
        let context = ModelContext(container)
        // F5 day-dedupe: notify can throw *after* this insert (revoked
        // mid-flight), and `lastRun` is only recorded after notify — so a
        // retry would persist a second identical row. Same-day rows are
        // replaced, never duplicated; the plan's only-on-success rule
        // still refers to `lastRun`, which stays unset on failure.
        // Round-4-sync item 11: `deps.calendar`, never
        // `Calendar.current` — the dedupe day-boundary must agree with
        // the scheduling gates above, or a retry under a non-system
        // calendar duplicates instead of replacing.
        let stale = try context.fetch(FetchDescriptor<DerivedInsight>()).filter {
            $0.sourceProvider.hasPrefix(insightSourceProvider)
                && Self.isSameInsightDay($0.createdAt, now, calendar: calendar)
        }
        for row in stale {
            context.delete(row)
        }
        context.insert(DerivedInsight(
            text: ([insight.headline] + insight.suggestions).joined(separator: "\n"),
            createdAt: now,
            sourceProvider: "\(insightSourceProvider).\(tier.rawValue)",
            sourceFields: fields.map(\.key)
        ))
        try context.save()
    }
}

/// Sendable holder so the static background-sync context (which cannot
/// capture `AppEnvironment`) and the foreground scene-phase hook share one
/// configured runner. Set once in `AppEnvironment.init`.
enum InsightRunnerHost {
    @MainActor static var runner: MorningInsightRunner?

    /// In-flight run (round-7 item 1): concurrent triggers (scene-phase
    /// hook + BG completion) JOIN one run instead of double-inferring +
    /// double-notifying — the once-daily guard alone cannot dedupe them
    /// (both pass it while `lastRun` is still unset). Check-and-claim is
    /// synchronous on the MainActor (no suspension between), so no
    /// second run slips in. A joiner adopts the run's outcome.
    @MainActor private static var inFlight: Task<Void, Never>?

    static func runIfDue() async {
        if let running = inFlight {
            await running.value
            return
        }
        guard let runner else { return }
        inFlight = Task { await runner.runIfDue() }
        await inFlight?.value
        inFlight = nil
    }
}
