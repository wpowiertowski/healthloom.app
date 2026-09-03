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
enum InitialRoute: Sendable, Equatable {
    /// Normal path: onboarding until completed, then Today.
    case `default`
    /// Past onboarding, on the named tab (UI-test launches only).
    case data
    case coach

    /// The tab a non-default route lands on (`.default` is Today).
    var homeTab: HomeTab {
        switch self {
        case .default: .today
        case .data: .data
        case .coach: .coach
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

    static var current: LaunchConfiguration {
        Self.resolve(arguments: ProcessInfo.processInfo.arguments)
    }

    /// Pure argument decoding, so the flag matrix is unit-testable without
    /// launching (WP-25 round-2 review #2/#7/#11).
    static func resolve(arguments: [String]) -> LaunchConfiguration {
        let stubGoogle = arguments.contains("-UITestStubGoogle")
        let seedDashboardData = arguments.contains("-UITestSeedData")
        let scriptedCoach = arguments.contains("-UITestScriptedCoach")
        let forcedCoachAvailability = Self.forcedAvailability(from: arguments)
        // The `.data` branch is `seedDashboardData` ONLY (round-2 #2):
        // `-UITestStubGoogle` alone is the onboarding happy-path test and
        // must keep landing on Welcome, exactly the pre-WP-25 rule.
        let initialRoute: InitialRoute
        if scriptedCoach || forcedCoachAvailability != nil {
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
            useInMemoryContainer: (stubGoogle || seedDashboardData || forcedCoachAvailability != nil) && !scriptedCoach,
            resetTodayMetrics: arguments.contains("-UITestResetTodayMetrics"),
            scriptedCoach: scriptedCoach,
            forcedCoachAvailability: forcedCoachAvailability,
            initialRoute: initialRoute,
            coachSessionMode: Self.sessionMode(scriptedCoach: scriptedCoach, forced: forcedCoachAvailability)
        )
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
