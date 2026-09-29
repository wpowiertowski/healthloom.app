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
// never blend into one average. Each night keeps the device it came from
// (WP-74), and everything compared with a night -- its baseline, the
// "latest" reading beside it -- comes from that same device: the two
// statistics are different scales. `nonisolated`: it runs in HealthKit
// handlers.

import Foundation
#if canImport(HealthKit)
import HealthKit
#endif

/// A night, named by the local calendar date its evening falls on.
nonisolated public struct NightKey: Hashable, Comparable, Sendable {
    /// Days since 2001-01-01 of that civil date -- arithmetic stays trivial.
    let dayNumber: Int

    init(dayNumber: Int) { self.dayNumber = dayNumber }

    public static func < (lhs: NightKey, rhs: NightKey) -> Bool { lhs.dayNumber < rhs.dayNumber }

    func adding(days: Int) -> NightKey { NightKey(dayNumber: dayNumber + days) }

    /// The civil date `time` falls on in `timeZone`. Arithmetic on the
    /// zone's offset at that instant, not a `Calendar`: this runs once per
    /// reading, thousands of times per refresh (WP-74).
    static func civilDay(of time: Date, in timeZone: TimeZone) -> NightKey {
        NightKey(dayNumber: Int((localSeconds(of: time, in: timeZone) / 86_400).rounded(.down)))
    }

    /// Seconds since 2001-01-01 00:00 on `timeZone`'s wall clock.
    static func localSeconds(of time: Date, in timeZone: TimeZone) -> TimeInterval {
        time.timeIntervalSinceReferenceDate + TimeInterval(timeZone.secondsFromGMT(for: time))
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
    static let eveningHour = 20
    static let morningHour = 6
    /// How many earlier nights the readiness baseline averages.
    static let baselineNights = 30
    /// How far back a night may be and still stand in for last night -- the
    /// 7-day freshness rule every "latest" reading follows.
    static let freshNights = 7

    public struct Reading: Sendable, Equatable {
        public let time: Date
        public let milliseconds: Double
        let origin: SleepOrigin
        /// The zone it was recorded in, when known.
        let timeZone: TimeZone?

        init(time: Date, milliseconds: Double, origin: SleepOrigin, timeZone: TimeZone?) {
            self.time = time
            self.milliseconds = milliseconds
            self.origin = origin
            self.timeZone = timeZone
        }
    }

    /// One night's average and the device whose readings made it.
    public struct NightAverage: Sendable, Equatable {
        public let milliseconds: Double
        let origin: SleepOrigin
    }

    /// Last night as the Today tile and readiness read it, computed once
    /// per refresh and shared by both (WP-74).
    public struct Snapshot: Sendable, Equatable {
        /// The latest completed, fresh night with readings.
        public let night: NightKey
        public let average: NightAverage
        /// The mean of the 30 nights before it recorded by the same device;
        /// nil with none.
        public let baseline: Double?
        /// The newest single reading at or before now from that device.
        public let latest: Reading?
    }

    /// How far back `snapshot` needs readings: the baseline's nights
    /// before the freshest night that may stand in for last night.
    static let snapshotSpan = TimeInterval(baselineNights + freshNights + 1) * 86_400

    /// The night a reading at `time` belongs to on `timeZone`'s clock:
    /// 20:00-23:59 is that date's night, 00:00-05:59 the previous date's;
    /// the daytime hours between belong to no night.
    static func night(of time: Date, in timeZone: TimeZone) -> NightKey? {
        let local = NightKey.localSeconds(of: time, in: timeZone)
        let day = NightKey(dayNumber: Int((local / 86_400).rounded(.down)))
        let hour = Int((local - TimeInterval(day.dayNumber) * 86_400) / 3600)
        if hour >= eveningHour { return day }
        if hour < morningHour { return day.adding(days: -1) }
        return nil
    }

    /// Each night's average, from the preferred source's readings only.
    static func averages(
        _ readings: [Reading],
        preference: SleepSourcePreference,
        fallbackTimeZone: TimeZone
    ) -> [NightKey: NightAverage] {
        var nights: [NightKey: [Reading]] = [:]
        for reading in readings {
            guard let night = night(of: reading.time, in: reading.timeZone ?? fallbackTimeZone) else { continue }
            nights[night, default: []].append(reading)
        }
        return nights.compactMapValues { night in
            let winners = SleepSourceSelection.winningSource(
                of: night, preference: preference, origin: \.origin, isAsleep: { _ in true }
            )
            guard let origin = winners.first?.origin else { return nil }
            return NightAverage(milliseconds: winners.reduce(0) { $0 + $1.milliseconds } / Double(winners.count), origin: origin)
        }
    }

    /// Last night, its same-device baseline and latest reading; nil with no
    /// completed night inside the freshness window.
    static func snapshot(
        _ readings: [Reading],
        preference: SleepSourcePreference,
        timeZone: TimeZone,
        now: Date
    ) -> Snapshot? {
        let averages = averages(readings, preference: preference, fallbackTimeZone: timeZone)
        let lastCompleted = lastCompletedNight(before: now, in: timeZone)
        guard let night = latestNight(in: averages, lastCompleted: lastCompleted),
              let average = averages[night]
        else { return nil }
        return Snapshot(
            night: night,
            average: average,
            baseline: baseline(averages, before: night),
            latest: latestReading(readings, origin: average.origin, now: now)
        )
    }

    /// Every completed night whose whole 20:00-06:00 window lies inside
    /// `start ... end`, oldest first -- the coach's nights (WP-74). A night
    /// still in progress, or one the window starts partway through, would
    /// be an average of a few readings passed off as a night's.
    public static func completedNights(
        _ readings: [Reading],
        preference: SleepSourcePreference,
        timeZone: TimeZone,
        from start: Date,
        to end: Date
    ) -> [(night: NightKey, average: NightAverage)] {
        // The first night starting at or after `start`: a start after
        // 20:00 is past that date's evening.
        let firstFull = NightKey.civilDay(of: start.addingTimeInterval(TimeInterval(24 - eveningHour) * 3600), in: timeZone)
        let lastCompleted = lastCompletedNight(before: end, in: timeZone)
        return averages(readings, preference: preference, fallbackTimeZone: timeZone)
            .filter { $0.key >= firstFull && $0.key <= lastCompleted }
            .sorted { $0.key < $1.key }
            .map { (night: $0.key, average: $0.value) }
    }

    /// The most recent single reading at or before `now` from `origin` --
    /// the device the displayed night came from (WP-72, WP-74). Nil with
    /// none.
    static func latestReading(_ readings: [Reading], origin: SleepOrigin, now: Date) -> Reading? {
        readings.filter { $0.origin == origin && $0.time <= now }.max { $0.time < $1.time }
    }

    /// The latest night that has ended by `now` (a night ends at 06:00).
    static func lastCompletedNight(before now: Date, in timeZone: TimeZone) -> NightKey {
        NightKey.civilDay(of: now.addingTimeInterval(-TimeInterval(morningHour) * 3600), in: timeZone).adding(days: -1)
    }

    /// The most recent night with an average, up to and including the last
    /// completed one and no older than `freshNights`; nil with none.
    static func latestNight(in averages: [NightKey: NightAverage], lastCompleted: NightKey) -> NightKey? {
        averages.keys.filter { $0 <= lastCompleted && $0 > lastCompleted.adding(days: -freshNights) }.max()
    }

    /// The mean of the nightly averages of the `baselineNights` nights
    /// before `night` (not including it) recorded by the same device, or
    /// nil with none. A watch SDNN night against a Fitbit RMSSD baseline
    /// read as a large drop that never happened (WP-74).
    static func baseline(_ averages: [NightKey: NightAverage], before night: NightKey) -> Double? {
        guard let origin = averages[night]?.origin else { return nil }
        let earlier = averages
            .filter { $0.key < night && $0.key >= night.adding(days: -baselineNights) && $0.value.origin == origin }
            .map(\.value.milliseconds)
        guard !earlier.isEmpty else { return nil }
        return earlier.reduce(0, +) / Double(earlier.count)
    }

    #if canImport(HealthKit)
    /// A heart-rate-variability sample as a reading: milliseconds, source,
    /// and the zone from `HKMetadataKeyTimeZone` when present.
    static func reading(from sample: HKQuantitySample) -> Reading {
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

    /// Fetches `snapshotSpan` of readings and computes the snapshot off the
    /// main actor (`@concurrent`: thousands of readings per refresh).
    @concurrent
    public static func fetchSnapshot(
        from healthStore: HKHealthStore,
        preference: SleepSourcePreference,
        timeZone: TimeZone,
        now: Date
    ) async -> Snapshot? {
        let readings = await fetchReadings(from: healthStore, start: now.addingTimeInterval(-snapshotSpan), end: now)
        return snapshot(readings, preference: preference, timeZone: timeZone, now: now)
    }
    #endif
}
