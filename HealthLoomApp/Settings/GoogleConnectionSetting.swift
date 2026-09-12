// GoogleConnectionSetting.swift
//
// Onboarding-skip-Google: the single source of truth for the user's explicit
// "Continue without Google" choice. A plain value type over `UserDefaults` (the
// `SyncPreferences` persistence precedent): no observation, no caching — every read
// hits defaults, so a flag set by onboarding is visible to Dashboard/Settings/
// background sync through fresh instances with no reload protocol to forget.
//
// This flag records EXPLICIT skip only. "Connected" is Keychain token presence
// (`GoogleAuthManager.hasStoredRefreshToken()`), never this flag's absence — a fresh
// install that never reached consent has neither, and must not read as either.
// The flag is set in exactly one place (`OnboardingFlowView`'s skip leg) and cleared
// in exactly two: a successful Google consent (Settings connect flows) and the wipe's
// `resetDefaults` (whole-domain removal). Anything else that needs "should we touch
// Google" branches on token presence, not this flag.

import Foundation

struct GoogleConnectionSetting {
    private static let skippedKey = "com.healthloom.settings.googleSkipped"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the user explicitly skipped Google connection during onboarding.
    var isSkipped: Bool {
        defaults.bool(forKey: Self.skippedKey)
    }

    /// Records the explicit skip (onboarding only).
    func setSkipped() {
        defaults.set(true, forKey: Self.skippedKey)
    }

    /// Clears the skip after a successful Google consent (Settings connect flows).
    func clearSkipped() {
        defaults.removeObject(forKey: Self.skippedKey)
    }
}
