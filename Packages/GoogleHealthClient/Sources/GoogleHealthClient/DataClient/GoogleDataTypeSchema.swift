// GoogleDataTypeSchema.swift
//
// WP-51: how each Google Health API data type is actually read, from the
// published v4 reference (developers.google.com/health/reference/rest/v4,
// fetched 2026-09-27). The client was first written from pre-release notes
// that assumed one flat point shape (`dataPointId`, `startTime`, `endTime`,
// `value{}`) and a POST body; the shipped API is a GET with an AIP-160
// `filter`, and every point is a typed union member (`heartRate`,
// `weight`, ...) with its own time field and units. The first real sync
// returned 404 for every type.
//
// One row per readable type, and nothing else in the client knows these
// facts:
//   - `unionKey`   the camelCase response field (`heart_rate` → `heartRate`)
//   - `time`       which time field the type carries, and so which filter
//                  field a window uses
//   - `endpoint`   `:reconcile` (merged across devices, architecture.md D1)
//                  unless the type isn't reconcilable
//   - `values`     how response fields become the neutral `GoogleDataPoint`
//                  values TypeMapper reads (`bpm`, `count`, `mass` in kg ...),
//                  with unit conversion done here, once
//   - `keepsPayload` sessions and local-only types keep their raw typed
//                  object as `sessionPayload`
//
// Types without a row (`total_calories`, `calories_in_heart_rate_zone`,
// `food`, and the never-synced skip types) aren't readable as data points:
// the first two exist only through roll-ups, and `food` is a catalogue
// entry with no time field. Reading one throws `.notAvailableFromGoogle`.

import CoreModel
import Foundation

/// The time field a data type carries, which also fixes its filter field.
nonisolated enum GoogleTimeShape: Sendable, Equatable {
    /// `interval` (ObservationTimeInterval): filter `<type>.interval.start_time`.
    case observationInterval
    /// `sampleTime.physicalTime`: filter `<type>.sample_time.physical_time`.
    case sampleTime
    /// `date` {year, month, day}: filter `<type>.date`, civil `YYYY-MM-DD`.
    case date
    /// `interval` (SessionTimeInterval): filter `<type>.interval.civil_start_time`.
    case session
    /// Sleep filters on the session's END (`sleep.interval.end_time`).
    case sleepSession
    /// ECG filters on `start_time` and only supports `>=`.
    case ecgSession
}

/// Which read method serves a type. ECG, irregular-rhythm notifications and
/// food aren't in `ReconciledDataPoint`'s union, so they're listed raw.
nonisolated enum GoogleReadEndpoint: String, Sendable {
    case reconcile = ":reconcile"
    case list = ""
}

/// One output value: `outKey` in `GoogleDataPoint.values`, read from a key
/// path inside the type's union object, then multiplied by `scale`.
nonisolated struct GoogleValueRule: Sendable {
    enum Source: Sendable {
        /// A numeric field (JSON number or int64-as-string) at this path.
        case path([String])
        /// `nutrients[]` entry whose `nutrient` equals this enum value;
        /// reads `quantity.grams`.
        case nutrient(String)
        /// Sum of `field` across the array at `array`.
        case sum(array: String, field: String)
    }

    let outKey: String
    let source: Source
    var scale: Double = 1
}

nonisolated struct GoogleDataTypeSchema: Sendable {
    let type: GoogleDataType
    let unionKey: String
    let time: GoogleTimeShape
    let endpoint: GoogleReadEndpoint
    let values: [GoogleValueRule]
    var keepsPayload: Bool = false
    /// A field that tells apart points sharing one interval, folded into the
    /// synthetic ID. Active Zone Minutes reports one point per heart-rate
    /// zone for the same interval; type + start + end alone would collide.
    var idDiscriminator: String? = nil

    /// The table. `nil` means the type isn't readable as data points.
    static func schema(for type: GoogleDataType) -> GoogleDataTypeSchema? {
        func row(
            _ time: GoogleTimeShape,
            _ values: [GoogleValueRule],
            endpoint: GoogleReadEndpoint = .reconcile,
            keepsPayload: Bool = false,
            idDiscriminator: String? = nil
        ) -> GoogleDataTypeSchema {
            GoogleDataTypeSchema(
                type: type, unionKey: unionKey(for: type), time: time,
                endpoint: endpoint, values: values, keepsPayload: keepsPayload,
                idDiscriminator: idDiscriminator
            )
        }
        func value(_ outKey: String, _ path: String..., scale: Double = 1) -> GoogleValueRule {
            GoogleValueRule(outKey: outKey, source: .path(path), scale: scale)
        }

        switch type {
        // Activity
        case .steps: return row(.observationInterval, [value("count", "count")])
        case .floors: return row(.observationInterval, [value("count", "count")])
        case .distance: return row(.observationInterval, [value("distance", "millimeters", scale: 0.001)])
        case .activeEnergyBurned: return row(.observationInterval, [value("kcal", "kcal")])

        // Heart
        case .heartRate: return row(.sampleTime, [value("bpm", "beatsPerMinute")])
        case .dailyRestingHeartRate: return row(.date, [value("bpm", "beatsPerMinute")])
        case .heartRateVariability:
            return row(.sampleTime, [
                value("rmssd_ms", "rootMeanSquareOfSuccessiveDifferencesMilliseconds"),
                value("sdnn_ms", "standardDeviationMilliseconds"),
            ])

        // Vitals and body
        case .oxygenSaturation: return row(.sampleTime, [value("percentage", "percentage")])
        case .respiratoryRateSleepSummary:
            return row(.sampleTime, [value("breathsPerMinute", "fullSleepStats", "breathsPerMinute")])
        case .vo2Max: return row(.sampleTime, [value("value", "vo2Max")])
        case .runVO2Max: return row(.sampleTime, [value("value", "runVo2Max")])
        case .weight: return row(.sampleTime, [value("mass", "weightGrams", scale: 0.001)])
        case .height: return row(.sampleTime, [value("meters", "heightMillimeters", scale: 0.001)])
        case .bodyFat: return row(.sampleTime, [value("percentage", "percentage")])
        case .bloodGlucose: return row(.sampleTime, [value("mg_per_dl", "bloodGlucoseMilligramsPerDeciliter")])
        case .coreBodyTemperature: return row(.sampleTime, [value("celsius", "temperatureCelsius")])

        // Nutrition
        case .hydrationLog:
            return row(.session, [value("liters", "amountConsumed", "milliliters", scale: 0.001)])
        case .nutritionLog:
            return row(.session, [
                value("energy_kcal", "energy", "kcal"),
                value("carbs_g", "totalCarbohydrate", "grams"),
                value("fat_g", "totalFat", "grams"),
                GoogleValueRule(outKey: "protein_g", source: .nutrient("PROTEIN")),
            ])

        // Sessions: the raw typed object rides along as `sessionPayload`.
        case .sleep: return row(.sleepSession, [], keepsPayload: true)
        case .exercise:
            return row(.session, [
                value("distance", "metricsSummary", "distanceMillimeters", scale: 0.001),
                value("kcal", "metricsSummary", "caloriesKcal"),
            ], keepsPayload: true)

        // Local-only (not written to HealthKit): keep what's there.
        case .activeMinutes:
            return row(.observationInterval, [
                GoogleValueRule(outKey: "minutes", source: .sum(array: "activeMinutesByActivityLevel", field: "activeMinutes")),
            ], keepsPayload: true)
        case .activeZoneMinutes:
            return row(
                .observationInterval, [value("minutes", "activeZoneMinutes")],
                keepsPayload: true, idDiscriminator: "heartRateZone"
            )
        case .electrocardiogram:
            return row(.ecgSession, [value("bpm", "beatsPerMinuteAvg")], endpoint: .list, keepsPayload: true)
        case .irregularRhythmNotification:
            return row(.session, [], endpoint: .list, keepsPayload: true)

        // Not readable as data points (see the file header).
        case .totalCalories, .caloriesInHeartRateZone, .food, .foodMeasurementUnit,
             .activityLevel, .altitude, .dailyHeartRateVariability, .dailyHeartRateZones,
             .dailyOxygenSaturation, .dailyRespiratoryRate, .dailySleepTemperatureDerivations,
             .dailyVO2Max, .sedentaryPeriod, .swimLengthsData, .timeInHeartRateZone:
            return nil
        }
    }

    /// Exercise and sleep cap at 25 per page (the API's own limit); other
    /// types take the API's maximum of 10,000. Heart rate runs to tens of
    /// thousands of samples a day: at 1,000 a page a 30-day backfill chunk
    /// needed ~500 pages, five times the walk's 100-page cap, and failed
    /// every retry (WP-52).
    var pageSize: Int {
        type == .sleep || type == .exercise ? 25 : 10_000
    }

    /// `page` held to `..< until`. The server applies every other type's
    /// upper bound itself; ECG's filter supports only `>=` on start time, so
    /// without this a caller walking day by day would get every recording
    /// since `since` once per day.
    func holdingToWindow(_ page: Page, until: Date) -> Page {
        guard time == .ecgSession else { return page }
        return Page(points: page.points.filter { $0.start < until }, nextPageToken: page.nextPageToken)
    }

    /// The AIP-160 time window for this type. The filter prefix is the snake
    /// name (`heart_rate`), the field follows the type's time shape. Physical
    /// times are RFC-3339 UTC; civil times and dates are the wearer's local
    /// clock, read in `timeZone`.
    func filter(since: Date, until: Date, timeZone: TimeZone) -> String {
        let name = type.rawValue
        let physical = ISO8601Formatting.string(from:)
        func window(_ field: String, _ from: String, _ to: String) -> String {
            "\(name).\(field) >= \"\(from)\" AND \(name).\(field) < \"\(to)\""
        }
        switch time {
        case .observationInterval:
            return window("interval.start_time", physical(since), physical(until))
        case .sampleTime:
            return window("sample_time.physical_time", physical(since), physical(until))
        case .date:
            // Upper bound is the day after `until`, so today's summary counts.
            let nextDay = until.addingTimeInterval(24 * 3600)
            return window("date", Self.civil(since, "yyyy-MM-dd", timeZone), Self.civil(nextDay, "yyyy-MM-dd", timeZone))
        case .session:
            let format = "yyyy-MM-dd'T'HH:mm:ss"
            return window("interval.civil_start_time", Self.civil(since, format, timeZone), Self.civil(until, format, timeZone))
        case .sleepSession:
            // A night is found by when it ended, so one that started before
            // the window but ended inside it isn't missed.
            return window("interval.end_time", physical(since), physical(until))
        case .ecgSession:
            // ECG supports only `>=` on start time.
            return "\(name).interval.start_time >= \"\(physical(since))\""
        }
    }

    static func civil(_ date: Date, _ format: String, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    /// `heart_rate` → `heartRate`, `run_vo2_max` → `runVo2Max`: the response's
    /// union field is the lowerCamel form of the filter (snake) name.
    static func unionKey(for type: GoogleDataType) -> String {
        let parts = type.rawValue.split(separator: "_")
        guard let first = parts.first else { return type.rawValue }
        return String(first) + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }
}
