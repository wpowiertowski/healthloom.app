// LaunchConfiguration.swift
//
// WP-10 (implementation-plan.md): launch-argument-driven configuration
// selecting which dependencies `AppEnvironment` wires up. Two UI-testing
// modes (test-plan.md §5's "App launches with arguments selecting stub
// layers"):
//
//   -UITestStubGoogle   Onboarding happy-path test. Starts at Welcome; Google
//                       consent and the first sync's reconcile client are
//                       both stubbed (`GoogleConsentCoordinator.swift`,
//                       `StubGoogleReconcileClient.swift`) so no real network
//                       call is ever made. HealthKit permission is *not*
//                       stubbed -- the real `HealthKitAuth.requestWrite`
//                       runs, and the UI test drives the system permission
//                       sheet, per implementation-plan.md WP-10's own
//                       framing ("stubbed auth" refers to Google, the one
//                       piece that would otherwise require live credentials).
//
//   -UITestSeedData     Dashboard-states test. Skips onboarding entirely and
//                       seeds an in-memory `ModelContainer` with `SyncState`
//                       rows spanning ok/error/idle before the first frame
//                       renders (`AppEnvironment.seedDashboardFixtures`).
//
//   -UITestScriptedCoach Coach chat test. Skips onboarding, lands on the
//                       Coach tab, drives it with a scripted `CoachSession`
//                       and forced `.available` availability. Deliberately
//                       NOT in-memory (unlike every other UI-test mode --
//                       see below): the relaunch leg asserts a turn
//                       persisted across launches shows history, which needs
//                       the on-disk store.
//
//   -UITestAIModels[=<scenario>]
//                       WP-29 AI Models test. Skips onboarding, lands on the
//                       Settings tab, scripts the catalog (PCC + Claude rows
//                       live with stubbed gate inputs) and the key validator
//                       so the consent/key enable flows are deterministic.
//                       Resets all tier preferences at launch (UserDefaults
//                       outlives UI-test launches) before applying the
//                       scenario's seed.
//   -UITestCoachUnavailable[=<case>]
//                       Forces an unavailable gate state on the Coach tab
//                       (default `modelNotReady`; also `deviceNotEligible`,
//                       `appleIntelligenceNotEnabled`, `unavailable`) --
//                       live unavailability is not producible on the iOS 27
//                       simulator, whose model reports `.available`.
//
// In-memory rule: every `-UITest*` mode EXCEPT `-UITestScriptedCoach`
// forces an in-memory `ModelContainer` (`CoreModel.makeContainer
// (inMemory:)`) so those runs never touch the real on-disk store. The
// scripted-coach exception exists for exactly one reason (relaunch
// persistence above) -- do not extend it without one.

import CoachKit
import Foundation

/// Which coach backend the app wires (WP-25 round-2 review #11): one
/// value computed once in `LaunchConfiguration.resolve`, so session
/// construction, availability selection, and the in-memory decision can
/// never drift apart again.
enum CoachSessionMode: Sendable, Equatable {
    /// Production on-device session + live availability.
    case live
    /// Scripted double + forced `.available` (`-UITestScriptedCoach`).
    case scripted
    /// Live session + forced unavailable case
    /// (`-UITestCoachUnavailable[=<case>]`).
    case forced(CoachAvailability)
}

/// Where the app lands at launch (WP-25 review #17).
/// WP-29 UI-test scenario for the AI Models screen. The scripted
/// catalog enables the PCC + Claude rows (non-live in production) with
/// fully stubbed gate inputs, so the enable/consent/key flows are
/// deterministic on a simulator where the real gates never pass:
///   - clean: nothing consented, no keys, validator accepts any key.
///   - invalidKey: the validator rejects every key (blocked-key copy).
///   - pccOn: PCC pre-consented and toggled on (chat slot + quota render).
enum AIModelsScenario: String, Sendable, Equatable {
    case clean
    case invalidKey
    case pccOn
}

enum InitialRoute: Sendable, Equatable {
    /// Normal path: onboarding until completed, then Today.
    case `default`
    /// Past onboarding, on the named tab (UI-test launches only).
    case data
    case coach
    /// WP-29: past onboarding, on the Settings tab (AI Models UI tests).
    case settings
    /// WP-30: past onboarding, on the You tab (profile UI tests).
    case you

    /// The tab a non-default route lands on (`.default` is Today).
    var homeTab: HomeTab {
        switch self {
        case .default: .today
        case .data: .data
        case .coach: .coach
        case .settings: .settings
        case .you: .you
        }
    }
}

struct LaunchConfiguration: Sendable {
    var stubGoogle: Bool
    var seedDashboardData: Bool
    var useInMemoryContainer: Bool
    /// WP-33: `-UITestResetTodayMetrics` clears the persisted Today-panel
    /// metric order at launch (`TodayMetricPreferences.reset`) so
    /// `TodayUITests` starts from the default four on every run --
    /// `UserDefaults.standard` outlives UI-test launches on a simulator,
    /// and the test's own relaunch leg deliberately omits this flag to
    /// verify real persistence.
    var resetTodayMetrics: Bool
    /// WP-25: `-UITestScriptedCoach` drives the Coach tab with a scripted
    /// `CoachSession` and forced `.available` availability (deterministic
    /// regardless of the simulator's live model state), landing directly
    /// on the Coach tab past onboarding. Deliberately NOT part of
    /// `useInMemoryContainer`: the
    /// chat UI test's relaunch leg asserts a turn persisted across launches
    /// shows history, which needs the on-disk store (mirroring how
    /// `TodayUITests`' relaunch leg relies on real `UserDefaults`).
    var scriptedCoach: Bool
    /// WP-30: `-UITestScrubChat` (with `-UITestScriptedCoach`) deletes every
    /// stored `ChatTurn` + `ContextSnapshot` at launch, so the transcript
    /// holds exactly the turns this run sends. Without it the on-disk store
    /// grows unboundedly across runs and history-dependent tests (scroll to
    /// Nth expander) slow down and eventually can't reach their target —
    /// each failed run appending more turns makes the next run worse.
    var scrubChat: Bool
    /// Forced gate state, or `nil` for the live/scripted path (see
    /// `forcedAvailability(from:)`).
    var forcedCoachAvailability: CoachAvailability?
    /// Where the app lands: onboarding-then-Today normally, past
    /// onboarding on the named tab under seed/scripted/forced flags
    /// (WP-25 review #17 -- one route value instead of sibling booleans,
    /// so no OR-matrix can drift and no ternary order can misroute).
    var initialRoute: InitialRoute
    /// Coach wiring selection (see `CoachSessionMode`).
    var coachSessionMode: CoachSessionMode
    /// WP-29: scripted AI Models screen (`-UITestAIModels[=<scenario>]`),
    /// or nil for the live Keychain/validator wiring.
    var aiModelsScenario: AIModelsScenario?
    /// WP-30: `-UITestYouTab` seeds an in-memory `KnowledgeProfile` (two
    /// derived fields incl. one clinical, one user correction) and lands
    /// past onboarding on the You tab, so the profile/correct/forget flows
    /// are deterministic without HealthKit data on a simulator.
    var seedYouTab: Bool
    /// True under any `-UITest*` launch. Unattended work (WP-34's morning
    /// runner) stays out of UI tests: generation does model + HealthKit
    /// work on activation, which starves animation-driven assertions on
    /// loaded CI machines (YouTab sheet timeout, PR #26).
    var isUITest: Bool
    /// WP-34: `-UITestStubNotifications` swaps the live notification center
    /// for a stub (starts `.notDetermined`, grants on request) so the
    /// insights permission flow is deterministic; `-UITestNotificationsDenied`
    /// starts the stub `.denied` for the guidance path.
    var stubNotifications: Bool
    var denyNotifications: Bool
    /// Round-2 item 7: `-UITestTipsStub=empty|failed` short-circuits the
    /// tip catalogue fetch (one-shot — Retry exercises the real path)
    /// so the settled UI states are deterministic without a StoreKit
    /// session. Unknown values fall back to `.emptyProducts` (same rule
    /// as `aiModelsScenario`: a typo still exercises a deterministic
    /// path, never the live-wiring one).
    var tipsStub: TipUITestStub?

    static var current: LaunchConfiguration {
        Self.resolve(arguments: ProcessInfo.processInfo.arguments)
    }

    /// Pure argument decoding, so the flag matrix is unit-testable without
    /// launching (WP-25 round-2 review #2/#7/#11).
    static func resolve(arguments: [String]) -> LaunchConfiguration {
        let stubGoogle = arguments.contains("-UITestStubGoogle")
        let seedDashboardData = arguments.contains("-UITestSeedData")
        let scriptedCoach = arguments.contains("-UITestScriptedCoach")
        let scrubChat = arguments.contains("-UITestScrubChat")
        let forcedCoachAvailability = Self.forcedAvailability(from: arguments)
        // The `.data` branch is `seedDashboardData` ONLY (round-2 #2):
        // `-UITestStubGoogle` alone is the onboarding happy-path test and
        // must keep landing on Welcome, exactly the pre-WP-25 rule.
        let aiModelsScenario = Self.aiModelsScenario(from: arguments)
        let seedYouTab = arguments.contains("-UITestYouTab")
        let initialRoute: InitialRoute
        if aiModelsScenario != nil {
            initialRoute = .settings
        } else if seedYouTab {
            initialRoute = .you
        } else if scriptedCoach || forcedCoachAvailability != nil {
            initialRoute = .coach
        } else if seedDashboardData {
            initialRoute = .data
        } else {
            initialRoute = .default
        }
        return LaunchConfiguration(
            stubGoogle: stubGoogle,
            seedDashboardData: seedDashboardData,
            // Scripted wins over forced unconditionally (round-2 #7): the
            // on-disk guarantee `-UITestScriptedCoach` documents holds even
            // when both flags are passed together.
            useInMemoryContainer: (stubGoogle || seedDashboardData || forcedCoachAvailability != nil || aiModelsScenario != nil || seedYouTab) && !scriptedCoach,
            resetTodayMetrics: arguments.contains("-UITestResetTodayMetrics"),
            scriptedCoach: scriptedCoach,
            scrubChat: scrubChat,
            forcedCoachAvailability: forcedCoachAvailability,
            initialRoute: initialRoute,
            coachSessionMode: Self.sessionMode(scriptedCoach: scriptedCoach, forced: forcedCoachAvailability),
            aiModelsScenario: aiModelsScenario,
            seedYouTab: seedYouTab,
            isUITest: arguments.contains(where: { $0.hasPrefix("-UITest") }),
            stubNotifications: arguments.contains("-UITestStubNotifications"),
            denyNotifications: arguments.contains("-UITestNotificationsDenied"),
            tipsStub: Self.tipsStub(from: arguments)
        )
    }

    /// `-UITestTipsStub=empty|failed` (round-2 item 7). Absent = no
    /// stub (real fetch); unknown value = `.emptyProducts`.
    static func tipsStub(from arguments: [String]) -> TipUITestStub? {
        let prefix = "-UITestTipsStub"
        guard let flag = arguments.first(where: { $0.hasPrefix(prefix + "=") }) else {
            return nil
        }
        switch String(flag.dropFirst(prefix.count + 1)) {
        case "failed": return .failed
        default: return .emptyProducts
        }
    }

    /// `-UITestAIModels` (bare = `.clean`) or `-UITestAIModels=<scenario>`.
    /// Unknown values fall back to `.clean`: the flag's job is exercising
    /// the enable flows, so a typo still exercises them (against clean
    /// state) rather than silently testing the live-wiring path.
    static func aiModelsScenario(from arguments: [String]) -> AIModelsScenario? {
        let prefix = "-UITestAIModels"
        guard let flag = arguments.first(where: { $0 == prefix || $0.hasPrefix(prefix + "=") }) else {
            return nil
        }
        let value = flag == prefix ? "clean" : String(flag.dropFirst(prefix.count + 1))
        return AIModelsScenario(rawValue: value) ?? .clean
    }

    /// One derived value for coach wiring (round-2 #11): `AppEnvironment`'s
    /// session and availability selections switch on this instead of
    /// re-deriving flag precedence in lock-step. Forced wins over scripted,
    /// matching the previous inline rule.
    static func sessionMode(scriptedCoach: Bool, forced: CoachAvailability?) -> CoachSessionMode {
        if let forced {
            return .forced(forced)
        } else if scriptedCoach {
            return .scripted
        } else {
            return .live
        }
    }

    /// `-UITestCoachUnavailable` (bare) or `-UITestCoachUnavailable=<case>`
    /// forces the named `CoachAvailability` case. Unknown values fall back
    /// to `.modelNotReady` -- the flag's whole job is rendering an
    /// unavailable state, so a typo must still render one (loudly the
    /// wrong one, visibly, in the test) rather than silently testing the
    /// available path.
    static func forcedAvailability(from arguments: [String]) -> CoachAvailability? {
        let prefix = "-UITestCoachUnavailable"
        guard let flag = arguments.first(where: { $0 == prefix || $0.hasPrefix(prefix + "=") }) else {
            return nil
        }
        let value = flag == prefix ? "modelNotReady" : String(flag.dropFirst(prefix.count + 1))
        return switch value {
        case "deviceNotEligible": .deviceNotEligible
        case "appleIntelligenceNotEnabled": .appleIntelligenceNotEnabled
        case "unavailable": .unavailable
        default: .modelNotReady
        }
    }
}
