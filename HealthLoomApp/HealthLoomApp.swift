@preconcurrency import BackgroundTasks
import CoreModel
import os
import SwiftData
import SyncKit
import SwiftUI

/// App entry point. WP-10 (implementation-plan.md): wires `AppEnvironment`
/// (ModelContainer/HealthKitAuth/GoogleAuthManager/SyncEngine DI root) into
/// the SwiftUI environment and roots the scene at `RootView` (onboarding ->
/// dashboard). The full Today/Activities/Coach/You tab set is later phases'
/// work (architecture.md §2) -- WP-10's scope is the P0 vertical slice only.
///
/// WP-16 (implementation-plan.md): also registers and drives the one
/// `BGAppRefreshTask` this app schedules -- `com.healthloom.sync.refresh`,
/// already declared in `project.yml`'s `BGTaskSchedulerPermittedIdentifiers`
/// / `UIBackgroundModes` since WP-01. See "MARK: - Background sync (WP-16)"
/// below for the full design writeup: why registration happens in `init()`,
/// the concurrency-isolation decision for calling into `SyncEngine`, the
/// reschedule-on-every-path structure, and expiration/cancellation handling.
@main
struct HealthLoomApp: App {
    @State private var appEnvironment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let environment = AppEnvironment()
        _appEnvironment = State(initialValue: environment)

        // WP-16 step 1: register the launch handler and schedule the first
        // occurrence "at launch" -- both must happen here, synchronously,
        // before this initializer returns (Apple's `BGTaskScheduler.register`
        // doc comment: "Registration of all launch handlers must be complete
        // before the end of application(_:didFinishLaunchingWithOptions:)";
        // for a SwiftUI-lifecycle app with no `UIApplicationDelegateAdaptor`,
        // `init()` is the equivalent point -- it runs before `body`/the
        // `WindowGroup`'s scene is ever installed, and exactly once per
        // process launch).
        //
        // `BackgroundSyncLaunchContext` is captured here -- reading
        // `environment.modelContainer` / `environment.syncEngine` (both
        // MainActor-isolated properties of `AppEnvironment`) and
        // `GoogleDataType.allCases.filter { $0.writability != .skip }`
        // (`.writability` is itself a MainActor-isolated computed property,
        // CoreModel's `.defaultIsolation(MainActor.self)`) is a same-actor,
        // synchronous read: `init()` runs on `MainActor` (this whole app
        // target's implicit default isolation, `SWIFT_DEFAULT_ACTOR_ISOLATION:
        // MainActor` in project.yml), so no `await` is needed here. Once
        // captured into that plain `Sendable` struct, every function this
        // background-sync section calls is declared `nonisolated` and never
        // touches `AppEnvironment`/`MainActor` again -- see that section's
        // header comment for why.
        let backgroundSyncContext = BackgroundSyncLaunchContext(
            modelContainer: environment.modelContainer,
            syncEngine: environment.syncEngine,
            // "The list of P0+P1 GoogleDataType cases to sync" (this WP's
            // brief): every type this pipeline has an actual destination
            // for by now (WP-11's full TypeMapper table, WP-12's exercise
            // ->HKWorkout, WP-13's nutrition correlations, WP-14's
            // LocalSample routing) -- i.e. every case whose `.writability`
            // isn't `.skip`. Derived from CoreModel's own table rather than
            // hand-duplicating `AppEnvironment.p0Types`/`.p1LocalOnlyTypes`
            // here (this WP's file scope is `HealthLoomApp.swift` only, not
            // `AppEnvironment.swift`) -- this is also strictly the broader,
            // more correct P1 set: it automatically includes distance,
            // floors, energy, resting HR, HRV, SpO2, respiratory rate,
            // VO2max, body fat, height, blood glucose, core body
            // temperature, hydration, exercise, and food/nutrition log
            // alongside the P0 four and the four `.localOnly` types, and
            // never drifts from CoreModel's table as future types are
            // added.
            syncableTypes: GoogleDataType.allCases.filter { $0.writability != .skip }
        )
        HealthLoomBackgroundSync.registerLaunchHandler(context: backgroundSyncContext)
        HealthLoomBackgroundSync.scheduleNextRun() // "at launch" half of "schedule next... at launch AND in the handler"
    }

    var body: some Scene {
        WindowGroup {
            RootView(initialRoute: appEnvironment.launchConfiguration.initialRoute)
                .environment(appEnvironment)
                .modelContainer(appEnvironment.modelContainer)
        }
        // Single dispatcher, re-merged (round-3 item 15 overrode the
        // round-2 split) and KEPT (round-4 item 8 — picked with
        // evidence, not re-split without proof):
        // - Cold launch pays nothing extra: attach evaluates with
        //   phase == .inactive, so the guard drops the initial fire;
        //   the arms run once, on the inactive→active transition — the
        //   same single run the split produced.
        // - The only `initial:true` fire the split avoided is an attach
        //   with the scene ALREADY .active (warm relaunch/reconnect —
        //   exotic on this single-scene iPhone target), and its cost is
        //   bounded per arm, all `Task`-dispatched (zero first-frame
        //   blocking): insight = a defaults read + date math + one
        //   store fetch + notification IPC before any inference — and
        //   inference itself fires only when due (≤ once daily, and the
        //   next transition would trigger it identically); tips =
        //   listener attach (no-op re-entry) + an unfinished-sweep that
        //   idles without transactions; sync = UITest-gated, CloudKit
        //   or silent local-only.
        // Re-splitting would re-spend a modifier to save only the
        // exotic attach-fire's bounded cost, while risking `begin()`
        // coverage (item 15's rationale stands). `initial: true`
        // covers attach; the guard covers everything else.
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active else { return }
            Task {
                await InsightRunnerHost.runIfDue()
            }
            Task {
                await appEnvironment.tipStore.begin()
            }
            if !appEnvironment.launchConfiguration.isUITest {
                Task {
                    await appEnvironment.cloudSync.syncNow()
                }
            }
        }
    }
}

// MARK: - Background sync (WP-16, implementation-plan.md)
//
// Registers `com.healthloom.sync.refresh` as a `BGAppRefreshTask` and drives
// it: determine due types (SyncKit's pure `dueTypes(...)` planner,
// `Packages/SyncKit/Sources/SyncKit/BackgroundSync/BackgroundSyncPlanner.swift`)
// -> call `SyncEngine.sync(type:)` type-by-type for exactly those, most-
// overdue-first, checking `BackgroundSyncBudget` between types -> always
// reschedule the next occurrence, on every code path, even on failure.
//
// **Concurrency-isolation decision (read `SyncEngine.swift`'s actual
// declaration before assuming anything here -- this section did):**
// `public actor SyncEngine` is its own, distinct, non-`MainActor` actor
// (confirmed directly from `SyncEngine.swift`'s header and declaration,
// architecture.md §3's explicit list -- `actor SyncEngine`, `actor
// GoogleAuthManager`, `actor KeychainStore` -- naming it as one of the few
// types in this codebase that does *not* inherit a package's
// `.defaultIsolation(MainActor.self)`), and both `sync(type:) -> SyncOutcome`
// and `syncAll(types:) -> [SyncOutcome]` **never throw** (every per-type
// failure becomes an `.error` `SyncOutcome` -- confirmed from
// `SyncEngine.swift`'s own doc comments and WP-09/WP-10's progress.md
// entries, not assumed). Consequently, calling `syncEngine.sync(type:)` (this
// WP calls it per-type, not the bulk `syncAll(types:)` -- see "Budget /
// expiration" below) from this WP's `BGTask` handler needs **no hop onto
// `MainActor`** at all -- it's exactly the same one cross-actor `await`
// regardless of which isolation domain (main-actor UI code, or this
// handler's own non-actor background `Task`) makes the call, since entering
// a *different*, non-MainActor actor is symmetric with respect to the
// caller's own isolation. This section's functions are therefore all
// declared `nonisolated` (never `@MainActor`) and call `syncEngine
// .sync(type:)` with a plain `await` from a detached `Task` -- there is
// deliberately no `Task { @MainActor in ... }` hop anywhere in this file's
// background-sync path, because none is needed; adding one would only cost
// an unnecessary actor round-trip on every background wake for no
// correctness benefit.
//
// The one place this file *does* need `MainActor` is reading
// `AppEnvironment`'s own DI (`HealthLoomApp.init()`, above) -- handled once,
// synchronously, at launch, and never again from any of the `nonisolated`
// code below.
//
// **Reschedule-on-every-path (WP-16 step 1, stated twice in the plan:
// "schedule next on every run and in the handler," "always reschedule, even
// on failure"):** `scheduleNextRun()` is called from `HealthLoomApp.init()`
// ("at launch") and, unconditionally, as the very first statement of
// `handleLaunch(_:context:)` below -- *before* any sync work starts, not
// duplicated into a success branch and a failure branch. This is
// deliberately stronger than "reschedule in both branches": it also covers
// the process being killed or crashing before either branch is ever
// reached (e.g. between the expiration handler firing and the completion
// `Task` resuming), since there is no branch left un-instrumented when
// there's no branching involved in the guarantee at all.
// `SyncKit.shouldRescheduleBackgroundSync(after:)` is additionally called
// and logged at completion, purely as a documented, testable confirmation
// of the same invariant (its automated test lives in SyncKit, since this
// file's own BGTaskScheduler-dependent code has no automated-test seam --
// see progress.md's WP-16 entry) -- it never gates the actual reschedule
// call, specifically because that guarantee must not depend on the
// completion closure ever running.
//
// **Budget / expiration (WP-16 step 2, "~20 s... check
// task.expirationHandler, cancel gracefully via Task cancellation"):** two
// complementary layers, not one:
//   1. **Proactive:** `run(context:)` below calls `SyncEngine.sync(type:)`
//      one type at a time (not the bulk `syncAll(types:)`) specifically so
//      it can check `BackgroundSyncBudget.hasRemainingBudget(elapsed:)`
//      *between* types and stop gracefully, with time to spare, once the
//      self-imposed ~20 s budget is spent -- this is the normal, expected
//      stopping path. `dueTypes(...)`'s most-overdue-first ordering means
//      whatever gets deferred by running out of budget is whatever was
//      *least* overdue to begin with.
//   2. **Reactive backstop:** `task.expirationHandler` cancels the detached
//      `Task` running that loop, for the case where even the proactive
//      check wasn't fast enough (e.g. a single type's fetch alone overruns
//      the remaining budget). Swift's cooperative cancellation propagates
//      into `GoogleHealthClient`'s `URLSession`-backed network calls and
//      its `Task.sleep`-based retry/backoff waits (both cancellation-aware),
//      so an in-flight type's fetch fails promptly instead of running to
//      completion.
// Neither path preempts a single type's in-flight network call mid-flight
// on its own (that would require editing `SyncEngine.swift`, out of this
// WP's file scope) -- but `SyncEngine.sync(type:)` never throws, so any
// cancellation-triggered failure just becomes an ordinary `.error`
// `SyncOutcome`, and architecture.md D3's cursor semantics mean none of
// this can corrupt state: a type that didn't finish (or wasn't reached
// before budget/deadline) simply keeps its previous `lastSyncedAt`, safely
// re-pulling the same window on the next attempt.
//
// **What's automated vs. manual (WP-16's "Tests" line):** the pure
// "due types + budget" planner (`dueTypes`, `BackgroundSyncBudget`,
// `shouldRescheduleBackgroundSync`) is unit-tested in
// `Packages/SyncKit/Tests/SyncKitTests/BackgroundSync/BackgroundSyncPlannerTests.swift`
// -- it imports neither `BackgroundTasks` nor `HealthKit`, so it runs under
// plain `swift test`. The real `BGTaskScheduler` register/submit/
// simulate-launch flow has no automated-test seam reachable from this WP's
// single-file app-target scope (`HealthLoomApp.swift` only, no new
// `HealthLoomTests` file) and, per the plan's own text, is verified manually
// via lldb's `_simulateLaunchForTaskWithIdentifier:` on a real device/
// simulator -- **not run in this session** (interactive-debugger-only;
// documented here and in progress.md as an outstanding manual follow-up,
// not faked).
private enum HealthLoomBackgroundSync {
    /// Matches `project.yml`'s `BGTaskSchedulerPermittedIdentifiers` entry
    /// and architecture.md's naming (WP-01). `nonisolated` (like every
    /// stored constant in this enum) so it's readable from the `nonisolated`
    /// functions below without an actor hop -- this app target's
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` setting would otherwise
    /// make even a plain `String`-typed `static let` MainActor-isolated by
    /// default.
    nonisolated static let identifier = "com.healthloom.sync.refresh"

    nonisolated private static let configuration = BackgroundSyncConfiguration()
    nonisolated private static let logger = Logger(subsystem: "app.healthloom", category: "BackgroundSync")

    /// WP-16 step 1: register the launch handler. Must be called exactly
    /// once per process launch (Apple's own doc comment on `register(...)`:
    /// "The system kills the app on the second registration of the same
    /// task identifier") -- `HealthLoomApp.init()` runs exactly once per
    /// launch, so this is safe as written.
    ///
    /// Deliberately `nonisolated`, called from `init()` (`MainActor`) with
    /// no isolation mismatch: `nonisolated` functions are callable from any
    /// isolation domain, including `MainActor`, with a plain (non-`await`)
    /// call when the function itself never suspends -- this one doesn't.
    /// The `BGTaskScheduler.register(forTaskWithIdentifier:using:launchHandler:)`
    /// launch handler closure is written *inside* this `nonisolated`
    /// function specifically so it has no ambient `MainActor` context to
    /// inherit: `BackgroundTasks`' `launchHandler` is a plain, un-annotated
    /// imported closure type (verified against this toolchain's
    /// `BGTaskScheduler.h`/`.apinotes` -- no `@Sendable`/actor annotation at
    /// all), and the system invokes it on an arbitrary background queue,
    /// never `MainActor`. Nesting it inside a `MainActor`-isolated function
    /// (as `HealthLoomApp.init()` itself is) would risk the closure
    /// literal's isolation defaulting to match that ambient context per
    /// Swift's closure-isolation-inference rules -- nesting it here, where
    /// the enclosing function is `nonisolated`, removes that ambiguity
    /// entirely rather than relying on inference. `context` (a plain
    /// `Sendable` struct, see below) is the closure's only capture.
    nonisolated static func registerLaunchHandler(context: BackgroundSyncLaunchContext) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                logger.error("BG launch handler received a non-BGAppRefreshTask for \(identifier, privacy: .public); completing as failed")
                task.setTaskCompleted(success: false)
                return
            }
            handleLaunch(refreshTask, context: context)
        }
        logger.debug("Registered BGAppRefreshTask handler for \(identifier, privacy: .public)")
    }

    /// WP-16 step 1: "schedule next on every run and in the handler." Called
    /// from `HealthLoomApp.init()` ("at launch") and, unconditionally, from
    /// the very start of `handleLaunch(_:context:)` ("in the handler").
    /// Failure to submit (`.unavailable` on the Simulator -- documented
    /// directly in this toolchain's `BGTaskScheduler.h`: "The app is running
    /// on Simulator which doesn't support background processing"; or
    /// `.notPermitted`/`.tooManyPendingTaskRequests` on-device) is logged,
    /// not fatal: the next foreground launch or the next successful
    /// background wake tries again.
    nonisolated static func scheduleNextRun() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: configuration.reschedulingInterval)
        // iOS 27 deprecated the synchronous throwing `submit(_:)` in favor of
        // `submitTaskRequest(_:completionHandler:)`, which Swift imports as
        // `async throws`. This function stays synchronous (its two call
        // sites -- `init()` and the launch handler -- rely on that), so the
        // submit is fired from an unstructured `Task` rather than propagated
        // as `async`; the original fire-and-forget/logged-not-fatal contract
        // is unchanged.
        Task {
            do {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
                logger.debug("Scheduled next background sync")
            } catch {
                // Redacted per architecture.md D11: a `BGTaskScheduler.Error`'s
                // description carries no health values or tokens, only a
                // scheduling-error code, so `.public` is safe here.
                logger.error("Failed to schedule next background sync: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The `BGAppRefreshTask` launch handler proper.
    nonisolated private static func handleLaunch(_ task: BGAppRefreshTask, context: BackgroundSyncLaunchContext) {
        // Unconditional, before any work starts -- see this enum's header
        // comment for why this dominates "reschedule in the success branch
        // and the failure branch."
        scheduleNextRun()
        logger.log("Background sync handler fired")

        // `BGTask`/`BGAppRefreshTask` predates Swift concurrency and carries
        // no `Sendable` annotation (verified against this toolchain's
        // `BGTaskScheduler.h`/`.apinotes` -- neither declares one), even
        // though `BGTaskScheduler`'s own documented contract hands each
        // launch-handler invocation exclusive, non-overlapping ownership of
        // one task instance for its entire lifetime (assign
        // `expirationHandler`, eventually call `setTaskCompleted(success:)`,
        // done -- never touched from two *truly* concurrent call sites).
        // `BackgroundTaskBox`'s `@unchecked Sendable` reflects that
        // documented single-owner contract so `task` can be captured by the
        // completion `Task.detached` closure below without the compiler
        // (correctly, in the general case, since it can't see that
        // contract) flagging a data-race risk.
        let taskBox = BackgroundTaskBox(task: task)

        let syncTask = Task.detached(priority: .utility) { () -> [SyncOutcome] in
            await run(context: context)
        }

        taskBox.task.expirationHandler = {
            logger.notice("Background sync task expiring before completion; cancelling in-flight work")
            syncTask.cancel()
        }

        Task.detached(priority: .utility) {
            let outcomes = await syncTask.value
            let allSucceeded = outcomes.allSatisfy { $0.status == .ok }
            // Documented, asserted confirmation only -- never gates the
            // actual reschedule, which already happened, unconditionally,
            // above.
            assert(
                shouldRescheduleBackgroundSync(after: outcomes),
                "WP-16: background sync must always reschedule regardless of outcome"
            )
            logger.log(
                "Background sync finished: \(outcomes.count, privacy: .public) type(s) attempted, allSucceeded=\(allSucceeded, privacy: .public)"
            )
            // WP-34: overnight half of the morning-insight trigger. Same
            // shared entry as the foreground scene-phase hook — the
            // runner's own gates (enabled, after-5am, once-daily, fresh
            // sync, tier, authorization, signals) decide, so a failed or
            // premature sync simply yields `.skipped`.
            await InsightRunnerHost.runIfDue()
            taskBox.task.setTaskCompleted(success: allSucceeded)
        }
    }

    /// Off-`MainActor` pipeline for one background run: builds a
    /// `SyncStateSnapshot` per type from a fresh `ModelContext` (created and
    /// used entirely within this one function call -- SwiftData's
    /// `ModelContainer`/`ModelContext` are both documented `@unchecked
    /// Sendable`, and this mirrors `SyncEngine.performSync`'s own
    /// per-call-context pattern exactly), asks SyncKit's pure `dueTypes(...)`
    /// planner which types actually need a run, then calls
    /// `SyncEngine.sync(type:)` one type at a time -- most-overdue-first,
    /// per `dueTypes(...)`'s ordering -- checking `BackgroundSyncBudget`
    /// between each so a slow run stops gracefully rather than relying
    /// solely on `task.expirationHandler`'s reactive cancellation (WP-16
    /// step 2; see this section's header comment). Returns an empty array
    /// (a legitimate, non-error outcome) when nothing is due.
    nonisolated private static func run(context: BackgroundSyncLaunchContext) async -> [SyncOutcome] {
        let modelContext = ModelContext(context.modelContainer)
        var snapshots: [GoogleDataType: SyncStateSnapshot] = [:]
        snapshots.reserveCapacity(context.syncableTypes.count)
        for type in context.syncableTypes {
            let key = type.rawValue
            let descriptor = FetchDescriptor<SyncState>(predicate: #Predicate { $0.dataType == key })
            if let state = try? modelContext.fetch(descriptor).first {
                snapshots[type] = SyncStateSnapshot(lastSyncedAt: state.lastSyncedAt)
            }
        }

        let due = dueTypes(
            allTypes: context.syncableTypes,
            syncStates: snapshots,
            now: Date(),
            minInterval: configuration.minInterval
        )
        logger.log(
            "\(due.count, privacy: .public) of \(context.syncableTypes.count, privacy: .public) type(s) due for background sync"
        )
        guard !due.isEmpty else { return [] }

        let runStart = Date()
        var outcomes: [SyncOutcome] = []
        outcomes.reserveCapacity(due.count)
        for type in due {
            let elapsed = Date().timeIntervalSince(runStart)
            guard configuration.budget.hasRemainingBudget(elapsed: elapsed) else {
                logger.notice(
                    "Background sync time budget exhausted; \(due.count - outcomes.count, privacy: .public) type(s) deferred to the next run"
                )
                break
            }
            outcomes.append(await context.syncEngine.sync(type: type))
        }
        return outcomes
    }
}

/// See `HealthLoomBackgroundSync.handleLaunch(_:context:)`'s doc comment for
/// why this `@unchecked Sendable` box exists: `BGTask`/`BGAppRefreshTask`
/// predates Swift concurrency and isn't `Sendable`-annotated, but
/// `BGTaskScheduler` itself hands the launch handler exclusive ownership of
/// one task instance per invocation.
nonisolated private struct BackgroundTaskBox: @unchecked Sendable {
    let task: BGAppRefreshTask
}

/// Plain, fully `Sendable` bundle of exactly the DI `HealthLoomBackgroundSync`
/// needs, captured once at launch (`HealthLoomApp.init()`, on `MainActor`) so
/// every function in that enum can be `nonisolated` with no ambient
/// `MainActor` context anywhere in its call tree -- see
/// `HealthLoomBackgroundSync.registerLaunchHandler(context:)`'s doc comment
/// for why that specifically matters for the `BGTaskScheduler` launch-handler
/// closure. Deliberately does *not* hold a reference to `AppEnvironment`
/// itself (a plain, non-`Sendable`-declared `@MainActor` class) -- capturing
/// the whole object in this long-lived, background-queue-invoked closure
/// would require `AppEnvironment` to conform to `Sendable`, which is
/// `AppEnvironment.swift`'s call to make, not this WP's (`AppEnvironment.swift`
/// is outside this WP's file scope: only `HealthLoomApp.swift` is touched).
private struct BackgroundSyncLaunchContext: Sendable {
    var modelContainer: ModelContainer
    var syncEngine: SyncEngine
    var syncableTypes: [GoogleDataType]
}
