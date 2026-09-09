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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.disabledTypes = Self.loadDisabledTypes(from: defaults)
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
    /// `SyncSettingsSnapshot`.
    func snapshotRawValues() -> [String] {
        disabledTypes.map(\.rawValue).sorted()
    }

    /// Applies a cloud-pulled snapshot. Unknown raw values are dropped
    /// (a case this app version renamed cannot be toggled anyway); the
    /// instance persists immediately so a force-quit cannot lose it.
    func replaceDisabledTypes(with rawValues: [String]) {
        disabledTypes = Set(rawValues.compactMap(GoogleDataType.init(rawValue:)))
        persist()
    }

    /// Re-reads from defaults (a pull applied through the sync engine's
    /// own instance; mirrors `InsightPreferences.reload`).
    func reload() {
        disabledTypes = Self.loadDisabledTypes(from: defaults)
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

    // MARK: - Persistence

    private func persist() {
        defaults.set(disabledTypes.map(\.rawValue), forKey: Self.disabledTypesDefaultsKey)
    }

    private static func loadDisabledTypes(from defaults: UserDefaults) -> Set<GoogleDataType> {
        let rawValues = defaults.stringArray(forKey: disabledTypesDefaultsKey) ?? []
        return Set(rawValues.compactMap(GoogleDataType.init(rawValue:)))
    }
}
