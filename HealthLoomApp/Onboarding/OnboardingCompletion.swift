// OnboardingCompletion.swift
//
// WP-50: onboarding runs once. Until now `RootView` decided from the launch
// route alone -- `.default` always started at Welcome -- and finishing only
// flipped in-memory `@State`, so every cold launch onboarded again.
// (`WipeCoordinator` already said its defaults reset "kills onboarding",
// expecting a flag that didn't exist.)
//
// The flag lives in the app's standard `UserDefaults` domain on purpose:
// "Disconnect & wipe" removes that whole domain (`WipeFlowView`'s
// `resetDefaults`), so a wipe -- and only a wipe -- brings onboarding back.
// `OnboardingCompletionTests` pins that; moving the flag anywhere a wipe
// doesn't reach (Keychain, another suite) fails it.

import Foundation

struct OnboardingCompletion {
    private static let completedKey = "com.healthloom.onboarding.completed"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The user finished onboarding on this install (since the last wipe).
    var isCompleted: Bool {
        defaults.bool(forKey: Self.completedKey)
    }

    /// Recorded once, when the onboarding flow finishes.
    func markCompleted() {
        defaults.set(true, forKey: Self.completedKey)
    }

    /// Where launch starts: `true` for the app, `false` for onboarding.
    /// Pure, so the whole table is unit-tested.
    ///
    /// - A tab route (the UI-test seed modes) starts in the app.
    /// - `completion` is `nil` when persistence is off -- every `-UITest*`
    ///   launch -- so a flag left in the simulator by one UI test run can't
    ///   skip another run's onboarding. The route alone decides.
    /// - Otherwise only the normal `.default` route honours the flag; an
    ///   explicit onboarding route (`.onboardingGoogle`) always onboards.
    static func startsInApp(route: InitialRoute, completion: OnboardingCompletion?) -> Bool {
        guard route.onboardingStep != nil else { return true }
        guard let completion, route == .default else { return false }
        return completion.isCompleted
    }
}
