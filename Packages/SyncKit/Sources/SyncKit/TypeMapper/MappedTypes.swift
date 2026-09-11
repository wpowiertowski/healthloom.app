// MappedTypes.swift
//
// WP-07 (implementation-plan.md): the HealthKit-free "mapping decision"
// representation `TypeMapper.decide(_:)` (TypeMapper.swift) produces.
// Mirrors the pure/impure split WP-06 established for HealthKit identifier
// strings (`HealthKitIdentifierClassifier` = pure, always compiles;
// `HealthKitObjectTypeResolver` = HealthKit-only, `#if canImport(HealthKit)`):
// everything in *this* file is plain Swift values (Date, String, Double, Int)
// with zero HealthKit and zero CoreModel/GoogleHealthClient dependency, so
// the mapping *decision* -- which sample to emit, with what value/unit/
// dates/metadata, or whether to drop/localOnly/skip a data point -- is fully
// unit-testable on any platform `swift test` runs on, independent of whether
// HealthKit itself happens to be importable there. `MappedObject.swift` is
// the thin layer built on top of this that wraps a `MappedDecision` into the
// real `HKQuantitySample`/`HKCategorySample` objects WP-07's required public
// signature (`TypeMapper.map(_:) -> MappedObject`) asks for.
//
// architecture.md §4 D13 note (read, not implemented, per this WP's brief):
// this shape deliberately carries enough per-sample identity (external ID,
// start/end, source device) that a later conflict resolver (WP-12b) can
// diff/suppress individual mapped samples without `TypeMapper` needing to
// know anything about watch coverage windows -- but WP-07 does not implement
// that resolution itself; `MappedDecision`/`MappedObject` are deliberately
// *not* over-built with any conflict-resolution fields (e.g. no
// `linkedWatchWorkoutUUID` here -- that lives on CoreModel's `LocalSample`
// and is populated by WP-12b, not by this mapping layer).

import Foundation

/// HealthKit unit this sample should be constructed with, expressed without
/// importing HealthKit. `MappedObject.swift`'s HK-wrapping layer turns each
/// case into the real `HKUnit`.
///
/// WP-11 additions below were verified against the real `HKUnit`/
/// `HKQuantityTypeIdentifier` factory APIs (`HKUnit.h` in the iOS 26.4
/// simulator SDK, plus a scratch `swiftc -typecheck` against the real
/// `HealthKit.framework`) before being written here, the same "confirm
/// against the real SDK, don't guess" discipline WP-06/07 already applied
/// to `HKObjectType`/`HKCategoryValueSleepAnalysis` -- see progress.md's
/// WP-11 entry for the exact commands run.
nonisolated public enum MappedUnit: Sendable, Hashable {
    /// `HKUnit.count()` -- steps, floors (flights climbed).
    case count
    /// `HKUnit.count().unitDivided(by: .minute())` -- heart rate (bpm),
    /// resting heart rate, respiratory rate (breaths/min uses the same
    /// count/min unit in HealthKit -- there is no separate "breaths" unit).
    case countPerMinute
    /// `HKUnit.gramUnit(with: .kilo)` -- body mass.
    case kilogram
    /// `HKUnit.meter()` -- distance (already normalized mm->m by
    /// GoogleHealthClient's `UnitNormalizer`, WP-05), height.
    case meter
    /// `HKUnit.kilocalorie()` -- active energy burned.
    case kilocalorie
    /// `HKUnit.percent()` -- HealthKit's `0...1` fraction unit (the literal
    /// name is "percent" but its documented range is `0.0...1.0`, per
    /// `HKUnit.h`: "% (0.0 - 1.0)"). Used for SpO2 (oxygen saturation) and
    /// body fat percentage -- WP-11's explicit requirement that both emit
    /// fraction values in `0...1`, never `0...100`. Every `decide(_:)`
    /// function that produces this unit is responsible for the percent->
    /// fraction conversion itself (TypeMapper.swift); this case's own
    /// invariant (enforced by `TypeMapperPropertyTests`) is that any
    /// `MappedQuantitySample` with `unit == .fraction` always has
    /// `0...1.contains(value)`.
    case fraction
    /// `HKUnit.degreeCelsius()` -- core body temperature.
    case degreeCelsius
    /// `HKUnit.liter()` -- hydration (dietary water).
    case liter
    /// `HKUnit.gram()` (HealthKit's plain, unprefixed gram unit -- WP-11's
    /// `.kilogram` case uses `gramUnitWithMetricPrefix:.kilo` instead; this is
    /// the bare `+gramUnit` factory) -- WP-13's Nutrition Log macros
    /// (protein/carbs/fat, all documented `g, Cumulative` in HealthKit's own
    /// `HKTypeIdentifiers.h`). Verified against the real SDK the same way as
    /// every other WP-11/13 unit -- see progress.md's WP-13 entry.
    case gram
    /// `HKUnit.gramUnit(with: .milli).unitDivided(by: HKUnit.literUnit(with:
    /// .deci))` -- blood glucose, US-conventional mg/dL variant.
    case milligramsPerDeciliter
    /// `HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose)
    /// .unitDivided(by: .liter())` -- blood glucose, most-of-the-rest-of-
    /// the-world mmol/L variant. `HKUnitMolarMassBloodGlucose` is a real
    /// HealthKit-defined constant (`HKUnit.h`: `180.15588000005408`), not a
    /// hand-derived conversion factor.
    case millimolesPerLiter
    /// `HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with:
    /// .kilo).unitMultiplied(by: .minute()))` -- VO2 Max / Run VO2 Max, i.e.
    /// mL/(kg·min). Built via `HKUnit`'s multiply/divide combinators (the
    /// same pattern `.countPerMinute` already uses) rather than
    /// `HKUnit(from: "mL/(kg*min)")` string parsing, to avoid depending on
    /// getting an unverified unit-string grammar exactly right.
    case vo2MaxUnit
}

/// Sleep stage, expressed as the exact `HKCategoryValueSleepAnalysis` raw
/// `Int` HealthKit itself defines (Apple HealthKit docs: `inBed` = 0,
/// `asleepUnspecified` = 1, `awake` = 2, `asleepCore` = 3, `asleepDeep` = 4,
/// `asleepREM` = 5 -- `inBed` is never produced by this mapper, so it has no
/// case here). Hardcoded as literal raw values here (rather than importing
/// HealthKit to read the real enum) so this file stays HealthKit-free;
/// `TypeMapperHealthKitMappingTests` (`#if canImport(HealthKit)`) cross-checks
/// every one of these literals against the real `HKCategoryValueSleepAnalysis`
/// enum so a future SDK change can't silently drift the two apart.
///
/// WP-07 step 3's stage map: `awake`→`.awake`, `light`→`.asleepCore`,
/// `deep`→`.asleepDeep`, `rem`→`.asleepREM`, any other/unrecognized stage
/// string→`.asleepUnspecified`.
nonisolated public enum MappedSleepStage: Int, Sendable, Hashable, CaseIterable {
    case asleepUnspecified = 1
    case awake = 2
    case asleepCore = 3
    case asleepDeep = 4
    case asleepREM = 5
}

/// Idempotency + provenance metadata stamped on every emitted sample
/// (architecture.md §4 D4; WP-07 step 4).
///
/// `nonisolated` (WP-12b, applied to every stored-property struct in this
/// file): these are pure `Sendable` value types, but under this package's
/// `.defaultIsolation(MainActor.self)` their stored properties would
/// otherwise be MainActor-isolated members -- the exact gotcha WP-05 hit
/// with `GoogleDataPoint`/`DataSource` and solved the same way (see
/// progress.md's WP-04/05 entry). WP-12b's `WatchConflictResolver` (its own
/// actor, not MainActor) reads `MappedWorkout.start/.end` and rebuilds
/// pro-rated `MappedQuantitySample` copies, which requires synchronous
/// member access from off the main actor.
nonisolated public struct MappedMetadata: Sendable, Hashable {
    /// `HKMetadataKeyExternalUUID` value — USUALLY the Google data-point
    /// ID (`GoogleDataPoint.id`), but SUFFIXED per emitted sample
    /// (`"<id>#<role>"`) wherever one point expands to many HealthKit
    /// samples (round-7 item 3): HealthKit rejects duplicate-UUID
    /// batches, so sharing one UUID across sleep stages / nutrition
    /// constituents / split parts / workout attachments failed every
    /// such sync forever. The suffix role is stable per expansion
    /// (index or field name), so re-syncs reproduce the exact UUIDs —
    /// idempotency-safe. This is the key `HealthKitWriter` (WP-08) will
    /// query against via `HKQuery.predicateForObjects(withMetadataKey:
    /// allowedValues:)` for idempotent re-sync (architecture.md D4).
    public var externalUUID: String
    /// `"healthloom.externalID"` -- same value as `externalUUID`, duplicated
    /// under HealthLoom's own namespaced key per WP-07 step 4's literal spec.
    /// Kept as a distinct field (not derived from `externalUUID` at the call
    /// site) deliberately: `HKMetadataKeyExternalUUID` is the HealthKit-native
    /// dedupe key; the `healthloom.*` copy is HealthLoom's own namespaced record
    /// of the same fact, robust to any future change in which HealthKit
    /// metadata key WP-08 dedupes against.
    public var externalID: String
    /// `"healthloom.sourceDevice"` -- `GoogleDataPoint.source.deviceDisplayName`,
    /// or `nil` when Google didn't report a device name (the app renamed from
    /// "bridge.*" to "healthloom.*" -- see this file's header and
    /// progress.md's WP-07 entry).
    public var sourceDevice: String?

    public init(externalUUID: String, externalID: String, sourceDevice: String?) {
        self.externalUUID = externalUUID
        self.externalID = externalID
        self.sourceDevice = sourceDevice
    }

    /// Workout-attachment roles `saveWorkout` stamps (round-8 item 2):
    /// the SAME strings the cleanup deletes by — a new attachment
    /// role needs one let here, one use in `saveWorkout`, and automatic
    /// coverage via `workoutAttachmentRoles` below (an unstamped role
    /// orphans; an undeleted role double-counts).
    public static let workoutDistanceRole = "distance"
    public static let workoutEnergyRole = "energy"
    public static let workoutAttachmentRoles = [workoutDistanceRole, workoutEnergyRole]

    /// Derived per-sample UUID (round-7 item 3): `externalID` (the bare
    /// point ID, kept as stable point identity) plus a stable role —
    /// every HealthKit sample from one expansion carries a UNIQUE
    /// external UUID while re-syncs reproduce them exactly.
    /// The ONE constructor for suffixed UUIDs (round-8 item 2):
    /// `derivedUUID` and the cleanup's delete-set both go through here,
    /// so the separator shape can never drift apart between stamping
    /// and deleting.
    public static func suffixedUUID(base: String, role: String) -> String {
        "\(base)#\(role)"
    }

    public func derivedUUID(role: String) -> MappedMetadata {
        MappedMetadata(
            externalUUID: Self.suffixedUUID(base: externalID, role: role),
            externalID: externalID,
            sourceDevice: sourceDevice
        )
    }
}

/// Pure, HealthKit-free description of one `HKQuantitySample` `TypeMapper`
/// decided to emit.
nonisolated public struct MappedQuantitySample: Sendable, Hashable {
    /// `HKQuantityTypeIdentifier` rawValue, e.g.
    /// `"HKQuantityTypeIdentifierStepCount"` -- always one of
    /// `GoogleDataType.writability`'s `.healthKit` strings (CoreModel's
    /// single source of truth; never re-derived here).
    public var healthKitIdentifier: String
    public var unit: MappedUnit
    public var value: Double
    public var start: Date
    public var end: Date
    public var metadata: MappedMetadata

    public init(
        healthKitIdentifier: String,
        unit: MappedUnit,
        value: Double,
        start: Date,
        end: Date,
        metadata: MappedMetadata
    ) {
        self.healthKitIdentifier = healthKitIdentifier
        self.unit = unit
        self.value = value
        self.start = start
        self.end = end
        self.metadata = metadata
    }
}

/// Pure, HealthKit-free description of one `HKCategorySample` stage segment
/// `TypeMapper` decided to emit (WP-07 step 3: a sleep session maps to an
/// array of these).
nonisolated public struct MappedCategorySample: Sendable, Hashable {
    /// `HKCategoryTypeIdentifier` rawValue, e.g.
    /// `"HKCategoryTypeIdentifierSleepAnalysis"`.
    public var healthKitIdentifier: String
    public var stage: MappedSleepStage
    public var start: Date
    public var end: Date
    public var metadata: MappedMetadata

    public init(
        healthKitIdentifier: String,
        stage: MappedSleepStage,
        start: Date,
        end: Date,
        metadata: MappedMetadata
    ) {
        self.healthKitIdentifier = healthKitIdentifier
        self.stage = stage
        self.start = start
        self.end = end
        self.metadata = metadata
    }
}

/// Coarse workout-activity bucket, expressed without importing HealthKit
/// (mirrors `MappedSleepStage`'s HealthKit-free posture, WP-07). Unlike
/// `MappedSleepStage`, this does **not** hardcode the real `HKWorkoutActivityType`
/// raw `UInt` values -- that enum has ~80 cases spread across many OS
/// versions, so mirroring its raw values by hand here would be far more
/// error-prone than switching on named cases in the HealthKit-only layer.
/// `MappedObject.swift`'s `makeHKWorkoutActivityType()` maps each case below
/// to the real, *named* `HKWorkoutActivityType` case instead (verified
/// against the real SDK header before being written -- see progress.md's
/// WP-12 entry).
///
/// WP-12 step 2: "Map the ~13 coarse Google exercise types to
/// HKWorkoutActivityType via ONE explicit table, default bucket .other for
/// anything unrecognized." See `TypeMapper.swift`'s
/// `googleExerciseActivityTypes` table for the Google wire-string -> case
/// mapping this enum's cases are the target of; that table (not this enum)
/// is where the "~13 Google types" themselves are documented, since
/// base-knowledge.md's §5 mapping-table row names no exact wire values --
/// only "~13 Google types are coarse."
nonisolated public enum MappedWorkoutActivityType: Sendable, Hashable, CaseIterable {
    case running
    case walking
    case cycling
    case swimming
    case hiking
    case traditionalStrengthTraining
    case yoga
    case elliptical
    case rowing
    case highIntensityIntervalTraining
    case stairClimbing
    case coreTraining
    /// Default bucket for anything not in `TypeMapper`'s explicit table --
    /// covers both Google's own generic "workout" wire value (an explicit
    /// table entry that itself targets `.other`) *and* any wire string the
    /// table doesn't recognize at all (WP-12: "default bucket .other for
    /// anything unrecognized").
    case other
}

/// Pure, HealthKit-free description of one Exercise session `TypeMapper`
/// decided to emit as a workout (WP-12). `start`/`end` are the session's own
/// bounds (`GoogleDataPoint.start`/`.end`) -- exactly what `HKWorkoutBuilder`
/// needs for `beginCollection`/`endCollection` (HealthKitWriter.swift);
/// duration is deliberately not a separate stored field here, since it's
/// always derivable from these two dates (see `ExerciseSessionDecoding.swift`'s
/// header for why WP-12's "duration" ask is satisfied this way rather than
/// by a redundant third wire field). Distance/energy are optional -- Google's
/// session payload may or may not report either (WP-12: "attach distance/
/// energy quantity samples if present").
nonisolated public struct MappedWorkout: Sendable, Hashable {
    public var activityType: MappedWorkoutActivityType
    public var start: Date
    public var end: Date
    /// Meters -- `nil` when Google's session payload didn't report a
    /// distance, or reported an implausible negative one (dropped, not kept
    /// -- see `TypeMapper.decideExercise`'s doc comment). See
    /// `ExerciseSessionDecoding.swift`'s header for the assumed wire unit.
    public var distanceMeters: Double?
    /// Kilocalories -- `nil` when Google's session payload didn't report
    /// energy, or reported an implausible negative one.
    public var energyKilocalories: Double?
    public var metadata: MappedMetadata

    public init(
        activityType: MappedWorkoutActivityType,
        start: Date,
        end: Date,
        distanceMeters: Double?,
        energyKilocalories: Double?,
        metadata: MappedMetadata
    ) {
        self.activityType = activityType
        self.start = start
        self.end = end
        self.distanceMeters = distanceMeters
        self.energyKilocalories = energyKilocalories
        self.metadata = metadata
    }
}

/// Pure, HealthKit-free description of one Google Nutrition Log entry
/// ("meal") `TypeMapper` decided to emit as an `HKCorrelation(.food)` (WP-13).
///
/// **Meal-grouping-key assumption (flagged, not confirmed against a real
/// payload -- same posture as every WP-11/12 field-name/shape note; see
/// progress.md's WP-13 entry for the full reasoning):** base-knowledge.md §3
/// records Nutrition Log as a **Sample (S)** record type -- the same record
/// kind as Weight/Height/Blood Glucose/etc., *not* a Session (Se) like
/// Exercise/Sleep. This mapper therefore assumes **one `GoogleDataPoint` =
/// one meal/log entry**, with up to four macro fields flat in that single
/// point's `values` dict (no nested `sessionPayload`, no cross-point
/// grouping). WP-13's spec line "meal grouping key = Google log entry ID" is
/// satisfied trivially under this assumption: `GoogleDataPoint.id` *is* the
/// meal's own external ID (identical to every other Sample-type row in this
/// file), stamped onto both this correlation and every one of its
/// constituents via `metadata` below -- there is no separate multi-point
/// grouping step to perform. If a real payload instead spreads one meal's
/// macros across multiple `GoogleDataPoint`s sharing a common (but
/// differently-keyed) meal identifier, only `TypeMapper.decideNutritionLog`
/// needs to change (add a grouping step upstream); this struct's shape
/// (a correlation's worth of constituents) would still apply.
nonisolated public struct MappedNutritionCorrelation: Sendable, Hashable {
    /// `HKCorrelationTypeIdentifier` rawValue --
    /// `"HKCorrelationTypeIdentifierFood"`, the exact sentinel string
    /// CoreModel's `GoogleDataType.writability` already declares for both
    /// `.food` and `.nutritionLog` (GoogleDataType.swift), confirmed against
    /// the real SDK (`HKTypeIdentifiers.h`'s `HKCorrelationTypeIdentifierFood`
    /// constant) rather than guessed.
    public var healthKitIdentifier: String
    public var start: Date
    public var end: Date
    /// One to four constituent macro samples -- WP-13's explicit "partial
    /// nutrient sets allowed" requirement means this is never required to
    /// have all four; `TypeMapper.decideNutritionLog` only ever produces a
    /// `.correlation` decision when this array is non-empty (an entirely
    /// empty result routes to `.skip` instead, same "nothing to write"
    /// posture every other WP-07/11 numeric guard already established).
    /// Order is insignificant (constituents become an unordered `Set<HKSample>`
    /// per the real `HKCorrelation` initializer -- see MappedObject.swift's
    /// `makeHKCorrelation()`).
    public var constituents: [MappedQuantitySample]
    /// Correlation-level metadata. Stamped identically on every constituent
    /// sample too (each `MappedQuantitySample` carries its own copy) --
    /// WP-13's brief flags this as a choice to document: both the
    /// correlation *and* its constituents get the same
    /// `HKMetadataKeyExternalUUID`/`healthloom.externalID`/
    /// `healthloom.sourceDevice` (all derived from this one meal's
    /// `GoogleDataPoint.id`), because (1) `SyncEngine`'s existence-diff for
    /// this type queries only `HKObjectType.correlationType(forIdentifier:
    /// .food)` (the correlation itself is what D4's per-(type,window)
    /// dedupe check needs), but (2) the constituent quantity samples are
    /// independently queryable/readable HealthKit objects in their own right
    /// (e.g. a future `KnowledgeStore` nutrition summary reading
    /// `dietaryProtein` directly, not through correlation membership) --
    /// architecture.md D4 says "every HealthKit sample," not "every
    /// correlation," so constituents get the same stamp architecture.md
    /// already requires of them individually. This costs nothing extra to
    /// implement: `MappedQuantitySample.makeHKQuantitySample()` (WP-07)
    /// already stamps whatever `MappedMetadata` it's given, so reusing it
    /// per constituent below stamps them automatically.
    public var metadata: MappedMetadata

    public init(
        healthKitIdentifier: String,
        start: Date,
        end: Date,
        constituents: [MappedQuantitySample],
        metadata: MappedMetadata
    ) {
        self.healthKitIdentifier = healthKitIdentifier
        self.start = start
        self.end = end
        self.constituents = constituents
        self.metadata = metadata
    }
}

/// `TypeMapper.decide(_:)`'s pure result -- see `MappedObject`
/// (MappedObject.swift) for the HealthKit-wrapping counterpart
/// `TypeMapper.map(_:)` derives from this.
nonisolated public enum MappedDecision: Sendable, Hashable {
    case quantity(MappedQuantitySample)
    case category([MappedCategorySample])
    /// WP-12: one Google Exercise session -> one `HKWorkout`. Unlike
    /// `.quantity`/`.category`, this is **not** turned into a real HealthKit
    /// object by `MappedObject.swift`'s `TypeMapper.map(_:)` -- a real
    /// `HKWorkout` can't be constructed synchronously (its own initializers
    /// are deprecated in favor of `HKWorkoutBuilder`'s async, store-backed
    /// flow), so `MappedObject.workout(_:)` carries this same pure value
    /// forward instead; `HealthKitWriter.saveWorkout(_:)`
    /// (HealthKitWriter.swift) is where the real `HKWorkoutBuilder` flow
    /// actually runs. See that file's header for the full split rationale.
    case workout(MappedWorkout)
    /// WP-13: one Google Nutrition Log entry ("meal") -> one
    /// `HKCorrelation(.food)` grouping 1-4 constituent dietary quantity
    /// samples. Unlike `.workout`, a real `HKCorrelation` **can** be
    /// constructed synchronously -- `HKCorrelation`'s own factory
    /// initializer (`+correlationWithType:startDate:endDate:objects:metadata:`,
    /// confirmed against the real SDK header, `HKCorrelation.h`) is not
    /// deprecated and needs no builder/store, unlike `HKWorkout` -- so this
    /// follows the `.quantity`/`.category` precedent instead: `MappedObject
    /// .swift`'s `TypeMapper.map(_:)` turns this into a real `HKCorrelation`
    /// directly, the same way it turns `.quantity`/`.category` into real
    /// `HKQuantitySample`/`HKCategorySample` objects.
    case correlation(MappedNutritionCorrelation)
    /// architecture.md D2: no writable HealthKit target for this
    /// `GoogleDataType` -- persisted only to `LocalSample` (WP-09/WP-14).
    case localOnly
    /// Unknown/unmapped data type, a `.healthKit`-writable type this package
    /// deliberately never writes (`.totalCalories` -- no basal split
    /// invented, WP-11; `.food` -- base-knowledge.md §3 never marks plain
    /// "Food" ✅-writable, only "Nutrition Log" is, despite CoreModel's
    /// writability table pairing both under the same `HKCorrelationTypeIdentifierFood`
    /// sentinel, WP-13), or a data point this package's rules decided to
    /// drop (WP-07 step 5; out-of-range values -- see TypeMapper.swift).
    case skip
}
