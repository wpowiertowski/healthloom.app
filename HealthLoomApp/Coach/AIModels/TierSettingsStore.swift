// TierSettingsStore.swift
//
// WP-29 (implementation-plan.md): the app-owned half of the catalog's
// gating truth table. `ModelCatalog` never touches storage -- it reads
// through injected `hasConsent`/`hasKey` closures -- and this store is what
// the app wires into those closures, alongside `KeychainStore` for keys.
//
// One `UserDefaults` suite holds three per-tier maps, all keyed by
// `ModelTier.rawValue`:
//   - consent timestamps ("recorded per tier with timestamp"): nil = never
//     consented (or withdrawn -- withdrawal deletes the date, it does not
//     tombstone; `hasConsent` is date != nil).
//   - on/off preference: the row toggle. This is deliberately SEPARATE from
//     the catalog gate -- a tier is effectively on only when the toggle is
//     on AND `catalog.isEnabled` passes (consent + key + live + available).
//     Turning a row off keeps consent and key (cheap re-enable); deleting a
//     key or withdrawing consent turns the effective state off while the
//     toggle stays put, and the row renders the blocker reason.
//   - model override: the tier's selected model ID for key-gated tiers
//     ("model picker where applicable"); nil = tier default.
// Defaults: `.onDevice` on, every off-device tier off (opt-in, D11).
//
// `@Observable` (not a plain struct) so `AIModelsView` rows and the chat
// tier slot re-render when consent/toggles change. WP-29 F1: the published
// state is the write-through stored mirrors below (`toggles`,
// `consentDates`, `modelOverrides`) — `UserDefaults` method calls publish
// nothing, so every reader (`isTurnedOn`, `consentDate`, `modelOverride`)
// reads its mirror and every writer updates both. `UserDefaults` remains
// the backing (not SwiftData): these are preferences, not health data, and
// they must be readable before/without the model container (the catalog gate
// runs on the settings screen cold).

import CoachKit
import Foundation
import Observation

@Observable
@MainActor
final class TierSettingsStore {
    private let defaults: UserDefaults

    /// Write-through `@Observable` mirrors (WP-29 F1). Initialized from
    /// `defaults` in `init` / `resyncFromDefaults()`; every setter below
    /// writes both the mirror and `defaults`, so mutation publishes.
    private(set) var toggles: [ModelTier: Bool] = [:]
    private(set) var consentDates: [ModelTier: Date] = [:]
    private(set) var modelOverrides: [ModelTier: String] = [:]

    private static func consentKey(for tier: ModelTier) -> String {
        "tierConsent.\(tier.rawValue)"
    }

    private static func toggleKey(for tier: ModelTier) -> String {
        "tierEnabled.\(tier.rawValue)"
    }

    private static func modelKey(for tier: ModelTier) -> String {
        "tierModel.\(tier.rawValue)"
    }

    /// Production store on the standard suite. Tests pass an isolated suite
    /// (`UserDefaults(suiteName:)`) so consent fixtures never touch real
    /// preferences.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        resyncFromDefaults()
    }

    /// Re-reads every mirror from `defaults`. Required after
    /// `resetAll(in:)` (a static wipe that cannot touch live instances) —
    /// the AI Models UI-test scenario calls `resetAll()` after this store
    /// is built, then re-seeds, so it resyncs before first render.
    /// Any future direct-`UserDefaults` write outside this type needs the
    /// same call, or the mirrors (the render truth) go stale.
    func resyncFromDefaults() {
        for tier in ModelTier.allCases {
            let toggleKey = Self.toggleKey(for: tier)
            if defaults.object(forKey: toggleKey) != nil {
                toggles[tier] = defaults.bool(forKey: toggleKey)
            } else {
                toggles.removeValue(forKey: tier)
            }
            let interval = defaults.double(forKey: Self.consentKey(for: tier))
            if interval > 0 {
                consentDates[tier] = Date(timeIntervalSince1970: interval)
            } else {
                consentDates.removeValue(forKey: tier)
            }
            if let override = defaults.string(forKey: Self.modelKey(for: tier)) {
                modelOverrides[tier] = override
            } else {
                modelOverrides.removeValue(forKey: tier)
            }
        }
    }

    /// Removes every key this store owns for every tier (consent,
    /// toggles, model overrides). The AI Models UI-test scenario calls this
    /// at launch: `UserDefaults.standard` outlives UI-test launches on a
    /// simulator, and leftover consent from an earlier test would make
    /// "blocked without consent" assertions pass or fail on run order.
    static func resetAll(in defaults: UserDefaults = .standard) {
        for tier in ModelTier.allCases {
            defaults.removeObject(forKey: Self.consentKey(for: tier))
            defaults.removeObject(forKey: Self.toggleKey(for: tier))
            defaults.removeObject(forKey: Self.modelKey(for: tier))
        }
    }

    // MARK: - Consent (D11)

    /// Recorded opt-in date, nil when never consented or withdrawn.
    /// `TimeInterval` (not `Date`) because `UserDefaults` has no native
    /// date serialization worth trusting across suites -- doubles round-trip
    /// exactly.
    func consentDate(for tier: ModelTier) -> Date? {
        consentDates[tier]
    }

    func hasConsent(for tier: ModelTier) -> Bool {
        consentDate(for: tier) != nil
    }

    func recordConsent(for tier: ModelTier, at date: Date = .now) {
        defaults.set(date.timeIntervalSince1970, forKey: Self.consentKey(for: tier))
        consentDates[tier] = date
    }

    /// Withdrawal deletes the date (no tombstone): "forget applies forward"
    /// -- the gate closes immediately, prior turns already sent are
    /// unaffected (the consent sheet says so verbatim).
    func withdrawConsent(for tier: ModelTier) {
        defaults.removeObject(forKey: Self.consentKey(for: tier))
        consentDates.removeValue(forKey: tier)
    }

    // MARK: - Row toggle

    /// Explicitly-set preference. Unset means the default (on-device on,
    /// off-device off) -- stored via a separate "was set" flag rather than
    /// `bool(forKey:)`'s false-default, so "user turned PCC off" and "never
    /// touched" stay distinguishable for future migration copy.
    func isTurnedOn(_ tier: ModelTier) -> Bool {
        if let mirrored = toggles[tier] {
            return mirrored
        }
        return tier == .onDevice
    }

    func setTurnedOn(_ turnedOn: Bool, for tier: ModelTier) {
        defaults.set(turnedOn, forKey: Self.toggleKey(for: tier))
        toggles[tier] = turnedOn
    }

    // MARK: - Model override ("model picker where applicable")

    /// Selected model ID for key-gated tiers, nil = `defaultModelID`.
    /// Non-key-gated tiers ignore this (their rows render no picker).
    func modelOverride(for tier: ModelTier) -> String? {
        modelOverrides[tier]
    }

    func setModelOverride(_ modelID: String?, for tier: ModelTier) {
        if let modelID {
            defaults.set(modelID, forKey: Self.modelKey(for: tier))
            modelOverrides[tier] = modelID
        } else {
            defaults.removeObject(forKey: Self.modelKey(for: tier))
            modelOverrides.removeValue(forKey: tier)
        }
    }
}
