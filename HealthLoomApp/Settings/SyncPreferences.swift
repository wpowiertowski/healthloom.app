// SyncPreferences.swift
//
// WP-17 (implementation-plan.md): "Persist toggles in UserDefaults." A small,
// `UserDefaults`-backed wrapper around the set of `GoogleDataType`s the user
// has *disabled* from syncing -- disabling a type stops it from being synced
// but does not delete anything already written (that's WP-35's wipe flow,
// out of scope here).
//
// Dependency-injected `UserDefaults` (default `.standard` in production;
// tests pass an ephemeral `UserDefaults(suiteName:)` instance so they never
// touch the real app's defaults -- mirrors the DI seam `Secrets.KeychainStore`
// (WP-03) established for a different backing store, and the
// `LaunchConfiguration`/stub-injection pattern WP-10 used for the rest of
// this app target).
//
// **Where the disabled-type filter lives (WP-17 deliverable 3):** this WP is
// explicitly barred from touching `SyncEngine.swift` (SyncKit, WP-16's/other
// WPs' territory) or `HealthLoomApp.swift` (WP-16's territory), so the filter
// can't live inside the sync engine itself or the background-task registration
// site. It lives here instead, as a pure, static, side-effect-free function
// (`filterEnabled(_:disabled:)`) -- every *caller* of `SyncEngine.syncAll
// (types:)` is expected to run its candidate type list through this function
// first. Two call sites do so today:
//   1. `DashboardView.syncNow()` (this WP) -- the manual "Sync now" button.
//   2. WP-16's background-refresh handler (`SyncKit/BackgroundSync/`, not yet
//      landed as of this WP's session) -- **flagged here as a coordination
//      point per the handoff protocol**: WP-16 should construct its own
//      `SyncPreferences()` (reads the same `UserDefaults.standard` key) and
//      call `filteredForSync(_:)` / `SyncPreferences.filterEnabled(_:disabled:)`
//      on its own due-types list before calling `syncAll(types:)`, exactly as
//      `DashboardView` does below. This file is intentionally the single
//      source of truth for both the storage key and the filtering logic so
//      the two call sites can never drift apart.
//
// `@Observable`/`@MainActor` (project.yml's `SWIFT_DEFAULT_ACTOR_ISOLATION:
// MainActor` already makes this MainActor-isolated implicitly; annotated
// explicitly here for readability, matching `AppEnvironment`'s own style)
// so a SwiftUI `Toggle` binding backed by an instance of this type updates
// reactively without any extra plumbing.

import CoreModel
import Foundation
import Observation

@MainActor
@Observable
final class SyncPreferences {
    private static let disabledTypesDefaultsKey = "com.healthloom.settings.disabledSyncTypes"

    /// Every `GoogleDataType` this app can sync anywhere -- HealthKit *or*
    /// `LocalSample` (architecture.md D2) -- i.e. every non-`.skip` row of
    /// CoreModel's writability table (WP-17 deliverable 1: "every syncable
    /// type, not `.skip` ones"). `.skip` types have no sync destination at
    /// all, so a toggle for one would control nothing and is deliberately
    /// never offered.
    static let syncableTypes: [GoogleDataType] = GoogleDataType.allCases
        .filter { $0.writability != .skip }
        .sorted { $0.rawValue < $1.rawValue }

    private let defaults: UserDefaults

    /// The set of types the user has explicitly turned *off*. Absence from
    /// this set means "enabled" -- i.e. every syncable type defaults to
    /// enabled the first time `SyncPreferences` reads an empty/fresh
    /// `UserDefaults` domain (matches every prior sync behavior in this app,
    /// which never had a settings screen to disable anything).
    private(set) var disabledTypes: Set<GoogleDataType>

    /// Raw disabled-type values no `GoogleDataType` case in THIS build recognizes
    /// (third-party r9: forward-safety). A newer device may disable a type this
    /// build never heard of; dropping it on pull and pushing the narrowed set back
    /// would silently re-enable sync for it — a privacy-relevant opt-out reverted.
    /// Unknown values are carried verbatim: persisted, snapshotted, and re-pushed
    /// untouched, never offered as toggles. Single-sourced with `disabledTypes`
    /// (both persist through `persist()` and load through `loadDisabledTypes`).
    private(set) var unknownDisabledRawValues: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loaded = Self.loadDisabledTypes(from: defaults)
        self.disabledTypes = loaded.known
        self.unknownDisabledRawValues = loaded.unknown
    }

    // MARK: - Instance API (SettingsView / call sites)

    func isEnabled(_ type: GoogleDataType) -> Bool {
        !disabledTypes.contains(type)
    }

    func setEnabled(_ enabled: Bool, for type: GoogleDataType) {
        if enabled {
            disabledTypes.remove(type)
        } else {
            disabledTypes.insert(type)
        }
        persist()
    }

    /// The Google scope(s) that must be granted before `type` can actually
    /// sync -- always exactly one (`GoogleDataType.scope`), returned as a set
    /// for a uniform call shape alongside `Self.requiredScopes(for:)`.
    /// Consumed by `SettingsView` to call
    /// `GoogleAuthManager.ensure(scopes:presentationContextProvider:)` when a
    /// toggle turns a type on (WP-17 deliverable 2).
    func requiredScopes(toEnable type: GoogleDataType) -> Set<GoogleDataType.Scope> {
        [type.scope]
    }

    /// `types`, minus whichever ones the user has disabled -- the exact
    /// filter every `syncAll(types:)` call site should apply first (see the
    /// file header's coordination note). Convenience wrapper over the pure
    /// static function below, using this instance's current `disabledTypes`.
    func filteredForSync(_ types: [GoogleDataType]) -> [GoogleDataType] {
        Self.filterEnabled(types, disabled: disabledTypes)
    }

    // MARK: - iCloud sync surface

    /// Raw disabled-type values for the cloud snapshot (sorted for stable
    /// encoding). Unknown future cases survive as strings — see
    /// `SyncSettingsSnapshot`. Third-party r9: the union of known + carried
    /// unknown values (never the narrowed known-only set).
    func snapshotRawValues() -> [String] {
        (disabledTypes.map(\.rawValue) + unknownDisabledRawValues).sorted()
    }

    /// Applies a cloud-pulled snapshot. Unknown raw values are PRESERVED verbatim
    /// (third-party r9 — was `compactMap`, dropping them): a case this app version
    /// renamed or never knew cannot be toggled, but must round-trip untouched so
    /// this device's next push does not narrow the server set. The instance
    /// persists immediately so a force-quit cannot lose it.
    func replaceDisabledTypes(with rawValues: [String]) {
        var known: Set<GoogleDataType> = []
        var unknown: Set<String> = []
        for raw in rawValues {
            if let type = GoogleDataType(rawValue: raw) {
                known.insert(type)
            } else {
                unknown.insert(raw)
            }
        }
        disabledTypes = known
        unknownDisabledRawValues = unknown
        persist()
    }

    /// Re-reads from defaults (a pull applied through the sync engine's
    /// own instance; mirrors `InsightPreferences.reload`).
    func reload() {
        let loaded = Self.loadDisabledTypes(from: defaults)
        disabledTypes = loaded.known
        unknownDisabledRawValues = loaded.unknown
    }

    // MARK: - Pure functions (WP-17's required tests target these directly --
    // no `UserDefaults`, no instance, no side effects.)

    /// `types`, minus every member of `disabled`. Order-preserving,
    /// duplicate-preserving (mirrors `Array.filter`'s own semantics) -- the
    /// filtering function WP-17's "Tests" line asks for ("disabled type
    /// skipped by `syncAll`").
    static func filterEnabled(_ types: [GoogleDataType], disabled: Set<GoogleDataType>) -> [GoogleDataType] {
        types.filter { !disabled.contains($0) }
    }

    /// The union of Google scopes required to sync every type in `enabled`
    /// -- the "scope-computation from toggle set" pure function WP-17's
    /// "Tests" line asks for.
    static func requiredScopes(for enabledTypes: Set<GoogleDataType>) -> Set<GoogleDataType.Scope> {
        Set(enabledTypes.map(\.scope))
    }

    /// Every syncable type with a HealthKit write destination (round-8
    /// item 1): THE write-destination set feeding the share-request funnel.
    /// `HealthKitAuth.authorizedShareTypes` derives the actual `toShare` subset and
    /// `partitionedAuthorization` the `read:` subset (third-party r9: correlations
    /// such as Food are excluded from BOTH structurally — never by callers filtering
    /// this list). `.localOnly` types persist to
    /// `LocalSample`, never HealthKit, so requesting share for them
    /// would throw (no mapping) — but requesting only P0 left ~14
    /// writable types (floors, RHR, SpO2, resp-rate, VO2, height,
    /// body-fat, glucose, temp, hydration, nutrition…) permanently
    /// denied, with cursors never advancing. Same funnel shape as
    /// `syncableTypes`/`backfillTypes` — one source, not three lists.
    static let healthKitWritableTypes: [GoogleDataType] = syncableTypes.filter {
        if case .healthKit = $0.writability { return true }
        return false
    }

    /// The READ half of both share sheets (round-9 item 13): hoisted
    /// next to the share funnel so the two call sites (onboarding +
    /// Settings repair) can never drift apart again — that drift is
    /// exactly what stranded item-2's repair path.
    static let healthKitReadTypes: [GoogleDataType] = [
        .exercise, .heartRate, .steps, .sleep, .weight,
        .oxygenSaturation, .distance, .activeEnergyBurned,
        // Round-10 item 2: resting HR + HRV are the highest-weighted
        // readiness signals (and vitals fields) — omitting them from
        // the READ set left them permanently unreadable (share is not
        // read, and the denial is invisible). Both sheets share this
        // one source, so they land everywhere at once.
        .dailyRestingHeartRate, .heartRateVariability,
    ]

    /// The manual-Sync-Now type list (round-6 item 9): every SYNCABLE
    /// type (not just the P0 four — an enabled non-P0 row must update
    /// on demand, not only on background wake), minus disabled. Reads
    /// live defaults (fresh instance per call, mirroring DashboardView's
    /// established pattern). Tested directly; the View calls this one
    /// line.
    static func manualSyncTypes() -> [GoogleDataType] {
        let prefs = SyncPreferences()
        return prefs.filteredForSync(syncableTypes)
    }

    // MARK: - Persistence

    private func persist() {
        defaults.set(disabledTypes.map(\.rawValue) + unknownDisabledRawValues, forKey: Self.disabledTypesDefaultsKey)
    }

    private static func loadDisabledTypes(from defaults: UserDefaults) -> (known: Set<GoogleDataType>, unknown: Set<String>) {
        let rawValues = defaults.stringArray(forKey: disabledTypesDefaultsKey) ?? []
        var known: Set<GoogleDataType> = []
        var unknown: Set<String> = []
        for raw in rawValues {
            if let type = GoogleDataType(rawValue: raw) {
                known.insert(type)
            } else {
                unknown.insert(raw)
            }
        }
        return (known, unknown)
    }
}
