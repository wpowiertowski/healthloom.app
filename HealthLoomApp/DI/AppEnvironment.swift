// AppEnvironment.swift
//
// WP-10 (implementation-plan.md): wires CoreModel's `ModelContainer`,
// SyncKit's `HealthKitAuth`/`SyncEngine`, and GoogleHealthClient's
// `GoogleAuthManager` into one dependency-injection root, held in the
// SwiftUI environment (architecture.md §2's app-target row: "DI wiring").
// `@Observable` (not `ObservableObject`) per this app target's iOS
// 26/Swift 6.2 conventions -- `HealthLoomApp` injects one instance via
// `.environment(_:)`; every screen reads it back via
// `@Environment(AppEnvironment.self)`.
//
// Real API shapes discovered while writing this file -- see progress.md's
// WP-10 entry for the full account of what the plan's illustrative sketches
// got right/wrong:
//   - `HealthKitAuth` (SyncKit) exposes `isAvailable` / `requestWrite(for:)`
//     / `writeStatus(for:)` / the static `p0WriteTypes` constant -- used
//     directly instead of re-deriving the P0 set.
//   - `SyncEngine.syncAll(types:)` returns `[SyncOutcome]` and never throws
//     -- every per-type failure becomes an `.error` `SyncOutcome`, not a
//     thrown error, so onboarding/dashboard code never needs a catch here.
//   - `CoreModel.makeContainer(inMemory:)` is exactly as sketched in the plan.
//   - `GoogleHealthClient` (the data client struct) already conforms to
//     SyncKit's `GoogleReconcileClient` (`GoogleHealthClient+SyncEngine
//     .swift`), so the real, non-stubbed path needs no adapter at all.

import CoachKit
import CoreModel
import Foundation
import GoogleHealthClient
import Observation
import Secrets
import SwiftData
import SyncKit

@MainActor
@Observable
final class AppEnvironment {
    /// The four P0 data types this WP's onboarding/dashboard slice covers
    /// (implementation-plan.md WP-10 / architecture.md §1 phase goal).
    /// Mirrors `HealthKitAuth.p0WriteTypes` -- kept as its own constant here
    /// (rather than reaching into SyncKit for it) since this app-target list
    /// is also used for Google-scope derivation (`GoogleConsentView`), which
    /// has nothing to do with HealthKit.
    static let p0Types: [GoogleDataType] = [.steps, .heartRate, .weight, .sleep]

    /// WP-14 (implementation-plan.md): the four `.localOnly`-writability
    /// types (architecture.md D2) that persist to `LocalSample` instead of
    /// HealthKit and render as "Not in Apple Health" dashboard rows
    /// (`LocalOnlyTypeRow.swift`) rather than `SyncTypeRow`'s `SyncState`-
    /// backed ones. A plain literal list, matching `p0Types`'s own
    /// convention, rather than deriving "every `.localOnly` `GoogleDataType`"
    /// from `GoogleDataType.writability` here: this WP's brief names exactly
    /// these four as P1's local-only scope, not "whatever CoreModel's table
    /// happens to mark `.localOnly` in the future" -- a fifth type appearing
    /// there later should be a deliberate app-target decision (does it get
    /// its own row? bucketed with these four?), not something that silently
    /// starts appearing here. SyncKit's `isClinicalType(_:)` (Routing/
    /// ClinicalClassification.swift) is the one piece of this WP that *is*
    /// table-driven/derived, per its own doc comment -- the clinical-vs-not
    /// split within this fixed four-type list is exactly the kind of fact
    /// that should never be hand-duplicated.
    static let p1LocalOnlyTypes: [GoogleDataType] = [
        .electrocardiogram, .activeZoneMinutes, .activeMinutes, .irregularRhythmNotification,
    ]

    /// WP-15 (implementation-plan.md): every type the historical-backfill
    /// walk covers -- deliberately the broad P1 set (every `GoogleDataType`
    /// with an actual write destination), not just `p0Types`, mirroring
    /// `HealthLoomApp.swift`'s own `syncableTypes` derivation for WP-16's
    /// background sync (`GoogleDataType.allCases.filter { $0.writability !=
    /// .skip }`) -- kept as its own constant here (rather than importing
    /// that file's private list, which this WP's scope doesn't touch
    /// anyway) since backfill and background-sync are independent
    /// consumers of the same underlying fact.
    static let backfillTypes: [GoogleDataType] = GoogleDataType.allCases.filter { $0.writability != .skip }

    let modelContainer: ModelContainer
    let healthKitAuth: HealthKitAuth
    let googleAuthManager: GoogleAuthManager
    let syncEngine: SyncEngine
    let consentCoordinator: any GoogleConsentCoordinating
    let launchConfiguration: LaunchConfiguration
    /// WP-15: chunked, resumable historical backfill (architecture.md D5).
    /// Shares this same `reconcileClient`/`HealthKitWriter()`/`modelContainer`
    /// with `syncEngine` above (dedupe/idempotency depends on both pipelines
    /// writing through the same `HealthKitWriter`/HK store, architecture.md
    /// D4 -- see `Packages/SyncKit/Sources/SyncKit/Backfill/BackfillCoordinator.swift`'s
    /// header), and `syncEngine` itself as the `BackfillBusyProbe` (WP-15
    /// step 2's "suspend during foreground incremental sync" rule, via
    /// `SyncEngine.isBusy(for:)` / `SyncEngine+BackfillBusyProbe.swift`'s
    /// zero-code conformance). Coordination point (flagged per the WP-15
    /// handoff brief): this is a new, additive stored property on
    /// `AppEnvironment` -- WP-16/WP-17 were not expected to touch this file,
    /// but if a concurrent edit lands here too, this property and its one
    /// init-time construction line are the only WP-15 footprint to
    /// reconcile.
    let backfillCoordinator: BackfillCoordinator
    /// WP-18 (implementation-plan.md): the ring-buffer sync-run log
    /// (SyncKit/Diagnostics/SyncLogStore.swift) backing `SettingsView`'s new
    /// "Sync Log" viewer. **Coordination point, flagged per the handoff
    /// protocol** (mirroring WP-15's own note above for its
    /// `backfillCoordinator` property): this is a new, additive stored
    /// property plus one new `runRecorder:` argument on the existing
    /// `SyncEngine(...)` construction below -- WP-18's own brief names this
    /// file's edit as the natural DI-wiring point for the one hook it adds
    /// to `SyncEngine.swift` (an optional `runRecorder:` parameter,
    /// defaulting to `nil` -- see that file's doc comment), since every
    /// other production consumer of `SyncEngine` (`syncEngine.sync(type:)`/
    /// `.syncAll(types:)` from `DashboardView`, `HealthLoomApp`'s background
    /// handler) is either out of this WP's scope or fenced off entirely.
    /// `SyncLogStore()`'s default `FileSyncLogPersistence` persists under
    /// `Application Support/HealthLoom/SyncLog.json` (a sibling of
    /// `CoreModel.store`, never inside its schema -- see
    /// `SyncLogPersistence.swift`'s header for why a second SwiftData model
    /// wasn't used instead).
    let syncLogStore: SyncLogStore
    /// WP-25 (implementation-plan.md): the Coach tab's view model, owning
    /// the conversation stack (one factory per app lifetime -- its cached
    /// conversation session is the WP-22 "transcript is the memory" rule).
    /// The only coach piece that stays stored: the store/manager/
    /// assembler/factory are `init`-time locals, since nothing outside this
    /// initializer reads them (review minor). Additive properties only --
    /// the WP-15/WP-18 coordination-point convention.
    let coachChatViewModel: CoachChatViewModel
    init(launchConfiguration: LaunchConfiguration = .current) {
        self.launchConfiguration = launchConfiguration

        // WP-33: UI-test launches can ask for a clean Today-panel metric
        // order (see LaunchConfiguration.resetTodayMetrics's doc comment).
        if launchConfiguration.resetTodayMetrics {
            TodayMetricPreferences.reset()
        }

        let container: ModelContainer
        do {
            container = try CoreModel.makeContainer(inMemory: launchConfiguration.useInMemoryContainer)
        } catch {
            // Defensive fallback, not specified by WP-10: a broken on-disk
            // store shouldn't hard-crash launch when an in-memory container
            // can still let onboarding/dashboard render (with data that
            // won't persist across relaunch) -- surfaces the failure via a
            // fallback rather than silently swallowing it.
            container = (try? CoreModel.makeContainer(inMemory: true))
                ?? { fatalError("CoreModel.makeContainer failed even in-memory: \(error)") }()
        }
        self.modelContainer = container
        self.healthKitAuth = HealthKitAuth()

        let authConfig = GoogleAuthConfig(
            // Placeholder client ID -- no real Google Cloud iOS OAuth client
            // exists yet (P-1.3, human prerequisite; see progress.md's
            // WP-01/WP-04 notes on the placeholder redirect scheme this
            // must be reconciled with). Real consent against Google is
            // untestable until that lands; this wiring is otherwise complete
            // and matches `project.yml`'s placeholder `CFBundleURLSchemes`.
            clientID: "GOOGLE_IOS_CLIENT_ID_PENDING_P-1.3",
            redirectURI: "com.healthloom.app:/oauth2redirect",
            redirectURIScheme: "com.healthloom.app"
        )
        let authManager = GoogleAuthManager(
            config: authConfig,
            httpSession: URLSessionHTTPSession(),
            tokenStore: KeychainStore()
        )
        self.googleAuthManager = authManager

        let reconcileClient: any GoogleReconcileClient
        if launchConfiguration.stubGoogle {
            reconcileClient = StubGoogleReconcileClient()
            self.consentCoordinator = StubGoogleConsentCoordinator()
        } else {
            reconcileClient = GoogleHealthClient(httpSession: URLSessionHTTPSession(), auth: authManager)
            self.consentCoordinator = LiveGoogleConsentCoordinator(authManager: authManager)
        }

        // WP-18: UI-test/preview runs already force an in-memory
        // `ModelContainer` above (never touching the real on-disk store) --
        // mirror that same choice here so those runs never write a real
        // `SyncLog.json` to this Mac/simulator's Application Support either.
        let syncLogStore = SyncLogStore(
            persistence: launchConfiguration.useInMemoryContainer ? NullSyncLogPersistence() : FileSyncLogPersistence()
        )
        self.syncLogStore = syncLogStore

        // WP-12b: watch-priority conflict resolution (architecture.md D13),
        // installed in the `conflictFilter:` seam WP-09 left on both
        // pipelines. One shared coverage provider (a read-only HealthKit
        // query source), but **one resolver per pipeline** -- the resolver
        // holds per-run drain state (deferred-session links, suppressed
        // counts), and `SyncEngine` runs can overlap `BackfillCoordinator`
        // chunks, so sharing one instance would cross-contaminate their
        // drains (WatchConflictResolver.swift's header documents this rule).
        // Each resolver deletes conflicts through the same `HealthKitWriter`
        // its pipeline writes through, keeping D4's idempotency story in one
        // place. `UserDefaultsWatchPriorityPreference` reads the same key
        // `SettingsView`'s "Prefer Apple Watch during workouts" toggle
        // writes (`WatchPriorityPreferences`, Settings/) -- default ON.
        let watchCoverageProvider = HealthKitWatchCoverageProvider()

        let syncWriter = HealthKitWriter()
        let syncEngine = SyncEngine(
            client: reconcileClient,
            writer: syncWriter,
            modelContainer: container,
            conflictFilter: WatchConflictResolver(
                coverageProvider: watchCoverageProvider,
                writer: syncWriter,
                preference: UserDefaultsWatchPriorityPreference()
            ),
            runRecorder: SyncEngineLogRecorder(store: syncLogStore)
        )
        self.syncEngine = syncEngine

        // WP-15: same reconcile client + a fresh HealthKitWriter (its own
        // `HKHealthStore` wrapper, but the same underlying store -- HK
        // access isn't instance-scoped) + the same container, so both
        // pipelines dedupe against the exact same HealthKit data per
        // architecture.md D4. `syncEngine` doubles as the `BackfillBusyProbe`
        // (zero-code conformance, `SyncEngine+BackfillBusyProbe.swift`).
        let backfillWriter = HealthKitWriter()
        self.backfillCoordinator = BackfillCoordinator(
            types: Self.backfillTypes,
            client: reconcileClient,
            writer: backfillWriter,
            modelContainer: container,
            conflictFilter: WatchConflictResolver(
                coverageProvider: watchCoverageProvider,
                writer: backfillWriter,
                preference: UserDefaultsWatchPriorityPreference()
            ),
            busyProbe: syncEngine
        )

        if launchConfiguration.seedDashboardData {
            Self.seedDashboardFixtures(in: container)
        }

        // WP-25: production chat stack. `HealthKitReadStore()` takes its own
        // `HKHealthStore` (its documented posture); authorization for the
        // read set stays with the app's existing HealthKit screens, and
        // `refresh()` simply reads empty until granted.
        let knowledgeStore = KnowledgeStore(
            modelContainer: container,
            healthReadStore: HealthKitReadStore(),
            healthKitAuth: healthKitAuth
        )
        let promptManager = PromptManager(modelContainer: container)
        let contextAssembler = ContextAssembler(modelContainer: container)
        // Both selections switch on the one precomputed mode (round-2
        // #11) -- no re-derived flag precedence here. The scripted double
        // is a plain always-compiled type (the `StubGoogleReconcileClient`
        // precedent), so selection is purely runtime, identical in Debug
        // and Release.
        let coachSessionFactory: CoachSessionFactory
        let availabilityChecker: any CoachAvailabilityChecking
        switch launchConfiguration.coachSessionMode {
        case .live:
            coachSessionFactory = CoachSessionFactory()
            availabilityChecker = LiveCoachAvailabilityChecker()
        case .scripted:
            coachSessionFactory = CoachSessionFactory(build: { _, _ in UITestScriptedCoachSession() })
            availabilityChecker = FixedCoachAvailabilityChecker(availability: .available)
        case .forced(let availability):
            coachSessionFactory = CoachSessionFactory()
            availabilityChecker = FixedCoachAvailabilityChecker(availability: availability)
        }
        self.coachChatViewModel = CoachChatViewModel(deps: CoachChatViewModel.Dependencies(
            container: container,
            store: knowledgeStore,
            prompts: promptManager,
            assembler: contextAssembler,
            factory: coachSessionFactory,
            availability: availabilityChecker
        ))
    }

    /// Seeds `SyncState` rows spanning every render state the WP-10 dashboard
    /// UI test asserts on (ok / error / idle-never-synced -- implementation
    /// -plan.md WP-10's "Tests" line), plus (WP-14) `LocalSample` rows for
    /// the four P1 local-only types so `DashboardUITests` can assert the
    /// "Not in Apple Health" / clinical badges against a seeded container
    /// without a real (or even stubbed) sync ever running -- used only under
    /// `-UITestSeedData` (LaunchConfiguration.swift), never in production.
    private static func seedDashboardFixtures(in container: ModelContainer) {
        let context = ModelContext(container)
        context.insert(SyncState(
            dataType: GoogleDataType.steps.rawValue,
            lastSyncedAt: Date().addingTimeInterval(-9 * 60),
            lastStatus: "ok",
            itemCount: 4213
        ))
        context.insert(SyncState(
            dataType: GoogleDataType.heartRate.rawValue,
            lastSyncedAt: Date().addingTimeInterval(-9 * 60),
            lastStatus: "ok",
            itemCount: 812
        ))
        context.insert(SyncState(
            dataType: GoogleDataType.weight.rawValue
            // lastStatus defaults to "idle", lastSyncedAt stays nil -- never synced.
        ))
        context.insert(SyncState(
            dataType: GoogleDataType.sleep.rawValue,
            lastSyncedAt: Date().addingTimeInterval(-3600),
            lastStatus: "error",
            lastError: "Google 429: rate limited - will retry automatically",
            itemCount: 12
        ))

        // WP-14: one seeded `LocalSample` per P1 local-only type -- ECG/IRN
        // (clinical) and Active Zone Minutes/Active Minutes (not) -- so
        // `DashboardUITests` can assert both the "Not in Apple Health" badge
        // (all four) and the clinical indicator (ECG/IRN only) render
        // correctly off a real `@Query` over `LocalSample`, not a mock.
        context.insert(LocalSample(
            externalID: "seed-ecg-1",
            dataType: GoogleDataType.electrocardiogram.rawValue,
            payloadJSON: Data("{}".utf8),
            start: Date().addingTimeInterval(-3600 - 30),
            end: Date().addingTimeInterval(-3600),
            source: "Apple Watch"
        ))
        context.insert(LocalSample(
            externalID: "seed-irn-1",
            dataType: GoogleDataType.irregularRhythmNotification.rawValue,
            payloadJSON: Data("{}".utf8),
            start: Date().addingTimeInterval(-7200 - 5),
            end: Date().addingTimeInterval(-7200),
            source: "Apple Watch"
        ))
        context.insert(LocalSample(
            externalID: "seed-azm-1",
            dataType: GoogleDataType.activeZoneMinutes.rawValue,
            payloadJSON: Data("{}".utf8),
            start: Date().addingTimeInterval(-600 - 1800),
            end: Date().addingTimeInterval(-600),
            source: "Fitbit Air"
        ))
        context.insert(LocalSample(
            externalID: "seed-activemin-1",
            dataType: GoogleDataType.activeMinutes.rawValue,
            payloadJSON: Data("{}".utf8),
            start: Date().addingTimeInterval(-300 - 900),
            end: Date().addingTimeInterval(-300),
            source: "Fitbit Air"
        ))

        // WP-12b: one deferred Fitbit exercise session (architecture.md
        // D13.2) so `ActivitiesUITests` can assert the consolidated
        // Activities entry renders from a seeded container. The linked
        // watch workout deliberately does NOT exist in the (empty
        // simulator) HealthKit store -- exercising the view's documented
        // unlinked-session fallback (ActivitiesModels.swift's header). The
        // payload mirrors `SyncEngineLocalPayload`'s persisted shape:
        // `sessionPayload` is the base64 of the Google Exercise session
        // JSON (`ExerciseSessionDecoding.swift`'s wire shape).
        let seedExerciseSession = Data(
            #"{"exercise.activity_type":"run","exercise.distance":8000.0,"exercise.energy":520.0}"#.utf8
        )
        context.insert(LocalSample(
            externalID: "seed-exercise-1",
            dataType: GoogleDataType.exercise.rawValue,
            payloadJSON: Data(
                #"{"sessionPayload":"\#(seedExerciseSession.base64EncodedString())"}"#.utf8
            ),
            start: Date().addingTimeInterval(-2 * 3600 - 40 * 60),
            end: Date().addingTimeInterval(-2 * 3600),
            source: "Fitbit Air",
            linkedWatchWorkoutUUID: UUID()
        ))

        try? context.save()
    }
}
