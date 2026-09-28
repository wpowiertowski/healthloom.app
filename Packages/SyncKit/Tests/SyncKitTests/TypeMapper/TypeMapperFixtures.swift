// TypeMapperFixtures.swift
//
// WP-07 (implementation-plan.md): "reuse/reference [existing fixtures] rather
// than inventing new ones for the same types." `GoogleDataPoint` decoding
// (and its backing JSON fixtures) lives in `GoogleHealthClientTests`, a
// different package's test target this one can't import, so these helpers
// reconstruct the exact same scenarios as literal `GoogleDataPoint` values --
// same IDs, timestamps, device names, and field values -- as the four
// existing fixtures under
// `Packages/GoogleHealthClient/Tests/GoogleHealthClientTests/Fixtures/GoogleHealth/`:
// `steps.json` (point `steps-0001`), `heart-rate.json` (point `hr-0001`),
// `weight.json` (point `weight-0001`), `sleep.json` (point `sleep-0001`).
// Every default parameter value below traces back to one of those files;
// overridable parameters exist only so out-of-range/edge-case tests can
// perturb a single field without hand-rolling a whole `GoogleDataPoint`.

import CoreModel
import Foundation
import GoogleHealthClient
@testable import SyncKit

enum TypeMapperFixtures {
    static func date(_ iso8601: String) -> Date {
        guard let date = ISO8601DateFormatter().date(from: iso8601) else {
            preconditionFailure("Fixture date literal is not valid ISO 8601: \(iso8601)")
        }
        return date
    }

    /// Mirrors `steps.json`'s `steps-0001` point (`482` steps,
    /// 2026-07-01T00:00:00Z–01:00:00Z, Fitbit Air).
    static func stepsPoint(
        id: String = "steps-0001",
        start: Date = date("2026-07-01T00:00:00Z"),
        end: Date = date("2026-07-01T01:00:00Z"),
        count: Double = 482,
        deviceDisplayName: String? = "Fitbit Air"
    ) -> GoogleDataPoint {
        GoogleDataPoint(
            id: id,
            dataType: .steps,
            start: start,
            end: end,
            source: DataSource(
                platform: "IOS",
                deviceDisplayName: deviceDisplayName,
                recordingMethod: "AUTOMATICALLY_RECORDED"
            ),
            values: ["count": count]
        )
    }

    /// Mirrors `heart-rate.json`'s `hr-0001` point (`58` bpm,
    /// 2026-07-01T07:30:00Z instant, Fitbit Air).
    static func heartRatePoint(
        id: String = "hr-0001",
        start: Date = date("2026-07-01T07:30:00Z"),
        end: Date = date("2026-07-01T07:30:00Z"),
        bpm: Double = 58,
        deviceDisplayName: String? = "Fitbit Air"
    ) -> GoogleDataPoint {
        GoogleDataPoint(
            id: id,
            dataType: .heartRate,
            start: start,
            end: end,
            source: DataSource(
                platform: "IOS",
                deviceDisplayName: deviceDisplayName,
                recordingMethod: "AUTOMATICALLY_RECORDED"
            ),
            values: ["bpm": bpm]
        )
    }

    /// Mirrors `weight.json`'s `weight-0001` point (`70.5` kg per that
    /// fixture's own documented assumption, 2026-07-01T06:45:00Z instant,
    /// Fitbit Aria Air, manual entry).
    static func weightPoint(
        id: String = "weight-0001",
        start: Date = date("2026-07-01T06:45:00Z"),
        end: Date = date("2026-07-01T06:45:00Z"),
        mass: Double = 70.5,
        deviceDisplayName: String? = "Fitbit Aria Air"
    ) -> GoogleDataPoint {
        GoogleDataPoint(
            id: id,
            dataType: .weight,
            start: start,
            end: end,
            source: DataSource(
                platform: "IOS",
                deviceDisplayName: deviceDisplayName,
                recordingMethod: "MANUAL_ENTRY"
            ),
            values: ["mass": mass]
        )
    }

    // MARK: - WP-11 additions
    //
    // Mirrors the new JSON fixtures added under
    // `Packages/GoogleHealthClient/Tests/GoogleHealthClientTests/Fixtures/GoogleHealth/`
    // for this WP, same reasoning as the header comment above: SyncKit's
    // test target can't import GoogleHealthClientTests, so these
    // reconstruct the same scenario -- same IDs/timestamps/device names/
    // field values -- as literal `GoogleDataPoint`s.

    /// Mirrors `distance.json`'s `distance-0001` point (15000mm on the wire,
    /// already normalized to `15.0` meters by the time it reaches
    /// `GoogleDataPoint.values["distance"]` -- see that fixture's own
    /// `_comment` and GoogleHealthClient's `GoogleDataTypeSchema` unit scaling).
    static func distancePoint(
        id: String = "distance-0001",
        start: Date = date("2026-07-01T07:00:00Z"),
        end: Date = date("2026-07-01T07:20:00Z"),
        meters: Double = 15.0,
        deviceDisplayName: String? = "Fitbit Air"
    ) -> GoogleDataPoint {
        GoogleDataPoint(
            id: id,
            dataType: .distance,
            start: start,
            end: end,
            source: DataSource(
                platform: "IOS",
                deviceDisplayName: deviceDisplayName,
                recordingMethod: "AUTOMATICALLY_RECORDED"
            ),
            values: ["distance": meters]
        )
    }

    /// Mirrors `floors.json`'s `floors-0001` point (`6` flights,
    /// 2026-07-01T08:00:00Z-09:00:00Z, Fitbit Air).
    static func floorsPoint(
        id: String = "floors-0001",
        start: Date = date("2026-07-01T08:00:00Z"),
        end: Date = date("2026-07-01T09:00:00Z"),
        count: Double = 6,
        deviceDisplayName: String? = "Fitbit Air"
    ) -> GoogleDataPoint {
        GoogleDataPoint(
            id: id,
            dataType: .floors,
            start: start,
            end: end,
            source: DataSource(
                platform: "IOS",
                deviceDisplayName: deviceDisplayName,
                recordingMethod: "AUTOMATICALLY_RECORDED"
            ),
            values: ["count": count]
        )
    }

    /// Mirrors `active-energy-burned.json`'s `aeb-0001` point (`312.5` kcal,
    /// 2026-07-01T08:00:00Z-09:00:00Z, Fitbit Air).
    static func activeEnergyBurnedPoint(
        id: String = "aeb-0001",
        start: Date = date("2026-07-01T08:00:00Z"),
        end: Date = date("2026-07-01T09:00:00Z"),
        kcal: Double = 312.5,
        deviceDisplayName: String? = "Fitbit Air"
    ) -> GoogleDataPoint {
        GoogleDataPoint(
            id: id,
            dataType: .activeEnergyBurned,
            start: start,
            end: end,
            source: DataSource(
                platform: "IOS",
                deviceDisplayName: deviceDisplayName,
                recordingMethod: "AUTOMATICALLY_RECORDED"
            ),
            values: ["kcal": kcal]
        )
    }

    /// Mirrors `daily-resting-heart-rate.json`'s `drhr-0001` point (`52`
    /// bpm, a full-day 2026-07-01T00:00:00Z-2026-07-02T00:00:00Z interval
    /// per base-knowledge.md §3's "D" = Daily record type, Fitbit Air).
    static func restingHeartRatePoint(
        id: String = "drhr-0001",
        start: Date = date("2026-07-01T00:00:00Z"),
        end: Date = date("2026-07-02T00:00:00Z"),
        bpm: Double = 52,
        deviceDisplayName: String? = "Fitbit Air"
    ) -> GoogleDataPoint {
        GoogleDataPoint(
            id: id,
            dataType: .dailyRestingHeartRate,
            start: start,
            end: end,
            source: DataSource(
                platform: "IOS",
                deviceDisplayName: deviceDisplayName,
                recordingMethod: "AUTOMATICALLY_RECORDED"
            ),
            values: ["bpm": bpm]
        )
    }

    /// Mirrors `heart-rate-variability.json`'s point: the schema's out keys
    /// `rmssd_ms` and, when Google sends one, `sdnn_ms` (WP-62).
    static func heartRateVariabilityPoint(
        id: String = "hrv-0001",
        start: Date = date("2026-07-09T03:00:00Z"),
        end: Date = date("2026-07-09T03:00:00Z"),
        rmssd: Double? = 38.2,
        sdnn: Double? = nil,
        deviceDisplayName: String? = "Fitbit Air"
    ) -> GoogleDataPoint {
        var values: [String: Double] = [:]
        values["rmssd_ms"] = rmssd
        values["sdnn_ms"] = sdnn
        return GoogleDataPoint(
            id: id,
            dataType: .heartRateVariability,
            start: start,
            end: end,
            source: DataSource(
                platform: "IOS",
                deviceDisplayName: deviceDisplayName,
                recordingMethod: "AUTOMATICALLY_RECORDED"
            ),
            values: values
        )
    }

    /// Mirrors `oxygen-saturation.json`'s `spo2-0001` point (`97`% on the
    /// wire -> `0.97` fraction after `TypeMapper`'s conversion).
    static func oxygenSaturationPoint(
        id: String = "spo2-0001",
        start: Date = date("2026-07-09T02:00:00Z"),
        end: Date = date("2026-07-09T02:00:00Z"),
        percentage: Double = 97,
        deviceDisplayName: String? = "Fitbit Air"
    ) -> GoogleDataPoint {
        GoogleDataPoint(
            id: id,
            dataType: .oxygenSaturation,
            start: start,
            end: end,
            source: DataSource(
                platform: "IOS",
                deviceDisplayName: deviceDisplayName,
                recordingMethod: "AUTOMATICALLY_RECORDED"
            ),
            values: ["percentage": percentage]
        )
    }

    /// Mirrors `respiratory-rate.json`'s `rr-0001` point (`14.5`
    /// breaths/min, Fitbit Air).
    static func respiratoryRatePoint(
        id: String = "rr-0001",
        start: Date = date("2026-07-09T02:00:00Z"),
        end: Date = date("2026-07-09T02:00:00Z"),
        breathsPerMinute: Double = 14.5,
        deviceDisplayName: String? = "Fitbit Air"
    ) -> GoogleDataPoint {
        GoogleDataPoint(
            id: id,
            dataType: .respiratoryRateSleepSummary,
            start: start,
            end: end,
            source: DataSource(
                platform: "IOS",
                deviceDisplayName: deviceDisplayName,
                recordingMethod: "AUTOMATICALLY_RECORDED"
            ),
            values: ["breathsPerMinute": breathsPerMinute]
        )
    }

    /// Mirrors `vo2-max.json`'s `vo2-0001` point (`42.3` mL/(kg·min),
    /// Fitbit Air). `dataType` is overridable so the identical scenario can
    /// stand in for `run-vo2-max.json`'s `run-vo2-0001` point too (both
    /// Google types share one HealthKit target -- see `decideVO2Max`).
    static func vo2MaxPoint(
        id: String = "vo2-0001",
        dataType: GoogleDataType = .vo2Max,
        start: Date = date("2026-07-05T09:00:00Z"),
        end: Date = date("2026-07-05T09:00:00Z"),
        value: Double = 42.3,
        deviceDisplayName: String? = "Fitbit Air"
    ) -> GoogleDataPoint {
        GoogleDataPoint(
            id: id,
            dataType: dataType,
            start: start,
            end: end,
            source: DataSource(
                platform: "IOS",
                deviceDisplayName: deviceDisplayName,
                recordingMethod: "AUTOMATICALLY_RECORDED"
            ),
            values: ["value": value]
        )
    }

    /// Mirrors `height.json`'s `height-0001` point (`1.78` meters, manual
    /// entry, Fitbit Aria Air).
    static func heightPoint(
        id: String = "height-0001",
        start: Date = date("2026-07-01T06:45:00Z"),
        end: Date = date("2026-07-01T06:45:00Z"),
        meters: Double = 1.78,
        deviceDisplayName: String? = "Fitbit Aria Air"
    ) -> GoogleDataPoint {
        GoogleDataPoint(
            id: id,
            dataType: .height,
            start: start,
            end: end,
            source: DataSource(
                platform: "IOS",
                deviceDisplayName: deviceDisplayName,
                recordingMethod: "MANUAL_ENTRY"
            ),
            values: ["meters": meters]
        )
    }

    /// Mirrors `body-fat.json`'s `bf-0001` point (`22`% on the wire ->
    /// `0.22` fraction after `TypeMapper`'s conversion).
    static func bodyFatPoint(
        id: String = "bf-0001",
        start: Date = date("2026-07-01T06:45:00Z"),
        end: Date = date("2026-07-01T06:45:00Z"),
        percentage: Double = 22,
        deviceDisplayName: String? = "Fitbit Aria Air"
    ) -> GoogleDataPoint {
        GoogleDataPoint(
            id: id,
            dataType: .bodyFat,
            start: start,
            end: end,
            source: DataSource(
                platform: "IOS",
                deviceDisplayName: deviceDisplayName,
                recordingMethod: "MANUAL_ENTRY"
            ),
            values: ["percentage": percentage]
        )
    }

    /// Mirrors `blood-glucose-mgdl.json`'s `bg-mgdl-0001` point (`98`
    /// mg/dL, manual entry, Fitbit Air).
    static func bloodGlucoseMgDLPoint(
        id: String = "bg-mgdl-0001",
        start: Date = date("2026-07-01T12:00:00Z"),
        end: Date = date("2026-07-01T12:00:00Z"),
        mgPerDL: Double = 98,
        deviceDisplayName: String? = "Fitbit Air"
    ) -> GoogleDataPoint {
        GoogleDataPoint(
            id: id,
            dataType: .bloodGlucose,
            start: start,
            end: end,
            source: DataSource(
                platform: "IOS",
                deviceDisplayName: deviceDisplayName,
                recordingMethod: "MANUAL_ENTRY"
            ),
            values: ["mg_per_dl": mgPerDL]
        )
    }

    /// Mirrors `blood-glucose-mmol.json`'s `bg-mmol-0001` point (`5.4`
    /// mmol/L, manual entry, Fitbit Air).
    static func bloodGlucoseMmolLPoint(
        id: String = "bg-mmol-0001",
        start: Date = date("2026-07-01T12:00:00Z"),
        end: Date = date("2026-07-01T12:00:00Z"),
        mmolPerL: Double = 5.4,
        deviceDisplayName: String? = "Fitbit Air"
    ) -> GoogleDataPoint {
        GoogleDataPoint(
            id: id,
            dataType: .bloodGlucose,
            start: start,
            end: end,
            source: DataSource(
                platform: "IOS",
                deviceDisplayName: deviceDisplayName,
                recordingMethod: "MANUAL_ENTRY"
            ),
            values: ["mmol_per_l": mmolPerL]
        )
    }

    /// Mirrors `core-body-temperature.json`'s `cbt-0001` point (`37.1`°C,
    /// Fitbit Air).
    static func coreBodyTemperaturePoint(
        id: String = "cbt-0001",
        start: Date = date("2026-07-09T03:00:00Z"),
        end: Date = date("2026-07-09T03:00:00Z"),
        celsius: Double = 37.1,
        deviceDisplayName: String? = "Fitbit Air"
    ) -> GoogleDataPoint {
        GoogleDataPoint(
            id: id,
            dataType: .coreBodyTemperature,
            start: start,
            end: end,
            source: DataSource(
                platform: "IOS",
                deviceDisplayName: deviceDisplayName,
                recordingMethod: "AUTOMATICALLY_RECORDED"
            ),
            values: ["celsius": celsius]
        )
    }

    /// Mirrors `hydration-log.json`'s `hydration-0001` point (`0.5` liters,
    /// manual entry, Fitbit Air).
    static func hydrationPoint(
        id: String = "hydration-0001",
        start: Date = date("2026-07-01T12:30:00Z"),
        end: Date = date("2026-07-01T12:30:00Z"),
        liters: Double = 0.5,
        deviceDisplayName: String? = "Fitbit Air"
    ) -> GoogleDataPoint {
        GoogleDataPoint(
            id: id,
            dataType: .hydrationLog,
            start: start,
            end: end,
            source: DataSource(
                platform: "IOS",
                deviceDisplayName: deviceDisplayName,
                recordingMethod: "MANUAL_ENTRY"
            ),
            values: ["liters": liters]
        )
    }

    // MARK: - WP-13 addition (Nutrition Log -> HKCorrelation(.food))
    //
    // Unlike WP-12's Exercise fixture, these two nutrition scenarios *do*
    // have companion JSON fixtures under
    // `Packages/GoogleHealthClient/Tests/GoogleHealthClientTests/Fixtures/GoogleHealth/`
    // (`nutrition-log.json`/`nutrition-log-partial.json`) -- WP-13's stated
    // scope explicitly grants fixture-only access to that directory (unlike
    // WP-12's SyncKit-only scope), so this follows the WP-07/11 convention
    // of a companion JSON fixture with a `_comment`, not WP-12's documented
    // exception.

    /// Mirrors `nutrition-log.json`'s `nutrition-0001` point: a full-macro
    /// meal (650 kcal, 35g protein, 70g carbs, 22g fat), manual entry, Fitbit
    /// Air. Every parameter is independently optional so the same builder
    /// covers WP-13's required "meal missing macros" scenario too (pass
    /// `nil` for any macro to omit its wire field entirely, matching
    /// `nutrition-log-partial.json`'s shape -- a missing field, not a
    /// present-but-zero one).
    static func nutritionLogPoint(
        id: String = "nutrition-0001",
        start: Date = date("2026-07-01T12:15:00Z"),
        end: Date = date("2026-07-01T12:15:00Z"),
        energyKcal: Double? = 650,
        proteinGrams: Double? = 35,
        carbsGrams: Double? = 70,
        fatGrams: Double? = 22,
        deviceDisplayName: String? = "Fitbit Air"
    ) -> GoogleDataPoint {
        var values: [String: Double] = [:]
        if let energyKcal { values["energy_kcal"] = energyKcal }
        if let proteinGrams { values["protein_g"] = proteinGrams }
        if let carbsGrams { values["carbs_g"] = carbsGrams }
        if let fatGrams { values["fat_g"] = fatGrams }
        return GoogleDataPoint(
            id: id,
            dataType: .nutritionLog,
            start: start,
            end: end,
            source: DataSource(
                platform: "IOS",
                deviceDisplayName: deviceDisplayName,
                recordingMethod: "MANUAL_ENTRY"
            ),
            values: values
        )
    }

    // MARK: - WP-12 addition (Exercise -> HKWorkout)
    //
    // Unlike every WP-11 fixture above, there is **no** companion JSON
    // fixture under
    // `Packages/GoogleHealthClient/Tests/GoogleHealthClientTests/Fixtures/GoogleHealth/`
    // for Exercise: WP-12's stated scope is `Packages/SyncKit` only ("do NOT
    // touch ... GoogleHealthClient"), unlike WP-07/11 which were free to add
    // fixtures to that package's test target. The wire-shape assumptions
    // that would normally live in such a fixture's `_comment` key are
    // documented instead in `ExerciseSessionDecoding.swift`'s header and
    // flagged again in progress.md's WP-12 entry as a deliberate,
    // scope-driven deviation from the WP-07/11 fixture convention.

    /// Builds a synthetic Exercise `GoogleDataPoint` whose `sessionPayload`
    /// is the API's typed `exercise` object (WP-51, published v4 shape):
    /// `exerciseType` plus `metricsSummary.distanceMillimeters` /
    /// `.caloriesKcal`. `values` is always empty -- exactly like
    /// `sleepPoint()` above, every field this session reports lives in
    /// `sessionPayload`, not `GoogleDataPoint.values` (see that decoding
    /// file's header for why).
    static func exercisePoint(
        id: String = "exercise-0001",
        start: Date = date("2026-07-01T17:00:00Z"),
        end: Date = date("2026-07-01T17:45:00Z"),
        wireActivityType: String = "RUNNING",
        distanceMeters: Double? = 8000.0,
        energyKilocalories: Double? = 520.0,
        deviceDisplayName: String? = "Fitbit Air"
    ) -> GoogleDataPoint {
        var metrics: [String: Any] = [:]
        if let distanceMeters { metrics["distanceMillimeters"] = distanceMeters * 1000 }
        if let energyKilocalories { metrics["caloriesKcal"] = energyKilocalories }
        let payloadObject: [String: Any] = ["exerciseType": wireActivityType, "metricsSummary": metrics]
        guard
            let payload = try? JSONSerialization.data(withJSONObject: payloadObject, options: [.sortedKeys])
        else {
            preconditionFailure("Fixture exercise payload failed to serialize")
        }
        return GoogleDataPoint(
            id: id,
            dataType: .exercise,
            start: start,
            end: end,
            source: DataSource(
                platform: "IOS",
                deviceDisplayName: deviceDisplayName,
                recordingMethod: "AUTOMATICALLY_RECORDED"
            ),
            values: [:],
            sessionPayload: payload
        )
    }

    struct SleepSegmentFixture {
        let start: String
        let end: String
        let stage: String

        init(_ start: String, _ end: String, _ stage: String) {
            self.start = start
            self.end = end
            self.stage = stage
        }
    }

    /// Mirrors `sleep.json`'s `sleep-0001` point: a 2026-07-08T23:15:00Z –
    /// 2026-07-09T06:45:00Z session with five contiguous stage segments
    /// (awake, light, deep, rem, light), Fitbit Air.
    static func sleepPoint(
        id: String = "sleep-0001",
        start: Date = date("2026-07-08T23:15:00Z"),
        end: Date = date("2026-07-09T06:45:00Z"),
        segments: [SleepSegmentFixture] = [
            .init("2026-07-08T23:15:00Z", "2026-07-08T23:40:00Z", "AWAKE"),
            .init("2026-07-08T23:40:00Z", "2026-07-09T01:10:00Z", "LIGHT"),
            .init("2026-07-09T01:10:00Z", "2026-07-09T02:00:00Z", "DEEP"),
            .init("2026-07-09T02:00:00Z", "2026-07-09T03:30:00Z", "REM"),
            .init("2026-07-09T03:30:00Z", "2026-07-09T06:45:00Z", "LIGHT"),
        ],
        deviceDisplayName: String? = "Fitbit Air"
    ) -> GoogleDataPoint {
        let payloadSegments: [[String: Any]] = segments.map {
            ["startTime": $0.start, "endTime": $0.end, "type": $0.stage]
        }
        let payloadObject: [String: Any] = ["stages": payloadSegments]
        guard
            let payload = try? JSONSerialization.data(withJSONObject: payloadObject, options: [.sortedKeys])
        else {
            preconditionFailure("Fixture sleep segments failed to serialize")
        }
        return GoogleDataPoint(
            id: id,
            dataType: .sleep,
            start: start,
            end: end,
            source: DataSource(
                platform: "IOS",
                deviceDisplayName: deviceDisplayName,
                recordingMethod: "AUTOMATICALLY_RECORDED"
            ),
            values: [:],
            sessionPayload: payload
        )
    }
}

extension MappedDecision {
    var isQuantity: Bool {
        if case .quantity = self { return true }
        return false
    }

    var isCategory: Bool {
        if case .category = self { return true }
        return false
    }

    /// WP-13.
    var isCorrelation: Bool {
        if case .correlation = self { return true }
        return false
    }
}
