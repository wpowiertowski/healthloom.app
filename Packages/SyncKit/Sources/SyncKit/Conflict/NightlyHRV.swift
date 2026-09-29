// NightlyHRV.swift
//
// WP-65: one HRV number per night -- the average of the readings taken
// between 8 pm and 6 am -- for the Today tile, readiness and the coach.
// Showing the latest single reading (88 ms at 5:50 am) beside Google
// Health's nightly average (65 ms) read as a mismatch, and scoring
// readiness on one reading against a 30-day average inflated the HRV
// signal whenever the last reading was high.
//
// Each reading is placed on the wall clock of the time zone it was recorded
// in (`HKMetadataKeyTimeZone`, which HealthLoom stamps from Google's UTC
// offset), so a night slept in New York stays a New York night after a
// flight to London. A reading without a zone falls back to the caller's.
// Within a night only the preferred sleep source's readings count
// (`SleepSourcePreference`), so a Fitbit RMSSD night and a Watch SDNN night
// never blend into one average. `nonisolated`: it runs in HealthKit
// handlers.

import Foundation
#if canImport(HealthKit)
import HealthKit
#endif

/// A night, named by the local calendar date its evening falls on.
nonisolated public struct NightKey: Hashable, Comparable, Sendable {
    /// Days since 2001-01-01 of that civil date -- arithmetic stays trivial.
    public let dayNumber: Int

    public init(dayNumber: Int) { self.dayNumber = dayNumber }

    public static func < (lhs: NightKey, rhs: NightKey) -> Bool { lhs.dayNumber < rhs.dayNumber }

    public func adding(days: Int) -> NightKey { NightKey(dayNumber: dayNumber + days) }

    /// The civil date `time` falls on in `timeZone`.
    static func civilDay(of time: Date, in timeZone: TimeZone) -> NightKey {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let parts = local.dateComponents([.year, .month, .day], from: time)
        return NightKey(dayNumber: dayNumber(year: parts.year ?? 2001, month: parts.month ?? 1, day: parts.day ?? 1))
    }

    private static func dayNumber(year: Int, month: Int, day: Int) -> Int {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let date = utc.date(from: DateComponents(year: year, month: month, day: day)) ?? Date(timeIntervalSinceReferenceDate: 0)
        return Int((date.timeIntervalSinceReferenceDate / 86_400).rounded(.down))
    }

    /// Midnight at the start of this night's evening date in `calendar` --
    /// the date to show or key a daily reading by.
    public func startOfEveningDate(in calendar: Calendar) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let date = Date(timeIntervalSinceReferenceDate: TimeInterval(dayNumber) * 86_400)
        let parts = utc.dateComponents([.year, .month, .day], from: date)
        return calendar.date(from: parts) ?? date
    }
}

nonisolated public enum NightlyHRV {
    /// The night window on the local clock: 20:00 to 06:00.
    public static let eveningHour = 20
    public static let morningHour = 6
    /// How many earlier nights the readiness baseline averages.
    public static let baselineNights = 30

    public struct Reading: Sendable, Equatable {
        public var time: Date
        public var milliseconds: Double
        public var origin: SleepOrigin
        /// The zone it was recorded in, when known.
        public var timeZone: TimeZone?

        public init(time: Date, milliseconds: Double, origin: SleepOrigin, timeZone: TimeZone?) {
            self.time = time
            self.milliseconds = milliseconds
            self.origin = origin
            self.timeZone = timeZone
        }
    }

    /// The night a reading at `time` belongs to on `timeZone`'s clock:
    /// 20:00-23:59 is that date's night, 00:00-05:59 the previous date's;
    /// the daytime hours between belong to no night.
    public static func night(of time: Date, in timeZone: TimeZone) -> NightKey? {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let hour = local.component(.hour, from: time)
        let day = NightKey.civilDay(of: time, in: timeZone)
        if hour >= eveningHour { return day }
        if hour < morningHour { return day.adding(days: -1) }
        return nil
    }

    /// Each night's average, from the preferred source's readings only.
    public static func averages(
        _ readings: [Reading],
        preference: SleepSourcePreference,
        fallbackTimeZone: TimeZone
    ) -> [NightKey: Double] {
        var nights: [NightKey: [Reading]] = [:]
        for reading in readings {
            guard let night = night(of: reading.time, in: reading.timeZone ?? fallbackTimeZone) else { continue }
            nights[night, default: []].append(reading)
        }
        return nights.compactMapValues { night in
            let winners = SleepSourceSelection.winningSource(
                of: night, preference: preference, origin: \.origin, isAsleep: { _ in true }
            )
            guard !winners.isEmpty else { return nil }
            return winners.reduce(0) { $0 + $1.milliseconds } / Double(winners.count)
        }
    }

    /// The most recent single reading at or before `now`, from the source
    /// the nightly averages prefer (WP-72) -- a Fitbit's RMSSD and a
    /// watch's SDNN are different scales, so the Today tile's "latest"
    /// comes from the same device as its night. Nil with none.
    public static func latestReading(_ readings: [Reading], preference: SleepSourcePreference, now: Date) -> Reading? {
        let past = readings.filter { $0.time <= now }
        return SleepSourceSelection.winningSource(of: past, preference: preference, origin: \.origin, isAsleep: { _ in true })
            .max { $0.time < $1.time }
    }

    /// The latest night that has ended by `now` (a night ends at 06:00).
    public static func lastCompletedNight(before now: Date, in timeZone: TimeZone) -> NightKey {
        NightKey.civilDay(of: now.addingTimeInterval(-TimeInterval(morningHour) * 3600), in: timeZone).adding(days: -1)
    }

    /// How far back a night may be and still stand in for last night -- the
    /// 7-day freshness rule every "latest" reading follows.
    public static let freshNights = 7

    /// The most recent night with an average, up to and including the last
    /// completed one and no older than `freshNights`; nil with none.
    public static func latestNight(in averages: [NightKey: Double], lastCompleted: NightKey) -> NightKey? {
        averages.keys.filter { $0 <= lastCompleted && $0 > lastCompleted.adding(days: -freshNights) }.max()
    }

    /// The mean of the nightly averages of the `baselineNights` nights
    /// before `night` (not including it), or nil with none.
    public static func baseline(_ averages: [NightKey: Double], before night: NightKey) -> Double? {
        let earlier = averages.filter { $0.key < night && $0.key >= night.adding(days: -baselineNights) }.values
        guard !earlier.isEmpty else { return nil }
        return earlier.reduce(0, +) / Double(earlier.count)
    }

    #if canImport(HealthKit)
    /// A heart-rate-variability sample as a reading: milliseconds, source,
    /// and the zone from `HKMetadataKeyTimeZone` when present.
    public static func reading(from sample: HKQuantitySample) -> Reading {
        Reading(
            time: sample.startDate,
            milliseconds: sample.quantity.doubleValue(for: .secondUnit(with: .milli)),
            origin: SleepSourceSelection.origin(of: sample),
            timeZone: (sample.metadata?[HKMetadataKeyTimeZone] as? String).flatMap(TimeZone.init(identifier:))
        )
    }

    /// Every heart-rate-variability reading in `start ... end`, from all
    /// sources; empty on failure or without read access. The one query the
    /// Today tile, readiness and the coach share.
    public static func fetchReadings(from healthStore: HKHealthStore, start: Date, end: Date) async -> [Reading] {
        let type = HKQuantityType(.heartRateVariabilitySDNN)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil
            ) { _, samples, _ in
                continuation.resume(returning: (samples ?? []).compactMap { $0 as? HKQuantitySample }.map(reading(from:)))
            }
            healthStore.execute(query)
        }
    }
    #endif
}
