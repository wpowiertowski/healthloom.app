// SleepSourceTests.swift
//
// WP-60: which source's sleep wins a night, and the stored preference.

import Foundation
import Testing
@testable import SyncKit

@Suite struct SleepSourceTests {
    struct Stage: Equatable {
        var origin: SleepOrigin
        var asleep: Bool
        var start: Date
    }

    static let evening = Date(timeIntervalSince1970: 1_790_463_600) // 23:00 UTC
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    static func stage(_ origin: SleepOrigin, asleep: Bool = true, hours: Double = 0) -> Stage {
        Stage(origin: origin, asleep: asleep, start: evening.addingTimeInterval(hours * 3600))
    }

    static func winner(_ night: [Stage], _ preference: SleepSourcePreference) -> [Stage] {
        SleepSourceSelection.winningSource(of: night, preference: preference, origin: \.origin, isAsleep: \.asleep)
    }

    // catches: merging both devices' stages (the Fitbit's awake stretch
    // read as sleep because the watch called it asleep), or the preference
    // not choosing the winner.
    @Test func thePreferredSourceWinsANightBothRecorded() {
        let night = [
            Self.stage(.fitbit), Self.stage(.fitbit, asleep: false, hours: 3),
            Self.stage(.appleWatch), Self.stage(.otherApp),
        ]
        #expect(Self.winner(night, .fitbit) == [Self.stage(.fitbit), Self.stage(.fitbit, asleep: false, hours: 3)])
        #expect(Self.winner(night, .appleWatch) == [Self.stage(.appleWatch)])
    }

    // catches: a night the preferred device missed going blank instead of
    // falling back, or another app beating the second device.
    @Test func aNightThePreferredSourceMissedFallsBack() {
        #expect(Self.winner([Self.stage(.appleWatch), Self.stage(.otherApp)], .fitbit) == [Self.stage(.appleWatch)])
        #expect(Self.winner([Self.stage(.otherApp)], .fitbit) == [Self.stage(.otherApp)])
        #expect(Self.winner([], .fitbit).isEmpty)
    }

    // catches: a source that logged only in-bed or awake time (the Fitbit
    // off the wrist but still reporting) winning the night with no sleep.
    @Test func aSourceWithoutAsleepTimeDoesNotWin() {
        let night = [Self.stage(.fitbit, asleep: false), Self.stage(.appleWatch)]
        #expect(Self.winner(night, .fitbit) == [Self.stage(.appleWatch)])
    }

    // catches: choosing one winner for a whole month instead of per night.
    @Test func eachNightPicksItsOwnWinner() {
        let firstNight = [Self.stage(.fitbit), Self.stage(.appleWatch, hours: 3)]  // 23:00, 02:00: one night
        let secondNight = [Self.stage(.appleWatch, hours: 24)]                      // the Fitbit was charging
        let picked = SleepSourceSelection.winningSources(
            of: firstNight + secondNight, preference: .fitbit, calendar: Self.utc,
            start: \.start, origin: \.origin, isAsleep: \.asleep
        )
        #expect(picked == [Self.stage(.fitbit), Self.stage(.appleWatch, hours: 24)])
    }

    // catches: an unset or corrupted preference reading as Apple Watch.
    @Test func theStoredPreferenceDefaultsToFitbit() throws {
        let suite = "SleepSourceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SleepSourcePreference.current(defaults: defaults) == .fitbit)
        defaults.set("garbage", forKey: SleepSourcePreference.defaultsKey)
        #expect(SleepSourcePreference.current(defaults: defaults) == .fitbit)
        defaults.set(SleepSourcePreference.appleWatch.rawValue, forKey: SleepSourcePreference.defaultsKey)
        #expect(SleepSourcePreference.current(defaults: defaults) == .appleWatch)
    }

    // catches: the build-21 crash shape -- this runs inside HealthKit result
    // handlers; with main-actor isolation it no longer compiles here.
    @Test func runsOffTheMainActor() async {
        let night = [Self.stage(.appleWatch)]
        let count = await Task.detached {
            SleepSourceSelection.winningSource(of: night, preference: .fitbit, origin: \.origin, isAsleep: \.asleep).count
        }.value
        #expect(count == 1)
    }
}
