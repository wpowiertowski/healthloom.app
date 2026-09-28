// TypeMapper.swift
//
// WP-07 (implementation-plan.md): "Pure, table-driven GoogleDataPoint ->
// MappedObject. Correctness lives here." This file holds the actual mapping
// *decision* logic (`TypeMapper.decide(_:) -> MappedDecision`, fully
// HealthKit-free -- see MappedTypes.swift's header for why that split
// exists); `MappedObject.swift`'s `TypeMapper.map(_:)` is a thin extension
// that turns a `MappedDecision` into the real
// `HKQuantitySample`/`HKCategorySample` objects WP-07's required public
// signature (`enum TypeMapper { static func map(_ p: GoogleDataPoint) ->
// MappedObject }`) asks for.
//
// Routing (WP-07 step 5): dispatch off CoreModel's `GoogleDataType.writability`
// table -- the single source of truth (CoreModel's `GoogleDataType.swift` doc
// comment) -- never a hand-duplicated list of "ECG/AZM/IRN". `.localOnly`
// writability -> `.localOnly`; `.skip` writability -> `.skip`; `.healthKit`
// writability for one of this WP's four implemented P0 types
// (steps/heartRate/weight/sleep) -> the real mapping. Any *other*
// `.healthKit` row (distance, bodyFat, exercise, food, ...) is WP-11/12/13's
// job and isn't implemented here yet, so it also currently falls to `.skip`
// -- flagged in progress.md's WP-07 entry as a scope note for WP-11's
// implementer: broadening `decideHealthKitMapped`'s switch (not rewriting the
// routing) is the extension point.
//
// Concurrency note (progress.md's WP-04/05 MainActor-isolation gotcha, hit
// again here): CoreModel's `GoogleDataType.writability` is a *computed*
// property declared in a module that opts into `.defaultIsolation
// (MainActor.self)` (architecture.md §3), so it is itself MainActor-isolated
// -- unlike `GoogleDataPoint`/`DataSource`'s plain *stored* properties, which
// are freely accessible from anywhere because WP-05 marked those two structs
// `nonisolated` outright. SyncKit's own Package.swift sets the same default
// isolation, so `TypeMapper.decide`/`.map` are left at their implicit
// MainActor isolation (no `nonisolated` annotation) rather than fighting it
// -- exactly the precedent WP-06's `HealthKitAuth.resolveSampleType` already
// established for reading this same table synchronously (see
// HealthKitAuth.swift). This package's own test target shares the same
// default isolation, so tests call `TypeMapper.decide`/`.map` directly with
// no `await`; a future *actor*-isolated caller (e.g. WP-09's `actor
// SyncEngine`) can still call either function with a plain `await` even
// though neither is declared `async` -- standard cross-actor call syntax for
// a synchronous isolated function, so this isn't a blocker downstream.

import CoreModel
import GoogleHealthClient
import Foundation

public enum TypeMapper {
    /// Heart rate readings outside this range are treated as sensor/API
    /// glitches and dropped (WP-07 "Tests:" line: "out-of-range values ...
    /// HR 0 / 400 -- decide and pin behavior (drop + count)"). Pinned
    /// decision: **drop** (route to `.skip`); **count** is deferred to WP-09's
    /// `SyncEngine`, which has the per-type counters (`SyncState.itemCount`)
    /// this pure mapper deliberately doesn't -- `TypeMapper` has no side
    /// channel, so "counting" a dropped point is the caller's job once it
    /// sees `.skip` for a point it expected to map (see progress.md's WP-07
    /// entry for the full reasoning). 300 bpm is a generous upper bound --
    /// comfortably above any physiologically plausible reading -- chosen so
    /// this filter only catches obvious sensor errors like the spec's own
    /// "400" example, not aggressive real-world exercise data; 0 bpm (and any
    /// non-positive value) is never valid for a living wearer.
    static let heartRateValidRange = 1.0...300.0

    /// WP-11: shared bound for fields the Google payload is assumed to
    /// report as a `0...100` percentage (SpO2, body fat) before this mapper
    /// converts them to HealthKit's required `0...1` fraction
    /// (`MappedUnit.fraction`, base-knowledge.md §5 "SpO2/body-fat fraction
    /// 0-1 in HK!"). Neither base-knowledge.md §2/§3 nor §5 documents the
    /// Google wire payload's own unit for either field -- this assumes a
    /// consumer-facing percentage (every SpO2/body-fat reading either
    /// platform surfaces to a user is shown as e.g. "97%", never "0.97"),
    /// flagged as an assumption to reconcile once real API access exists
    /// (same posture as WP-07's weight-unit note). Guarding the *input* to
    /// this range structurally guarantees the *converted* fraction lands in
    /// `0...1` -- the property WP-11 requires a dedicated property test for
    /// (`TypeMapperPropertyTests.fractionOutputsAlwaysStayInUnitInterval`).
    static let percentageValidRange = 0.0...100.0

    /// WP-11: generous sensor-glitch filter for respiratory rate, same
    /// philosophy as `heartRateValidRange` (a bound comfortably above/below
    /// any physiologically plausible reading, not a clinical range).
    static let respiratoryRateValidRange = 1.0...60.0

    /// WP-11: generous sensor-glitch filter for core body temperature in
    /// Celsius (human core temperature is ~36-40°C; this bound is
    /// deliberately wide so it only catches obvious unit/sensor errors, not
    /// real fever/hypothermia readings).
    static let coreBodyTemperatureValidRange = 20.0...45.0

    /// WP-11: generous plausible-height filter in meters (catches an
    /// obvious unit mismatch -- e.g. a value that's actually centimeters --
    /// without rejecting any real adult or child height).
    static let heightValidRange = 0.3...2.75

    /// Map one Google data point to its `MappedDecision` (WP-07 step 1's
    /// "correctness lives here" pure entry point). See `MappedObject.swift`
    /// for `.map(_:) -> MappedObject`, the HealthKit-wrapping counterpart
    /// built on top of this.
    public static func decide(_ point: GoogleDataPoint) -> MappedDecision {
        switch point.dataType.writability {
        case .localOnly:
            return .localOnly
        case .skip:
            return .skip
        case .healthKit:
            return decideHealthKitMapped(point)
        }
    }

    private static func decideHealthKitMapped(_ point: GoogleDataPoint) -> MappedDecision {
        switch point.dataType {
        case .steps:
            return decideSteps(point)
        case .heartRate:
            return decideHeartRate(point)
        case .weight:
            return decideWeight(point)
        case .sleep:
            return decideSleep(point)
        // MARK: - WP-11 additions (full TypeMapper table)
        case .distance:
            return decideDistance(point)
        case .floors:
            return decideFloors(point)
        case .activeEnergyBurned:
            return decideActiveEnergyBurned(point)
        case .dailyRestingHeartRate:
            return decideRestingHeartRate(point)
        case .heartRateVariability:
            return decideHeartRateVariability(point)
        case .oxygenSaturation:
            return decideOxygenSaturation(point)
        case .respiratoryRateSleepSummary:
            return decideRespiratoryRate(point)
        case .vo2Max, .runVO2Max:
            return decideVO2Max(point)
        case .height:
            return decideHeight(point)
        case .bodyFat:
            return decideBodyFat(point)
        case .bloodGlucose:
            return decideBloodGlucose(point)
        case .coreBodyTemperature:
            return decideCoreBodyTemperature(point)
        case .hydrationLog:
            return decideHydration(point)
        // MARK: - WP-12 addition
        case .exercise:
            return decideExercise(point)
        // MARK: - WP-13 addition
        case .nutritionLog:
            return decideNutritionLog(point)
        default:
            // `.totalCalories` deliberately falls through to here (WP-11:
            // "Google gives a single total ... do NOT invent a basal split
            // unless the payload actually separates it"). CoreModel's
            // writability table declares
            // "HKQuantityTypeIdentifierBasalEnergyBurned" as an *available*
            // target for `.totalCalories` (see GoogleDataType.swift's own
            // doc comment and progress.md's WP-02 note), but that table only
            // records what HealthKit *could* accept, not a decision to
            // write it -- writing Google's undifferentiated total into
            // `basalEnergyBurned` would fabricate data Google never actually
            // reported (a real basal-only reading), which is worse than not
            // writing it. No fixture/payload evidence available in this
            // session separates active from basal, so `.totalCalories` is
            // left unhandled here and falls to `.skip`.
            //
            // `.food` deliberately falls through here too (WP-13): CoreModel's
            // writability table pairs both `.food` and `.nutritionLog` with
            // the same `HKCorrelationTypeIdentifierFood` sentinel (see that
            // file's own doc comment), but base-knowledge.md §3's data-type
            // table only marks **Nutrition Log** ✅-writable -- plain "Food"
            // has no ✅ in that column (`list, get` only, no `reconcile`/
            // write ops). Writing a generic "Food" catalog/reference entry
            // into a per-meal `HKCorrelation` would conflate a food
            // *definition* with a food *log entry*, which base-knowledge.md
            // never asks for -- so only `.nutritionLog` gets an explicit
            // case above; `.food` falls to `.skip` here, same reasoning
            // posture as `.totalCalories`. (Exercise -> HKWorkout is WP-12's
            // own job -- see the explicit `case .exercise` above; it no
            // longer falls through to here.)
            return .skip
        }
    }

    // MARK: - Steps (stepCount / count)

    private static func decideSteps(_ point: GoogleDataPoint) -> MappedDecision {
        guard let count = point.values["count"] else { return .skip }
        guard point.end >= point.start else { return .skip }
        // Out-of-range decision (WP-07 "Tests:" line, "negative steps"):
        // pinned to **drop** -- a negative step count cannot exist, so write
        // nothing rather than garbage into Apple Health.
        guard count >= 0 else { return .skip }
        return .quantity(
            MappedQuantitySample(
                healthKitIdentifier: "HKQuantityTypeIdentifierStepCount",
                unit: .count,
                value: count,
                start: point.start,
                end: point.end,
                metadata: metadata(for: point)
            )
        )
    }

    // MARK: - Heart rate (heartRate / count/min)

    private static func decideHeartRate(_ point: GoogleDataPoint) -> MappedDecision {
        guard let bpm = point.values["bpm"] else { return .skip }
        guard point.end >= point.start else { return .skip }
        guard heartRateValidRange.contains(bpm) else { return .skip }
        return .quantity(
            MappedQuantitySample(
                healthKitIdentifier: "HKQuantityTypeIdentifierHeartRate",
                unit: .countPerMinute,
                value: bpm,
                start: point.start,
                end: point.end,
                metadata: metadata(for: point)
            )
        )
    }

    // MARK: - Weight (bodyMass / kg)

    private static func decideWeight(_ point: GoogleDataPoint) -> MappedDecision {
        guard let mass = point.values["mass"] else { return .skip }
        guard point.end >= point.start else { return .skip }
        // Unit pin (WP-07 step 2, settled in WP-51): the published v4
        // reference sends `weight.weightGrams`; GoogleHealthClient's
        // `GoogleDataTypeSchema` scales it to kilograms, so `mass` arrives
        // here already in kg and maps straight through.
        guard mass > 0 else { return .skip }
        return .quantity(
            MappedQuantitySample(
                healthKitIdentifier: "HKQuantityTypeIdentifierBodyMass",
                unit: .kilogram,
                value: mass,
                start: point.start,
                end: point.end,
                metadata: metadata(for: point)
            )
        )
    }

    // MARK: - Distance (distanceWalkingRunning / meters) -- WP-11

    /// Wire field `distance.distance`, already normalized mm->m by
    /// GoogleHealthClient's `GoogleDataTypeSchema` unit scaling (WP-05) before this struct is
    /// constructed -- `point.values["distance"]` arrives in meters already,
    /// no further scaling needed (base-knowledge.md §5: "Distance ...
    /// Convert mm -> m").
    private static func decideDistance(_ point: GoogleDataPoint) -> MappedDecision {
        guard let meters = point.values["distance"] else { return .skip }
        guard point.end >= point.start else { return .skip }
        guard meters >= 0 else { return .skip }
        return .quantity(
            MappedQuantitySample(
                healthKitIdentifier: "HKQuantityTypeIdentifierDistanceWalkingRunning",
                unit: .meter,
                value: meters,
                start: point.start,
                end: point.end,
                metadata: metadata(for: point)
            )
        )
    }

    // MARK: - Floors (flightsClimbed / count) -- WP-11

    /// Wire field `floors.count` (field name assumed -- base-knowledge.md
    /// doesn't document Google's exact field name for this type; "count" is
    /// consistent with how the other Interval types in this file name their
    /// scalar field, e.g. steps' `steps.count`).
    private static func decideFloors(_ point: GoogleDataPoint) -> MappedDecision {
        guard let count = point.values["count"] else { return .skip }
        guard point.end >= point.start else { return .skip }
        guard count >= 0 else { return .skip }
        return .quantity(
            MappedQuantitySample(
                healthKitIdentifier: "HKQuantityTypeIdentifierFlightsClimbed",
                unit: .count,
                value: count,
                start: point.start,
                end: point.end,
                metadata: metadata(for: point)
            )
        )
    }

    // MARK: - Active Energy Burned (activeEnergyBurned / kcal) -- WP-11

    /// Wire field `active_energy_burned.kcal` (field name assumed; kcal is
    /// the unit HealthKit itself uses for this identifier --
    /// `HKUnit.kilocalorie()` -- and the base-knowledge.md §5 row is
    /// explicit that Google gives "a single total," so this maps only
    /// `.activeEnergyBurned` -> `HKQuantityTypeIdentifierActiveEnergyBurned`.
    /// `.totalCalories` is deliberately **not** handled here -- see
    /// `decideHealthKitMapped`'s `default` case doc comment for why writing
    /// it to `basalEnergyBurned` would invent a split Google never reported.
    private static func decideActiveEnergyBurned(_ point: GoogleDataPoint) -> MappedDecision {
        guard let kcal = point.values["kcal"] else { return .skip }
        guard point.end >= point.start else { return .skip }
        guard kcal >= 0 else { return .skip }
        return .quantity(
            MappedQuantitySample(
                healthKitIdentifier: "HKQuantityTypeIdentifierActiveEnergyBurned",
                unit: .kilocalorie,
                value: kcal,
                start: point.start,
                end: point.end,
                metadata: metadata(for: point)
            )
        )
    }

    // MARK: - Resting Heart Rate (restingHeartRate / count/min) -- WP-11

    /// Wire field `daily_resting_heart_rate.bpm`. Reuses
    /// `heartRateValidRange` (same physiological quantity, same generous
    /// sensor-glitch filter) rather than defining a separate, tighter
    /// "resting" range -- base-knowledge.md gives no clinical bound to pin a
    /// tighter one against, and a resting reading outside 1...300 bpm is
    /// exactly as implausible as an ordinary one outside that range.
    private static func decideRestingHeartRate(_ point: GoogleDataPoint) -> MappedDecision {
        guard let bpm = point.values["bpm"] else { return .skip }
        guard point.end >= point.start else { return .skip }
        guard heartRateValidRange.contains(bpm) else { return .skip }
        return .quantity(
            MappedQuantitySample(
                healthKitIdentifier: "HKQuantityTypeIdentifierRestingHeartRate",
                unit: .countPerMinute,
                value: bpm,
                start: point.start,
                end: point.end,
                metadata: metadata(for: point)
            )
        )
    }

    // MARK: - Heart Rate Variability -- WP-62, written to Apple Health

    /// Apple Health's one HRV type (`heartRateVariabilitySDNN`), in ms,
    /// tagged with the statistic it holds. WP-11 kept HRV in-app because
    /// Google's statistic was undocumented and Fitbit's is RMSSD, not the
    /// SDNN that type is named for. The real v4 format (WP-51) carries
    /// `rmssd_ms` and, optionally, `sdnn_ms`; the owner chose (WP-62) to
    /// write RMSSD under the SDNN type rather than keep it out of Apple
    /// Health, as other wearables do. A true SDNN wins when Google sends
    /// one. Either way `hrvStatistic` records which it is, so the sample
    /// never claims to be something it isn't.
    private static func decideHeartRateVariability(_ point: GoogleDataPoint) -> MappedDecision {
        // The first *plausible* value wins, SDNN first (WP-64): a present
        // but zero SDNN -- an optional field Google may fill with 0 for
        // Fitbit -- must fall through to the RMSSD beside it, not skip the
        // point.
        let candidates: [(milliseconds: Double?, statistic: HRVStatistic)] = [
            (point.values["sdnn_ms"], .sdnn),
            (point.values["rmssd_ms"], .rmssd),
        ]
        guard let chosen = candidates.first(where: { $0.milliseconds.map(hrvValidRange.contains) ?? false }),
              let milliseconds = chosen.milliseconds
        else { return .skip }
        let reading = (milliseconds: milliseconds, statistic: chosen.statistic)
        guard point.end >= point.start else { return .skip }
        var metadata = metadata(for: point)
        metadata.hrvStatistic = reading.statistic
        return .quantity(
            MappedQuantitySample(
                healthKitIdentifier: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
                unit: .millisecond,
                value: reading.milliseconds,
                start: point.start,
                end: point.end,
                metadata: metadata
            )
        )
    }

    /// Plausible HRV in ms, either statistic: resting adult RMSSD/SDNN runs
    /// roughly 10-150 ms; the bounds only reject a zero, a negative or a
    /// unit error (seconds or microseconds). A candidate outside them is
    /// passed over for the next one.
    static let hrvValidRange: ClosedRange<Double> = 1...500

    // MARK: - Oxygen Saturation / SpO2 (oxygenSaturation / fraction) -- WP-11

    /// Wire field `oxygen_saturation.percentage`. base-knowledge.md doesn't
    /// pin down whether Google's payload is already a `0...1` fraction or a
    /// `0...100` percentage; every consumer-facing SpO2 reading either
    /// platform shows a user is a percentage (e.g. "97%"), so this assumes
    /// the wire value is `0...100` and converts -- **never** passes it
    /// through unconverted (HealthKit requires `0...1`, base-knowledge.md
    /// §5's "fraction 0-1 in HK!"). Guarding the raw input to
    /// `percentageValidRange` structurally guarantees the emitted fraction
    /// lands in `0...1`.
    private static func decideOxygenSaturation(_ point: GoogleDataPoint) -> MappedDecision {
        guard let percentage = point.values["percentage"] else { return .skip }
        guard point.end >= point.start else { return .skip }
        guard percentageValidRange.contains(percentage) else { return .skip }
        return .quantity(
            MappedQuantitySample(
                healthKitIdentifier: "HKQuantityTypeIdentifierOxygenSaturation",
                unit: .fraction,
                value: percentage / 100.0,
                start: point.start,
                end: point.end,
                metadata: metadata(for: point)
            )
        )
    }

    // MARK: - Respiratory Rate (respiratoryRate / count/min) -- WP-11

    /// Wire field `respiratory_rate_sleep_summary.breathsPerMinute` (field
    /// name assumed). HealthKit has no dedicated "breaths" unit -- like
    /// heart rate, `respiratoryRate` samples use `count/min`
    /// (`MappedUnit.countPerMinute`).
    private static func decideRespiratoryRate(_ point: GoogleDataPoint) -> MappedDecision {
        guard let breathsPerMinute = point.values["breathsPerMinute"] else { return .skip }
        guard point.end >= point.start else { return .skip }
        guard respiratoryRateValidRange.contains(breathsPerMinute) else { return .skip }
        return .quantity(
            MappedQuantitySample(
                healthKitIdentifier: "HKQuantityTypeIdentifierRespiratoryRate",
                unit: .countPerMinute,
                value: breathsPerMinute,
                start: point.start,
                end: point.end,
                metadata: metadata(for: point)
            )
        )
    }

    // MARK: - VO2 Max / Run VO2 Max (vo2Max / mL·(kg·min)⁻¹) -- WP-11

    /// Both `.vo2Max` and `.runVO2Max` (base-knowledge.md §3's two separate
    /// Google types) write to the same HealthKit identifier,
    /// `HKQuantityTypeIdentifierVO2Max` (§5), sharing this one function.
    /// Wire field `<dataType>.value` (field name assumed).
    private static func decideVO2Max(_ point: GoogleDataPoint) -> MappedDecision {
        guard let value = point.values["value"] else { return .skip }
        guard point.end >= point.start else { return .skip }
        guard value > 0 else { return .skip }
        return .quantity(
            MappedQuantitySample(
                healthKitIdentifier: "HKQuantityTypeIdentifierVO2Max",
                unit: .vo2MaxUnit,
                value: value,
                start: point.start,
                end: point.end,
                metadata: metadata(for: point)
            )
        )
    }

    // MARK: - Height (height / meters) -- WP-11

    /// Wire field `height.meters` (field name assumed; meters chosen to
    /// match HealthKit's own base unit for this identifier, avoiding an
    /// unconfirmed cm/in conversion).
    private static func decideHeight(_ point: GoogleDataPoint) -> MappedDecision {
        guard let meters = point.values["meters"] else { return .skip }
        guard point.end >= point.start else { return .skip }
        guard heightValidRange.contains(meters) else { return .skip }
        return .quantity(
            MappedQuantitySample(
                healthKitIdentifier: "HKQuantityTypeIdentifierHeight",
                unit: .meter,
                value: meters,
                start: point.start,
                end: point.end,
                metadata: metadata(for: point)
            )
        )
    }

    // MARK: - Body Fat (bodyFatPercentage / fraction) -- WP-11

    /// Wire field `body_fat.percentage`. Same `0...100 -> 0...1` conversion
    /// rationale as `decideOxygenSaturation` above (base-knowledge.md §5:
    /// "Body Fat ... fraction in HK").
    private static func decideBodyFat(_ point: GoogleDataPoint) -> MappedDecision {
        guard let percentage = point.values["percentage"] else { return .skip }
        guard point.end >= point.start else { return .skip }
        guard percentageValidRange.contains(percentage) else { return .skip }
        return .quantity(
            MappedQuantitySample(
                healthKitIdentifier: "HKQuantityTypeIdentifierBodyFatPercentage",
                unit: .fraction,
                value: percentage / 100.0,
                start: point.start,
                end: point.end,
                metadata: metadata(for: point)
            )
        )
    }

    // MARK: - Blood Glucose (bloodGlucose / mg/dL or mmol/L) -- WP-11

    /// WP-11: "unit from payload - mg/dL vs mmol/L, both fixture variants."
    /// base-knowledge.md documents neither Google's wire field name(s) for
    /// this type nor which of the two clinically-standard units it reports.
    /// Assumed here (undocumented, flagged): the unit is signalled by
    /// *which* field is present on the wire (`blood_glucose.mg_per_dl` vs.
    /// `blood_glucose.mmol_per_l`), not a single numeric field alongside a
    /// separate unit string -- so both device/locale variants can be
    /// handled without ever converting between them (mg/dL and mmol/L are
    /// passed straight through in their own unit; this mapper never
    /// performs a mg/dL<->mmol/L conversion itself). If a future real
    /// payload turns out to use a single field name for both units guarded
    /// by a separate unit indicator instead, this function is the one place
    /// to update.
    private static func decideBloodGlucose(_ point: GoogleDataPoint) -> MappedDecision {
        guard point.end >= point.start else { return .skip }
        if let mgPerDL = point.values["mg_per_dl"] {
            guard mgPerDL > 0 else { return .skip }
            return .quantity(
                MappedQuantitySample(
                    healthKitIdentifier: "HKQuantityTypeIdentifierBloodGlucose",
                    unit: .milligramsPerDeciliter,
                    value: mgPerDL,
                    start: point.start,
                    end: point.end,
                    metadata: metadata(for: point)
                )
            )
        }
        if let mmolPerL = point.values["mmol_per_l"] {
            guard mmolPerL > 0 else { return .skip }
            return .quantity(
                MappedQuantitySample(
                    healthKitIdentifier: "HKQuantityTypeIdentifierBloodGlucose",
                    unit: .millimolesPerLiter,
                    value: mmolPerL,
                    start: point.start,
                    end: point.end,
                    metadata: metadata(for: point)
                )
            )
        }
        return .skip
    }

    // MARK: - Core Body Temperature (bodyTemperature / degreeCelsius) -- WP-11

    /// Wire field `core_body_temperature.celsius` (field name assumed;
    /// Celsius chosen to match HealthKit's own `degreeCelsius` unit,
    /// avoiding an unconfirmed Fahrenheit conversion).
    private static func decideCoreBodyTemperature(_ point: GoogleDataPoint) -> MappedDecision {
        guard let celsius = point.values["celsius"] else { return .skip }
        guard point.end >= point.start else { return .skip }
        guard coreBodyTemperatureValidRange.contains(celsius) else { return .skip }
        return .quantity(
            MappedQuantitySample(
                healthKitIdentifier: "HKQuantityTypeIdentifierBodyTemperature",
                unit: .degreeCelsius,
                value: celsius,
                start: point.start,
                end: point.end,
                metadata: metadata(for: point)
            )
        )
    }

    // MARK: - Hydration (dietaryWater / liters) -- WP-11

    /// Wire field `hydration_log.liters` (field name assumed; liters chosen
    /// to match HealthKit's own `dietaryWater` base unit). base-knowledge.md
    /// §3 records Hydration Log as a Session (Se) record type, but WP-11
    /// only asks for a `dietaryWater` quantity mapping (not a session/
    /// correlation structure like Exercise or Food), so this is treated
    /// like the other Sample-shaped scalar fields in this file (weight,
    /// height, ...) rather than decoded via `SleepSessionDecoding`-style
    /// nested payload parsing.
    private static func decideHydration(_ point: GoogleDataPoint) -> MappedDecision {
        guard let liters = point.values["liters"] else { return .skip }
        guard point.end >= point.start else { return .skip }
        guard liters >= 0 else { return .skip }
        return .quantity(
            MappedQuantitySample(
                healthKitIdentifier: "HKQuantityTypeIdentifierDietaryWater",
                unit: .liter,
                value: liters,
                start: point.start,
                end: point.end,
                metadata: metadata(for: point)
            )
        )
    }

    // MARK: - Exercise (HKWorkout via HKWorkoutBuilder) -- WP-12

    /// WP-12 step 2, reconciled in WP-51 against the published v4
    /// `Exercise.ExerciseType` enum (180+ values): each maps to the nearest
    /// of the app's workout buckets (MappedTypes.swift); every value not
    /// listed -- ball sports, dance, chores, `OTHER`, and anything Google adds
    /// later -- maps to `.other`, per WP-12's default bucket. The pre-WP-51
    /// keys (`run`, `bike`, ...) were an invented set that no real response
    /// uses.
    static let googleExerciseActivityTypes: [String: MappedWorkoutActivityType] = {
        let buckets: [MappedWorkoutActivityType: [String]] = [
            .running: ["RUNNING", "TRAIL_RUN", "TREADMILL", "INCLINE_RUN"],
            .walking: [
                "WALKING", "POWER_WALKING", "TREADMILL_WALK", "INCLINE_WALK",
                "NORDIC_WALKING", "STROLLER_WALK", "WALK_WITH_WEIGHTS",
            ],
            .cycling: [
                "BIKING", "OUTDOOR_BIKE", "MOUNTAIN_BIKE", "STATIONARY_BIKE",
                "SPINNING", "ELECTRIC_BIKE", "ASSAULT_BIKE", "HAND_CYCLING",
            ],
            .swimming: ["SWIMMING", "SWIMMING_POOL", "SWIMMING_OPEN_WATER"],
            .hiking: ["HIKING", "BACKPACKING", "RUCKING"],
            .traditionalStrengthTraining: [
                "WEIGHTS", "WEIGHTLIFTING", "FREE_WEIGHTS", "WEIGHT_MACHINES",
                "STRENGTH_TRAINING", "POWERLIFTING", "FUNCTIONAL_STRENGTH_TRAINING",
            ],
            .yoga: ["YOGA", "YOGA_BIKRAM", "YOGA_HATHA", "YOGA_POWER", "YOGA_VINYASA"],
            .elliptical: ["ELLIPTICAL"],
            .rowing: ["ROWING", "ROWING_MACHINE"],
            .highIntensityIntervalTraining: ["HIIT", "TABATA_WORKOUT", "INTERVAL_WORKOUT"],
            .stairClimbing: ["STAIRCLIMBER"],
            .coreTraining: ["CORE_TRAINING"],
        ]
        var table: [String: MappedWorkoutActivityType] = [:]
        for (bucket, values) in buckets {
            for value in values { table[value] = bucket }
        }
        return table
    }()

    /// The workout bucket for a Google `Exercise.ExerciseType` value -- the
    /// one place that enum is classified. The app's Activities view derives
    /// its activity families from this too, so a new mapping lands once.
    public static func workoutActivityType(forGoogleExerciseType type: String?) -> MappedWorkoutActivityType {
        type.flatMap { googleExerciseActivityTypes[$0] } ?? .other
    }

    /// Decodes the session payload (`ExerciseSessionDecoding.swift`) and
    /// maps Google's coarse activity-type string to a
    /// `MappedWorkoutActivityType` bucket via `googleExerciseActivityTypes`
    /// above, defaulting to `.other` for anything unrecognized (WP-12's
    /// explicit instruction). Distance/energy are carried through as
    /// optional fields -- present only when Google's payload reported them
    /// and the reported value is non-negative (a negative reading is
    /// implausible sensor/API garbage; dropped -- i.e. nil'd -- rather than
    /// kept, same "drop obviously-bad data" philosophy as every other
    /// WP-07/11 numeric guard, but scoped to just that one optional field
    /// rather than discarding the entire session: unlike out-of-range heart
    /// rate, a bad auxiliary attachment doesn't mean the workout itself
    /// didn't happen). A missing/malformed payload, or one missing the
    /// activity-type field entirely, never crashes -- it drops the whole
    /// session (`.skip`), same "never crash" rule WP-07 established for
    /// Sleep.
    private static func decideExercise(_ point: GoogleDataPoint) -> MappedDecision {
        guard point.end >= point.start else { return .skip }
        guard
            let payload = point.sessionPayload,
            let wire = ExerciseSessionDecoding.decode(payload)
        else { return .skip }

        let activityType = workoutActivityType(forGoogleExerciseType: wire.activityType)
        let distanceMeters = wire.distanceMeters.flatMap { $0 >= 0 ? $0 : nil }
        let energyKilocalories = wire.energyKilocalories.flatMap { $0 >= 0 ? $0 : nil }

        return .workout(
            MappedWorkout(
                activityType: activityType,
                start: point.start,
                end: point.end,
                distanceMeters: distanceMeters,
                energyKilocalories: energyKilocalories,
                metadata: metadata(for: point)
            )
        )
    }

    // MARK: - Nutrition Log (HKCorrelation(.food) per meal) -- WP-13

    /// Wire fields (assumed -- base-knowledge.md documents neither Google's
    /// exact field names for Nutrition Log nor its wire shape beyond the
    /// `<data_type>.<field>` nesting convention itself, §2): `nutrition_log
    /// .energy_kcal`, `.protein_g`, `.carbs_g`, `.fat_g` -- read here (after
    /// GoogleHealthClient strips the `nutrition_log.` prefix) as
    /// `point.values["energy_kcal"/"protein_g"/"carbs_g"/"fat_g"]`. All four
    /// are independently optional (WP-13: "partial nutrient sets allowed,
    /// e.g. energy + protein only, no carbs/fat") -- see
    /// `MappedNutritionCorrelation`'s doc comment (MappedTypes.swift) for the
    /// companion "one GoogleDataPoint = one meal" assumption this decoding
    /// relies on (Nutrition Log is a Sample (S) record type per
    /// base-knowledge.md §3, not a Session (Se) like Exercise/Sleep, so no
    /// `sessionPayload` decoding is involved here at all).
    ///
    /// Per-field negative-value guard, same "drop just the bad field, not
    /// the whole point" philosophy `decideExercise`'s distance/energy
    /// handling already established (as opposed to `decideSteps`/
    /// `decideHeartRate`'s "drop the whole point" guard) -- an implausible
    /// single macro reading doesn't mean the whole meal log entry is
    /// garbage, and WP-13's "partial sets allowed" instruction already
    /// establishes that a meal need not report every macro. Zero is a valid,
    /// ordinary reading for any macro (e.g. 0 g protein for a black coffee
    /// log) and is kept, matching every other WP-07/11 "count >= 0" guard.
    /// If every macro is missing or dropped, there is nothing left to
    /// correlate -- `.skip`, never an empty `HKCorrelation` (same "never
    /// emit a degenerate empty result" rule `decideSleep`'s
    /// all-segments-dropped case already established).
    private static func decideNutritionLog(_ point: GoogleDataPoint) -> MappedDecision {
        guard point.end >= point.start else { return .skip }

        let sampleMetadata = metadata(for: point)

        // Round-7 item 3: the correlation and each constituent carry
        // distinct UUIDs (field-named roles — stable across runs). One
        // shared UUID made HealthKit reject the meal batch.
        func namedConstituent(_ field: String, identifier: String, unit: MappedUnit) -> MappedQuantitySample? {
            guard let raw = point.values[field], raw >= 0 else { return nil }
            var sample = MappedQuantitySample(
                healthKitIdentifier: identifier,
                unit: unit,
                value: raw,
                start: point.start,
                end: point.end,
                metadata: sampleMetadata
            )
            sample.metadata = sample.metadata.derivedUUID(role: field)
            return sample
        }

        let constituents = [
            namedConstituent("energy_kcal", identifier: "HKQuantityTypeIdentifierDietaryEnergyConsumed", unit: .kilocalorie),
            namedConstituent("protein_g", identifier: "HKQuantityTypeIdentifierDietaryProtein", unit: .gram),
            namedConstituent("carbs_g", identifier: "HKQuantityTypeIdentifierDietaryCarbohydrates", unit: .gram),
            namedConstituent("fat_g", identifier: "HKQuantityTypeIdentifierDietaryFatTotal", unit: .gram),
        ].compactMap { $0 }

        guard !constituents.isEmpty else { return .skip }

        return .correlation(
            MappedNutritionCorrelation(
                healthKitIdentifier: "HKCorrelationTypeIdentifierFood",
                start: point.start,
                end: point.end,
                constituents: constituents,
                metadata: sampleMetadata.derivedUUID(role: "meal")
            )
        )
    }

    // MARK: - Sleep (sleepAnalysis category, multi-stage)

    private static func decideSleep(_ point: GoogleDataPoint) -> MappedDecision {
        guard point.end >= point.start else { return .skip }
        guard
            let payload = point.sessionPayload,
            let wire = SleepSessionDecoding.decode(payload)
        else { return .skip }

        let identifier = "HKCategoryTypeIdentifierSleepAnalysis"
        let sampleMetadata = metadata(for: point)

        // WP-51: a session with no stage breakdown (a short nap, some
        // classic sleeps) is still sleep -- one unspecified-asleep sample
        // spanning it, rather than dropping the night.
        guard !wire.segments.isEmpty else {
            guard point.end > point.start else { return .skip }
            return .category([
                MappedCategorySample(
                    healthKitIdentifier: identifier,
                    stage: .asleepUnspecified,
                    start: point.start,
                    end: point.end,
                    metadata: sampleMetadata.derivedUUID(role: "sleep-0")
                ),
            ])
        }

        // WP-07 step 3: "Segments must not overlap; clamp to session
        // bounds." Sorting by start and walking a monotonically
        // non-decreasing cursor guarantees both: each emitted segment's
        // start is clamped forward to at least the previous emitted
        // segment's end (so it can never overlap it) and both its start and
        // end are clamped to the session's own [start, end] bounds; a
        // segment that's zero-length on arrival, or fully consumed by
        // clamping (e.g. entirely overlapped by an earlier segment, or
        // entirely outside the session bounds), is dropped rather than
        // emitted as a degenerate zero-duration sample (WP-07's "Tests:"
        // line: "zero-length segment").
        let ordered = wire.segments.sorted { $0.startTime < $1.startTime }
        var cursor = point.start
        var result: [MappedCategorySample] = []
        // Round-7 item 3: per-segment UUIDs (`sleep-<index>`) — the
        // pre-sort order is deterministic, so re-syncs reproduce them.
        // Shared `point.id` across stages made HealthKit reject the
        // whole batch, failing every sleep sync forever.
        var emittedIndex = 0
        for segment in ordered {
            let clampedStart = Swift.max(segment.startTime, cursor, point.start)
            let clampedEnd = Swift.min(segment.endTime, point.end)
            guard clampedEnd > clampedStart else { continue }
            result.append(
                MappedCategorySample(
                    healthKitIdentifier: identifier,
                    stage: stage(for: segment.stage),
                    start: clampedStart,
                    end: clampedEnd,
                    metadata: sampleMetadata.derivedUUID(role: "sleep-\(emittedIndex)")
                )
            )
            emittedIndex += 1
            cursor = clampedEnd
        }
        guard !result.isEmpty else { return .skip }
        return .category(result)
    }

    /// WP-07 step 3's stage map, on the API's `Sleep.SleepStageType`
    /// (WP-51): `AWAKE→.awake`, `LIGHT→.asleepCore`, `DEEP→.asleepDeep`,
    /// `REM→.asleepREM`. Classic sleep's `ASLEEP` and `RESTLESS` (restless is
    /// movement while asleep, not waking), `SLEEP_STAGE_TYPE_UNSPECIFIED` and
    /// anything unrecognised → `.asleepUnspecified`.
    private static func stage(for rawStage: String) -> MappedSleepStage {
        switch rawStage {
        case "AWAKE": return .awake
        case "LIGHT": return .asleepCore
        case "DEEP": return .asleepDeep
        case "REM": return .asleepREM
        default: return .asleepUnspecified
        }
    }

    // MARK: - Shared metadata (WP-07 step 4 / architecture.md D4)

    private static func metadata(for point: GoogleDataPoint) -> MappedMetadata {
        MappedMetadata(
            externalUUID: point.id,
            externalID: point.id,
            sourceDevice: point.source.deviceDisplayName,
            timeZoneIdentifier: point.utcOffset.flatMap { TimeZone(secondsFromGMT: Int($0))?.identifier }
        )
    }
}
