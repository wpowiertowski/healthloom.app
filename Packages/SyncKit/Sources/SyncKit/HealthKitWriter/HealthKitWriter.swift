// HealthKitWriter.swift
//
// WP-08 (implementation-plan.md) / architecture.md §4 D2, D4, D13.
// The public deliverable: batched, idempotent writes and scoped deletes,
// built entirely on top of `HealthStoreProtocol` (HealthStoreProtocol.swift)
// so this type itself never touches `HKHealthStore` directly — every real
// HealthKit call lives in `HealthKitStore`, this file only orchestrates.
//
// Consumes WP-07's `MappedObject`/`MappedDecision` output indirectly: callers
// (WP-09's `SyncEngine`) unwrap `MappedObject.quantity`/`.category` into
// `HKObject`s themselves and hand this type the resulting batch — this file
// deliberately does not import or depend on TypeMapper/MappedObject.swift at
// all, keeping the WP-07/WP-08 boundary a plain `[HKObject]`.
//
// Guarded with #if canImport(HealthKit) — see HealthStoreProtocol.swift's
// header for the platform-boundary rationale, which applies identically here.
#if canImport(HealthKit)
import HealthKit

/// Batched, idempotent HealthKit writes and scoped deletes
/// (implementation-plan.md WP-08).
///
/// Holds a `HealthStoreProtocol`, not a concrete `HKHealthStore` — inject a
/// `MockHealthStore` (test target) for unit tests that need no HealthKit
/// entitlement, or the real `HealthKitStore` (this package, HealthStoreProtocol.swift)
/// for production. This is exactly the seam WP-09's `SyncEngine` needs to be
/// testable in turn: `SyncEngine` holds a `HealthKitWriter`, never an
/// `HKHealthStore` or a `HealthStoreProtocol` directly, so swapping the
/// backing store never touches call sites.
public final class HealthKitWriter: Sendable {
    private let store: HealthStoreProtocol
    private let workoutBuilderFactory: WorkoutBuilderFactory

    /// Primary initializer — inject any `HealthStoreProtocol` conformer, and
    /// (WP-12) any `WorkoutBuilderFactory` conformer. `workoutBuilderFactory`
    /// defaults to the real `HealthKitWorkoutBuilderFactory` (backed by a
    /// fresh `HKHealthStore`) so every existing call site that only ever
    /// passed `store:` (predating WP-12) keeps compiling unchanged; tests
    /// that specifically exercise `saveWorkout(_:)` inject a
    /// `MockWorkoutBuilderFactory` instead
    /// (`Tests/SyncKitTests/HealthKitWriter/MockWorkoutBuilder.swift`).
    public init(
        store: HealthStoreProtocol,
        workoutBuilderFactory: WorkoutBuilderFactory = HealthKitWorkoutBuilderFactory(healthStore: HKHealthStore())
    ) {
        self.store = store
        self.workoutBuilderFactory = workoutBuilderFactory
    }

    /// Production convenience: wraps a real `HKHealthStore` in `HealthKitStore`
    /// for you, and (WP-12) uses that same store for the real
    /// `HealthKitWorkoutBuilderFactory` too. Pass the same `HKHealthStore`
    /// instance `HealthKitAuth` already owns if one exists in scope, so the
    /// app shares one store instance (HealthKitAuth.swift's "one store per
    /// app" note) — this initializer does not itself enforce that, since
    /// `HealthKitWriter` and `HealthKitAuth` are independent, separately-DI'd
    /// types (same pattern as `KeychainStore`/`GoogleAuthManager` elsewhere
    /// in this app).
    public convenience init(healthStore: HKHealthStore = HKHealthStore()) {
        self.init(
            store: HealthKitStore(healthStore: healthStore),
            workoutBuilderFactory: HealthKitWorkoutBuilderFactory(healthStore: healthStore)
        )
    }

    /// Batched existence check (architecture.md D4): the `healthloom`-stamped
    /// external IDs already present in HealthKit for `type` within
    /// `[start, end]`, in exactly one underlying query — see
    /// `HealthStoreProtocol.existingExternalIDs(ofType:start:end:)`'s doc
    /// comment (HealthStoreProtocol.swift) for the exact predicate strategy
    /// and why. Callers (WP-09's `SyncEngine`) diff their incoming page
    /// against this set in memory and only pass the *new* objects to
    /// `save(_:)` below.
    public func existingExternalIDs(
        type: HKSampleType,
        start: Date,
        end: Date
    ) async throws(HealthKitWriterError) -> Set<String> {
        try await store.existingExternalIDs(ofType: type, start: start, end: end)
    }

    /// App-written sample records (external ID + interval) of `type` within
    /// `[start, end]` -- WP-12b's retroactive conflict cleanup input
    /// (architecture.md D13.4). Thin passthrough, same shape as
    /// `existingExternalIDs` above.
    public func appWrittenSampleRecords(
        type: HKSampleType,
        start: Date,
        end: Date
    ) async throws(HealthKitWriterError) -> [AppWrittenSampleRecord] {
        try await store.appWrittenSampleRecords(ofType: type, start: start, end: end)
    }

    /// Save `batch` with exactly **one** underlying HealthKit save call
    /// (architecture.md D4 / WP-08 step 3) — never one call per sample. A
    /// no-op for an empty batch (skips the round-trip entirely rather than
    /// asking HealthKit to save nothing).
    public func save(_ batch: [HKObject]) async throws(HealthKitWriterError) {
        guard !batch.isEmpty else { return }
        try await store.save(batch)
    }

    /// Delete every object of `type` whose external ID is in `externalIDs`.
    /// Used for "update" (delete-by-external-ID + re-insert, since HK samples
    /// are immutable — architecture.md D4).
    @discardableResult
    public func delete(
        externalIDs: Set<String>,
        type: HKObjectType
    ) async throws(HealthKitWriterError) -> Int {
        guard !externalIDs.isEmpty else { return 0 }
        return try await store.deleteObjects(ofType: type, externalIDs: externalIDs)
    }

    /// The HealthKit distance bucket matching a workout's activity
    /// type. `nil` means HealthKit models no distance for that activity --
    /// the caller then attaches no distance sample (see `saveWorkout`).
    /// Single edit point: `WatchConflictResolver.retroactiveCleanup`'s
    /// sweep list must cover every non-nil row here (it deletes by the same
    /// external-ID stamp).
    // `nonisolated`: pure table, callable from `WatchConflictResolver`'s
    // own actor (this class otherwise inherits the package's MainActor
    // default isolation).
    nonisolated static func distanceIdentifier(
        for activityType: MappedWorkoutActivityType
    ) -> HKQuantityTypeIdentifier? {
        switch activityType {
        case .running, .walking, .hiking:
            return .distanceWalkingRunning
        case .cycling:
            return .distanceCycling
        case .swimming:
            return .distanceSwimming
        case .rowing:
            return .distanceRowing
        case .elliptical, .traditionalStrengthTraining, .yoga,
             .highIntensityIntervalTraining, .stairClimbing, .coreTraining,
             .other:
            return nil
        }
    }

    /// Every distance bucket `distanceIdentifier(for:)` can return, for
    /// cleanup sweeps (`WatchConflictResolver.retroactiveCleanup`): derived
    /// from the same table so writer and sweeper can never disagree about
    /// which buckets exist. `allCases` order (deduped, NOT a `Set`
    /// round-trip): the sweep aborts on its first failure, so a
    /// nondeterministic order would make which buckets get cleaned before
    /// an error arbitrary run to run.
    /// Public for WP-35's wipe set (same table the share request uses).
    nonisolated public static var distanceIdentifiersForCleanup: [HKQuantityTypeIdentifier] {
        var seen: [HKQuantityTypeIdentifier] = []
        for activityType in MappedWorkoutActivityType.allCases {
            guard let identifier = distanceIdentifier(for: activityType),
                  !seen.contains(identifier)
            else { continue }
            seen.append(identifier)
        }
        return seen
    }

    /// Everything a workout save may write beyond `GoogleDataType
    /// .writability`: the workout itself, its energy attachment, and every
    /// distance bucket above. Single source of truth for the share set
    /// `HealthKitAuth` must request before exercise sync can succeed (the
    /// distance buckets are structurally unreachable from `writability`,
    /// and -- found while fixing that -- `.exercise` share itself was never
    /// requested anywhere, so this set closes both gaps at once).
    /// Public for WP-35's wipe set (same union the share request makes).
    nonisolated public static var workoutShareTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = [HKObjectType.workoutType()]
        if let energy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) {
            types.insert(energy)
        }
        for identifier in distanceIdentifiersForCleanup {
            if let distance = HKObjectType.quantityType(forIdentifier: identifier) {
                types.insert(distance)
            }
        }
        return types
    }

    /// Generic multi-type variant of `delete(externalIDs:type:)` — sweeps
    /// every type in `types` for the same `externalIDs` set and sums the
    /// deleted counts. Deliberately *not* fixed to today's four P0 types
    /// (steps/heart-rate/weight/sleep): a caller that doesn't yet know (or
    /// doesn't want to track) which concrete `HKObjectType` a given external
    /// ID belongs to — e.g. D13.4's retroactive conflict cleanup, which may
    /// need to remove a mix of quantity samples and an `HKWorkout` sharing
    /// the same lookback window — can pass every candidate type here instead
    /// of calling the single-type overload once per type itself.
    @discardableResult
    public func delete(
        externalIDs: Set<String>,
        types: [HKObjectType]
    ) async throws(HealthKitWriterError) -> Int {
        guard !externalIDs.isEmpty, !types.isEmpty else { return 0 }
        var total = 0
        for type in types {
            total += try await store.deleteObjects(ofType: type, externalIDs: externalIDs)
        }
        return total
    }

    /// Delete-by-source: every object of every type in `types` this app
    /// itself wrote (architecture.md D4 / WP-35's "disconnect & wipe").
    /// Takes the type list as a parameter rather than hardcoding today's P0
    /// set for the same reason as `delete(externalIDs:types:)` above — by
    /// the time WP-35 ships, WP-11/12/13 will have broadened the writable set
    /// well beyond steps/heart-rate/weight/sleep, and `HealthKitWriter` has no
    /// business knowing that list itself (CoreModel's `GoogleDataType
    /// .writability` remains the single source of truth for it — see
    /// CoreModel.swift and HealthKitIdentifierClassifier).
    @discardableResult
    public func deleteAllAppData(types: [HKObjectType]) async throws(HealthKitWriterError) -> AppDataWipeReport {
        var counts: [String: Int] = [:]
        for type in types {
            counts[type.identifier] = try await store.deleteAllAppData(ofType: type)
        }
        return AppDataWipeReport(deletedCounts: counts)
    }

    /// WP-12: replaces the WP-08 stub with a real `HKWorkoutBuilder`
    /// integration — `beginCollection → add(samples) → endCollection →
    /// finishWorkout`, per implementation-plan.md's WP-12 step 3. Distance/
    /// energy quantity samples (`HKQuantityTypeIdentifierDistanceWalkingRunning`
    /// / `HKQuantityTypeIdentifierActiveEnergyBurned`, stamped with the same
    /// metadata as the workout itself) are attached only when `workout`
    /// reports them; metadata (architecture.md D4) is stamped via
    /// `addMetadata` before finishing, satisfying WP-12 step 4.
    ///
    /// **Return value:** mirrors `HKWorkoutBuilder.finishWorkout()`'s own
    /// contract exactly — `nil` without a thrown error is a documented
    /// success (the "device is locked" edge case; see WorkoutBuilding.swift's
    /// header), not a failure this method should convert into one.
    ///
    /// **Dedupe/idempotency** (WP-12's explicit ask: "verify workouts flow
    /// through the same idempotency mechanism, don't build a parallel one"):
    /// unlike `save(_:)`, this method does **not** itself check
    /// `existingExternalIDs` — exactly like `save(_:)`, that check is the
    /// caller's job, performed once per (type, window) *before* calling this
    /// method (architecture.md D4's "batched, never per-sample" invariant;
    /// see `existingExternalIDs(type:start:end:)`'s doc comment above).
    /// Callers pass `HKObjectType.workoutType()` as the `type` — the exact
    /// same method every other write path already uses; no parallel dedupe
    /// mechanism exists for workouts (`HKObjectType.workoutType()` is an
    /// `HKSampleType` like any other, so it needed no new overload). One
    /// real asymmetry, unavoidable given HealthKit's own API shape:
    /// `HKWorkoutBuilder.finishWorkout()` saves the resulting `HKWorkout`
    /// directly to the health store itself (per Apple's own documentation)
    /// — it does **not** flow through this class's `save(_:)`/
    /// `HealthStoreProtocol.save(_:)`. But `existingExternalIDs`'s query is a
    /// generic `HKSampleQuery` over whatever `HKSampleType` it's asked
    /// about, so it finds a builder-created workout exactly as readily as a
    /// `save(_:)`-written quantity sample — the idempotency *mechanism*
    /// (query-side) is identical even though the *write* path differs,
    /// which is unavoidable (workouts can only be created via
    /// `HKWorkoutBuilder`, never `HKHealthStore.save`). See
    /// `Tests/SyncKitTests/HealthKitWriter/WorkoutSavingTests.swift`'s
    /// `aSavedWorkoutIsDiscoverableThroughTheSameExistingExternalIDsMethod`
    /// for this proven end-to-end against mocks.
    @discardableResult
    public func saveWorkout(_ workout: MappedWorkout) async throws(HealthKitWriterError) -> HKWorkout? {
        let builder = workoutBuilderFactory.makeBuilder(
            activityType: workout.activityType.makeHKWorkoutActivityType(),
            device: nil
        )
        var metadataDictionary = workout.metadata.makeHKMetadataDictionary()
        // Distance/energy without a HealthKit bucket (`.other`, elliptical,
        // HIIT, ...) are preserved here, not dropped: no sample is attached
        // for them (filing an unknown activity under walking+running
        // corrupts totals), but the values ride the workout's own metadata
        // so they survive the round-trip and stay queryable by external ID.
        // Bucketed workouts carry the same keys -- one metadata shape for
        // every workout, sample or not.
        if let distanceMeters = workout.distanceMeters {
            metadataDictionary["healthloom.distanceMeters"] = distanceMeters
        }
        if let energyKilocalories = workout.energyKilocalories {
            metadataDictionary["healthloom.energyKilocalories"] = energyKilocalories
        }

        do {
            try await builder.beginCollection(at: workout.start)

            var samples: [HKSample] = []
            // Distance attaches under the identifier matching the workout's
            // own activity type -- never blanket `distanceWalkingRunning`
            // (a 40 km bike ride must not land in walking+running totals).
            // Activity types with no HealthKit distance counterpart (strength,
            // yoga, HIIT, ...) attach no distance sample at all: the value
            // is preserved in the workout metadata instead (see above), so
            // nothing is lost -- it just isn't double-counted under a wrong
            // bucket.
            // Round-7 item 3: attachments carry role-suffixed UUIDs —
            // sharing the workout's base UUID across distance+energy
            // made HealthKit reject the attachment batch. The
            // workout-level metadata below keeps the base UUID (one
            // workout object — no duplication there). Roles come from
            // `MappedMetadata.workoutAttachmentRoles` (round-8 item 2)
            // so the cleanup deletes exactly what was stamped.
            if let distanceMeters = workout.distanceMeters,
               let distanceIdentifier = Self.distanceIdentifier(for: workout.activityType),
               let distanceType = HKObjectType.quantityType(forIdentifier: distanceIdentifier) {
                samples.append(
                    HKQuantitySample(
                        type: distanceType,
                        quantity: HKQuantity(unit: .meter(), doubleValue: distanceMeters),
                        start: workout.start,
                        end: workout.end,
                        metadata: workout.metadata.derivedUUID(role: MappedMetadata.workoutDistanceRole).makeHKMetadataDictionary()
                    )
                )
            }
            if let energyKilocalories = workout.energyKilocalories,
               let energyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) {
                samples.append(
                    HKQuantitySample(
                        type: energyType,
                        quantity: HKQuantity(unit: .kilocalorie(), doubleValue: energyKilocalories),
                        start: workout.start,
                        end: workout.end,
                        metadata: workout.metadata.derivedUUID(role: MappedMetadata.workoutEnergyRole).makeHKMetadataDictionary()
                    )
                )
            }
            if !samples.isEmpty {
                try await builder.addSamples(samples)
            }

            try await builder.addMetadata(metadataDictionary)
            try await builder.endCollection(at: workout.end)
            return try await builder.finishWorkout()
        } catch {
            throw .underlying(String(describing: error))
        }
    }
}
#endif
