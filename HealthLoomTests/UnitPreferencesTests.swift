// UnitPreferencesTests.swift
//
// WP-79: per-measurement units -- region defaults, choices that persist one
// kind at a time, and unchosen kinds that keep following the region.

import Foundation
import Testing
@testable import HealthLoom

@MainActor
@Suite("Unit preferences")
struct UnitPreferencesTests {
    // catches: a US phone defaulting to kilometres, or the UK's miles
    // dragging its weights and pools to imperial too.
    @Test func regionsDefaultToWhatTheyMeasureIn() {
        #expect(UnitPreferences.regionDefault(for: Locale(identifier: "en_US")) == .imperial)
        #expect(UnitPreferences.regionDefault(for: Locale(identifier: "de_DE")) == .metric)
        let uk = UnitPreferences.regionDefault(for: Locale(identifier: "en_GB"))
        #expect(uk.distance == .miles)
        #expect(uk.weight == .kilograms && uk.pool == .meters && uk.bodyLength == .metric)
    }

    // catches: a choice lost on relaunch, one choice overwriting another
    // kind, or a chosen unit snapping back when the region changes.
    @Test func choicesPersistOneKindAtATime() throws {
        let suite = "unit-preferences-tests"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = UnitSettings(defaults: defaults, locale: Locale(identifier: "en_US"))
        settings.set(\.weight, to: .kilograms)
        settings.set(\.energy, to: .kilojoules)
        #expect(settings.preferences.weight == .kilograms)
        #expect(settings.preferences.distance == .miles)

        let relaunched = UnitSettings(defaults: defaults, locale: Locale(identifier: "de_DE"))
        #expect(relaunched.preferences.weight == .kilograms)
        #expect(relaunched.preferences.energy == .kilojoules)
        // Never chosen: follows the new region.
        #expect(relaunched.preferences.distance == .kilometers)
        #expect(relaunched.preferences.pool == .meters)
    }
}
