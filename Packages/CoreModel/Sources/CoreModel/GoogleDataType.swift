// GoogleDataType.swift
// CoreModel
//
// Shared vocabulary for every Google Health API data type HealthLoom knows about.
// Source of truth: google-health-healthkit-base-knowledge.md §3 (full data-type table)
// and §5 (Google → HealthKit write-target mapping).
//
// This file must never import HealthKit (architecture.md §2, §4 D2) — HealthKit
// identifiers are carried as plain strings via `GoogleDataType.Writability.healthKit`.

/// Every Google Health API data type HealthLoom is aware of (base-knowledge §3).
///
/// The raw value is the **snake_case filter identifier** used in Google Health API query
/// filters (base-knowledge §2, e.g. `body_fat`); `endpointName` derives the **kebab-case**
/// identifier used in REST paths (e.g. `body-fat`) by swapping `_` for `-`.
public enum GoogleDataType: String, CaseIterable, Sendable, Hashable, Codable {
    case activeEnergyBurned = "active_energy_burned"
    case activeMinutes = "active_minutes"
    case activeZoneMinutes = "active_zone_minutes"
    case activityLevel = "activity_level"
    case altitude = "altitude"
    case bloodGlucose = "blood_glucose"
    case bodyFat = "body_fat"
    case caloriesInHeartRateZone = "calories_in_heart_rate_zone"
    case coreBodyTemperature = "core_body_temperature"
    case dailyHeartRateVariability = "daily_heart_rate_variability"
    case dailyHeartRateZones = "daily_heart_rate_zones"
    case dailyOxygenSaturation = "daily_oxygen_saturation"
    case dailyRespiratoryRate = "daily_respiratory_rate"
    case dailyRestingHeartRate = "daily_resting_heart_rate"
    case dailySleepTemperatureDerivations = "daily_sleep_temperature_derivations"
    case dailyVO2Max = "daily_vo2_max"
    case distance = "distance"
    case electrocardiogram = "electrocardiogram"
    case exercise = "exercise"
    case floors = "floors"
    case food = "food"
    case foodMeasurementUnit = "food_measurement_unit"
    case heartRate = "heart_rate"
    case heartRateVariability = "heart_rate_variability"
    case height = "height"
    case hydrationLog = "hydration_log"
    case irregularRhythmNotification = "irregular_rhythm_notification"
    case nutritionLog = "nutrition_log"
    case oxygenSaturation = "oxygen_saturation"
    case respiratoryRateSleepSummary = "respiratory_rate_sleep_summary"
    case runVO2Max = "run_vo2_max"
    case sedentaryPeriod = "sedentary_period"
    case sleep = "sleep"
    case steps = "steps"
    case swimLengthsData = "swim_lengths_data"
    case timeInHeartRateZone = "time_in_heart_rate_zone"
    case totalCalories = "total_calories"
    case vo2Max = "vo2_max"
    case weight = "weight"

    /// snake_case identifier used in Google Health API query filters, e.g. `body_fat`
    /// (base-knowledge §2 "Identifier casing").
    public var filterName: String { rawValue }

    /// kebab-case identifier used in Google Health API REST endpoint paths, e.g.
    /// `body-fat` in `users/me/dataTypes/body-fat/dataPoints` (base-knowledge §2).
    public var endpointName: String {
        rawValue.replacingOccurrences(of: "_", with: "-")
    }

    /// Title-cased, space-separated identifier for UI display, e.g. `body_fat` ->
    /// "Body Fat". Previously hand-duplicated in three app-target views
    /// (`SettingsView`, `SyncLogRow`, `BackfillTypeRow`); shared here as the one
    /// implementation so a future formatting change (e.g. acronym handling)
    /// doesn't have to be made in four places.
    public var displayName: String {
        Self.titleCased(rawValue)
    }

    /// Splits a snake_case identifier into space-separated Title Case words.
    /// Also used by `LocalSample.decodedExercisePayload` (ExercisePayloadDecoding.swift)
    /// to title-case a wire-format activity type that isn't itself a `GoogleDataType`.
    ///
    /// `nonisolated`: a pure `String -> String` transform with no actor-isolated
    /// state, called from `LocalSample.decodedExercisePayload`'s own `nonisolated`
    /// context (that property's doc comment explains why) -- without this, passing
    /// it as a function value there fails to build under CoreModel's package-wide
    /// `.defaultIsolation(MainActor.self)`.
    nonisolated static func titleCased(_ snakeCase: String) -> String {
        snakeCase.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// The Google Health API OAuth scope family this data type belongs to
    /// (base-knowledge §3, right-most column). Read and write are separate scopes
    /// (`.readonly`/`.writeonly`) per data type; this enum identifies only the family.
    public enum Scope: String, CaseIterable, Sendable, Hashable, Codable {
        case activityAndFitness
        case healthMetrics
        case sleep
        case nutrition
        case ecg
        case irn
    }

    public var scope: Scope {
        switch self {
        case .activeEnergyBurned, .activeMinutes, .activeZoneMinutes, .activityLevel,
             .altitude, .caloriesInHeartRateZone, .dailyVO2Max, .distance, .exercise,
             .floors, .runVO2Max, .sedentaryPeriod, .steps, .swimLengthsData,
             .timeInHeartRateZone, .totalCalories, .vo2Max:
            return .activityAndFitness
        case .bloodGlucose, .bodyFat, .coreBodyTemperature, .dailyHeartRateVariability,
             .dailyHeartRateZones, .dailyOxygenSaturation, .dailyRespiratoryRate,
             .dailyRestingHeartRate, .dailySleepTemperatureDerivations, .heartRate,
             .heartRateVariability, .height, .oxygenSaturation,
             .respiratoryRateSleepSummary, .weight:
            return .healthMetrics
        case .sleep:
            return .sleep
        case .food, .foodMeasurementUnit, .hydrationLog, .nutritionLog:
            return .nutrition
        case .electrocardiogram:
            return .ecg
        case .irregularRhythmNotification:
            return .irn
        }
    }

    /// Whether — and how — this Google data type flows into Apple HealthKit
    /// (base-knowledge §5). CoreModel does not import HealthKit, so writable targets
    /// are carried as the plain HealthKit identifier **string** (e.g.
    /// `"HKQuantityTypeIdentifierStepCount"`); SyncKit's `TypeMapper` (WP-07/WP-11) is
    /// responsible for turning that string back into a real `HKQuantityTypeIdentifier`.
    public enum Writability: Sendable, Hashable {
        /// Maps directly to a writable HealthKit type. The associated string is the
        /// HealthKit identifier constant's `rawValue` (or, for compound targets that
        /// aren't a single quantity/category identifier — workouts, food correlations —
        /// a documented sentinel string; see the `writability` doc comments below).
        case healthKit(String)
        /// HealthKit has no writable target for this type (or writing it would
        /// require inventing data HealthKit doesn't accept). Persisted only to
        /// `LocalSample` for in-app display (architecture.md D2, D8; WP-14).
        case localOnly
        /// Not surfaced anywhere yet — no mapping is defined in the base-knowledge
        /// doc or implementation plan (e.g. redundant daily-rollup duplicates of an
        /// already-mapped sample-level type). `TypeMapper` must treat unknown/unmapped
        /// types this way too (WP-07 step 5): never crash, just skip.
        case skip
    }

    public var writability: Writability {
        switch self {
        // MARK: - ✅ Writable (base-knowledge §5)
        case .steps:
            return .healthKit("HKQuantityTypeIdentifierStepCount")
        case .distance:
            return .healthKit("HKQuantityTypeIdentifierDistanceWalkingRunning")
        case .floors:
            return .healthKit("HKQuantityTypeIdentifierFlightsClimbed")
        case .activeEnergyBurned:
            return .healthKit("HKQuantityTypeIdentifierActiveEnergyBurned")
        case .totalCalories:
            // §5 pairs "Active Energy Burned / Total Calories" positionally with
            // "activeEnergyBurned / basalEnergyBurned". Taken literally that puts
            // Total Calories at basalEnergyBurned, but WP-11 explicitly warns not to
            // *invent* a basal split from Google's single total. Declared here as the
            // table's literal writable target; TypeMapper (WP-11) decides at
            // implementation time whether to actually write it or to skip pending a
            // real basal-only source. See progress.md WP-02 note.
            return .healthKit("HKQuantityTypeIdentifierBasalEnergyBurned")
        case .heartRate:
            return .healthKit("HKQuantityTypeIdentifierHeartRate")
        case .dailyRestingHeartRate:
            return .healthKit("HKQuantityTypeIdentifierRestingHeartRate")
        case .heartRateVariability:
            return .healthKit("HKQuantityTypeIdentifierHeartRateVariabilitySDNN")
        case .oxygenSaturation:
            return .healthKit("HKQuantityTypeIdentifierOxygenSaturation")
        case .respiratoryRateSleepSummary:
            // §5's bare "Respiratory Rate" row has no exact-name match in §3; of the
            // two respiratory rows there (`Daily Respiratory Rate` / `Respiratory Rate
            // Sleep Summary`), the sample-level one is the natural fit for a HK sample
            // write. See progress.md WP-02 note.
            return .healthKit("HKQuantityTypeIdentifierRespiratoryRate")
        case .vo2Max, .runVO2Max:
            return .healthKit("HKQuantityTypeIdentifierVO2Max")
        case .weight:
            return .healthKit("HKQuantityTypeIdentifierBodyMass")
        case .height:
            return .healthKit("HKQuantityTypeIdentifierHeight")
        case .bodyFat:
            return .healthKit("HKQuantityTypeIdentifierBodyFatPercentage")
        case .bloodGlucose:
            return .healthKit("HKQuantityTypeIdentifierBloodGlucose")
        case .coreBodyTemperature:
            return .healthKit("HKQuantityTypeIdentifierBodyTemperature")
        case .sleep:
            return .healthKit("HKCategoryTypeIdentifierSleepAnalysis")
        case .exercise:
            // Not a quantity/category identifier — Exercise sessions become
            // `HKWorkout` objects via `HKWorkoutBuilder` (WP-12). This sentinel string
            // documents the target; there is no `HKWorkoutTypeIdentifier` constant in
            // HealthKit (workouts are addressed via `HKObjectType.workoutType()`).
            return .healthKit("HKWorkoutType")
        case .hydrationLog:
            return .healthKit("HKQuantityTypeIdentifierDietaryWater")
        case .food, .nutritionLog:
            // Both "Food" and "Nutrition Log" map to the same per-meal
            // `HKCorrelation(.food)` grouping dietaryEnergyConsumed/protein/carbs/fat
            // (base-knowledge §5, WP-13). Sentinel string, not a single quantity type.
            return .healthKit("HKCorrelationTypeIdentifierFood")

        // MARK: - ⚠️/❌ Local-only (base-knowledge §5; architecture D2, D8; WP-14)
        case .activeMinutes, .activeZoneMinutes, .electrocardiogram,
             .irregularRhythmNotification:
            return .localOnly

        // MARK: - Unmapped / redundant daily rollups → skip
        case .activityLevel, .altitude, .caloriesInHeartRateZone,
             .dailyHeartRateVariability, .dailyHeartRateZones, .dailyOxygenSaturation,
             .dailyRespiratoryRate, .dailySleepTemperatureDerivations, .dailyVO2Max,
             .foodMeasurementUnit, .sedentaryPeriod, .swimLengthsData,
             .timeInHeartRateZone:
            return .skip
        }
    }
}
