// SyncPreferencesTests.swift
//
// WP-17 (implementation-plan.md) "Tests" line: "scope-computation from
// toggle set (pure function); disabled type skipped by `syncAll`." Both
// targets are pure static functions on `SyncPreferences`
// (`HealthLoomApp/Settings/SyncPreferences.swift`) -- tested here directly,
// with no `UserDefaults` involved at all. A second group of tests covers the
// `UserDefaults`-backed instance API itself, using a bound
// `EphemeralDefaults` holder per test so nothing here ever touches
// `UserDefaults.standard` (the real app's defaults).

import Testing
import Foundation
@testable import HealthLoom
import CoreModel

@Suite("SyncPreferences - pure functions")
struct SyncPreferencesPureFunctionTests {
    @Test func filterEnabledExcludesDisabledType() async throws {
        let types: [GoogleDataType] = [.steps, .heartRate, .weight, .sleep]
        let disabled: Set<GoogleDataType> = [.weight]

        let result = SyncPreferences.filterEnabled(types, disabled: disabled)

        #expect(result == [.steps, .heartRate, .sleep])
    }

    @Test func filterEnabledWithNothingDisabledReturnsAllTypes() async throws {
        let types: [GoogleDataType] = [.steps, .heartRate, .weight, .sleep]

        let result = SyncPreferences.filterEnabled(types, disabled: [])

        #expect(result == types)
    }

    @Test func filterEnabledWithEverythingDisabledReturnsEmpty() async throws {
        let types: [GoogleDataType] = [.steps, .heartRate]

        let result = SyncPreferences.filterEnabled(types, disabled: [.steps, .heartRate])

        #expect(result.isEmpty)
    }

    @Test func filterEnabledIgnoresDisabledTypesNotInTheInputList() async throws {
        // A disabled type that isn't part of the candidate list at all (e.g.
        // the user disabled `.bodyFat` but this call site only ever syncs
        // the P0 four) must not affect the result.
        let types: [GoogleDataType] = [.steps, .heartRate]

        let result = SyncPreferences.filterEnabled(types, disabled: [.bodyFat])

        #expect(result == types)
    }

    @Test func requiredScopesUnionsAcrossEnabledTypes() async throws {
        // steps -> activityAndFitness, heartRate/weight -> healthMetrics,
        // sleep -> sleep (CoreModel's `GoogleDataType.scope`).
        let enabled: Set<GoogleDataType> = [.steps, .heartRate, .weight, .sleep]

        let scopes = SyncPreferences.requiredScopes(for: enabled)

        #expect(scopes == [.activityAndFitness, .healthMetrics, .sleep])
    }

    @Test func requiredScopesDeduplicatesSameScopeTypes() async throws {
        // heartRate and weight are both `.healthMetrics` -- the union must
        // collapse to one entry, not two.
        let enabled: Set<GoogleDataType> = [.heartRate, .weight]

        let scopes = SyncPreferences.requiredScopes(for: enabled)

        #expect(scopes == [.healthMetrics])
    }

    @Test func requiredScopesOfEmptySetIsEmpty() async throws {
        #expect(SyncPreferences.requiredScopes(for: []).isEmpty)
    }

    @Test func syncableTypesExcludesEverySkipType() async throws {
        let skipTypes = GoogleDataType.allCases.filter { $0.writability == .skip }

        for type in skipTypes {
            #expect(!SyncPreferences.syncableTypes.contains(type))
        }
        // Sanity: this isn't a vacuous check -- there really are `.skip`
        // types in CoreModel's table (per progress.md's WP-02 entry).
        #expect(!skipTypes.isEmpty)
    }

    @Test func syncableTypesIncludesEveryHealthKitAndLocalOnlyType() async throws {
        for type in GoogleDataType.allCases where type.writability != .skip {
            #expect(SyncPreferences.syncableTypes.contains(type))
        }
    }
}

@Suite("SyncPreferences - instance / UserDefaults persistence")
@MainActor
struct SyncPreferencesInstanceTests {
    /// Every test binds its own `EphemeralDefaults` holder (pre-cleaned
    /// suite, post-cleaned at deinit, janitor-backed at exit) — uniform
    /// with every other suite site (round-2 item 14).
    // Round-2 item 14: uniform ownership — the holder IS the cleanup
    // (pre-clean at init, post-clean at deinit, janitor at exit). The old
    // tuple-with-closure said "cleanup ordering is explicit"; the
    // explicitness that matters is the BINDING (holder alive for the
    // whole test), which `let ephemeral` gives.
    private func makeEphemeralDefaults() throws -> EphemeralDefaults {
        try EphemeralDefaults(prefix: "syncpreferences")
    }

    @Test func freshInstanceHasEveryTypeEnabled() async throws {
        let ephemeral = try makeEphemeralDefaults()
        let defaults = ephemeral.defaults
        let preferences = SyncPreferences(defaults: defaults)

        for type in SyncPreferences.syncableTypes {
            #expect(preferences.isEnabled(type))
        }
        #expect(preferences.disabledTypes.isEmpty)
    }

    @Test func disablingATypePersistsAndIsReflectedByIsEnabled() async throws {
        let ephemeral = try makeEphemeralDefaults()
        let defaults = ephemeral.defaults
        let preferences = SyncPreferences(defaults: defaults)

        preferences.setEnabled(false, for: .weight)

        #expect(!preferences.isEnabled(.weight))
        #expect(preferences.isEnabled(.steps))
        #expect(preferences.disabledTypes == [.weight])
    }

    @Test func disabledStatePersistsAcrossInstancesOverTheSameDefaults() async throws {
        let ephemeral = try makeEphemeralDefaults()
        let defaults = ephemeral.defaults
        let first = SyncPreferences(defaults: defaults)
        first.setEnabled(false, for: .sleep)

        let second = SyncPreferences(defaults: defaults)

        #expect(!second.isEnabled(.sleep))
    }

    @Test func reEnablingRemovesFromDisabledSet() async throws {
        let ephemeral = try makeEphemeralDefaults()
        let defaults = ephemeral.defaults
        let preferences = SyncPreferences(defaults: defaults)
        preferences.setEnabled(false, for: .heartRate)
        #expect(!preferences.isEnabled(.heartRate))

        preferences.setEnabled(true, for: .heartRate)

        #expect(preferences.isEnabled(.heartRate))
        #expect(preferences.disabledTypes.isEmpty)
    }

    @Test func filteredForSyncConsultsCurrentDisabledSet() async throws {
        let ephemeral = try makeEphemeralDefaults()
        let defaults = ephemeral.defaults
        let preferences = SyncPreferences(defaults: defaults)
        preferences.setEnabled(false, for: .weight)

        let result = preferences.filteredForSync([.steps, .heartRate, .weight, .sleep])

        #expect(result == [.steps, .heartRate, .sleep])
    }

    @Test func requiredScopesToEnableReturnsTheTypesOwnScope() async throws {
        let ephemeral = try makeEphemeralDefaults()
        let defaults = ephemeral.defaults
        let preferences = SyncPreferences(defaults: defaults)

        #expect(preferences.requiredScopes(toEnable: .sleep) == [.sleep])
        #expect(preferences.requiredScopes(toEnable: .steps) == [.activityAndFitness])
    }

    @Test func separateInstancesOverDifferentDefaultsDoNotInterfere() async throws {
        let ephemeralA = try makeEphemeralDefaults()
        let ephemeralB = try makeEphemeralDefaults()
        let defaultsA = ephemeralA.defaults
        let defaultsB = ephemeralB.defaults

        let a = SyncPreferences(defaults: defaultsA)
        let b = SyncPreferences(defaults: defaultsB)

        a.setEnabled(false, for: .steps)

        #expect(!a.isEnabled(.steps))
        #expect(b.isEnabled(.steps))
    }
}
