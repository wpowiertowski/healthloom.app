// HealthKitSourceDeleter.swift
//
// WP-35 "optional delete of all app-written HealthKit samples
// (delete-by-source, per-type progress)". Two halves:
//
// - The *policy* (only this app's samples, per-type outcomes, progress
//   callbacks) is pure over three injected seams, so unit tests drive it
//   with canned samples — no HealthKit, no authorization sheets (which
//   simulators can't answer, the same reason OnboardingUITests skips its
//   HealthKit-sheet test).
// - The *live* seams bridge `HKHealthStore` with the same continuation
//   pattern `TodayMetricsProvider` uses.
//
// "App-written" = `sourceRevision.source.bundleIdentifier` equal to this
// app's bundle ID — never a display-name match (localizable, spoofable).
// Failures are per-type (denied/unavailable on one type doesn't strand
// the others); the coordinator turns them into step rows.

import Foundation
import CoreModel
import HealthKit
import SyncKit

struct HealthKitSourceDeleter {
    /// All samples of one type, newest-first not required (deletion is a
    /// set operation). Live: unbounded `HKSampleQuery`.
    var fetchAll: (HKObjectType) async throws -> [HKSample]
    /// Owning bundle ID, or nil when unknown (never deleted).
    var bundleID: (HKSample) -> String?
    /// Deletes the given objects. Live: `HKHealthStore.delete(_:with:)`.
    var deleteObjects: ([HKObject]) async throws -> Void

    /// Deletes this app's samples for each type. Returns deleted counts
    /// for types that succeeded; throws nothing — per-type errors are in
    /// the returned dictionary, so one denied type can't strand the rest.
    func deleteAppWritten(
        types: [HKObjectType],
        ownBundleID: String,
        onProgress: (HKObjectType, Int) -> Void = { _, _ in }
    ) async -> [HKObjectType: Result<Int, Error>] {
        var outcomes: [HKObjectType: Result<Int, Error>] = [:]
        for type in types {
            do {
                let ours = try await fetchAll(type).filter { bundleID($0) == ownBundleID }
                if !ours.isEmpty {
                    try await deleteObjects(ours)
                }
                onProgress(type, ours.count)
                outcomes[type] = .success(ours.count)
            } catch {
                outcomes[type] = .failure(error)
            }
        }
        return outcomes
    }

    /// Production wipe path (round-4-sync item 9): server-side
    /// delete-by-source via `HealthKitWriter` — the store applies its
    /// source predicate itself (`HKSource.default()`), so the wipe never
    /// fetches unbounded multi-year sample lists into memory (jetsam)
    /// and never half-deletes ledger-less: per-type outcomes are
    /// preserved for the ledger rows, one denied/unavailable type still
    /// can't strand the rest. The seam-based `deleteAppWritten` above
    /// stays as the tested policy core; production enters here.
    /// A denied grant the wipe cannot verify (round-6 item 14 +
    /// fix-round F1): success-0 under `.sharingDenied` may mean
    /// "nothing there" or "denied" — claiming success would be the
    /// lie, so it fails loud into the ledger/partial path instead.
    struct WipeRevokedUnverifiable: Error, CustomStringConvertible {
        var typeIdentifier: String
        var description: String {
            "HealthKit access for \(typeIdentifier) was revoked — deletion could not be verified. Re-enable access and run again."
        }
    }

    static func deleteAppWrittenLive(
        types: [HKObjectType],
        writer: HealthKitWriter,
        authorizationStatus: (HKObjectType) -> HKAuthorizationStatus = { type in
            (type as? HKSampleType).map {
                HKHealthStore().authorizationStatus(for: $0)
            } ?? .notDetermined
        },
        onProgress: (HKObjectType, Int) -> Void = { _, _ in }
    ) async -> [HKObjectType: Result<Int, Error>] {
        var outcomes: [HKObjectType: Result<Int, Error>] = [:]
        for type in types {
            // Round-6 item 14 + fix-round F1: denied types are NOT
            // excluded pre-loop — every type attempts and lands a
            // ledger row. The status table, stated exactly:
            // - `.sharingAuthorized`: the delete speaks for itself
            //   (count or throw).
            // - `.notDetermined`: never requested → never written →
            //   a success-0 is PROVABLY empty, not merely hopeful.
            //   (The old Bool seam lumped this with denied and failed
            //   the wipe step for never-granted floor types.)
            // - `.sharingDenied` + success-0: unverifiable ("nothing
            //   there" vs "denied") → fail loud. A real count, or a
            //   throw, still speaks for itself.
            let status = authorizationStatus(type)
            do {
                let report = try await writer.deleteAllAppData(types: [type])
                let count = report.deletedCounts[type.identifier] ?? 0
                if count == 0, status == .sharingDenied {
                    outcomes[type] = .failure(WipeRevokedUnverifiable(typeIdentifier: type.identifier))
                } else {
                    onProgress(type, count)
                    outcomes[type] = .success(count)
                }
            } catch {
                outcomes[type] = .failure(error)
            }
        }
        return outcomes
    }

    /// Production seams over one store. Bundle ownership is decided per
    /// call (`ownBundleID`), not per deleter — the same instance serves
    /// tests and production with different identities.
    static func live(store: HKHealthStore = HKHealthStore()) -> HealthKitSourceDeleter {
        HealthKitSourceDeleter(
            fetchAll: { type in
                // Authorization pre-check: without share access the query
                // below may never call back (observed as an unbounded
                // hang on simulators), so fail fast per-type instead.
                if let sampleType = type as? HKSampleType,
                   store.authorizationStatus(for: sampleType) != .sharingAuthorized
                {
                    throw HealthKitDeleteError.notAuthorized
                }
                guard let sampleType = type as? HKSampleType else { return [] }
                return try await withCheckedThrowingContinuation { continuation in
                    let query = HKSampleQuery(
                        sampleType: sampleType,
                        predicate: nil,
                        limit: HKObjectQueryNoLimit,
                        sortDescriptors: nil
                    ) { _, samples, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: samples ?? [])
                        }
                    }
                    store.execute(query)
                }
            },
            bundleID: { $0.sourceRevision.source.bundleIdentifier },
            deleteObjects: { objects in
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    store.delete(objects) { success, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else if success {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: HealthKitDeleteError.deleteReturnedFalse)
                        }
                    }
                }
            }
        )
    }
}

extension HealthKitSourceDeleter {
    /// The wipe set, derived from exactly what onboarding authorizes
    /// (F1/F2): the P0-mapped sample types in P0 order, then the writer's
    /// workout-attachment set (workout, energy, ALL distance buckets) in
    /// cleanup-table order. A type can only hold app-written samples if
    /// share was requested for it — deriving (not hand-listing) means a
    /// future P0 addition or distance bucket lands in both the share
    /// sheet and the wipe, or neither. Deterministic order (never a Set
    /// round-trip): progress rows and tests read this sequence.
    /// Types this app has EVER requested share for (round-6 item 14) —
    /// frozen at the v1 request set. The wipe covers request ∪ history:
    /// narrowing `p0Types` later (or a revoked grant today) can never
    /// strand previously-written samples outside the wipe with no
    /// ledger row. Pass a narrowed `requesting` list to prove it (the
    /// historical floor still wipes); production uses the default.
    static let historicalRequestTypes: [GoogleDataType] = [.steps, .heartRate, .weight, .sleep]

    static func wipeableTypes(requesting: [GoogleDataType] = AppEnvironment.p0Types) throws -> [HKSampleType] {
        // Membership comes from the shared share-set computation (F10):
        // whatever onboarding authorizes, the wipe covers — no parallel
        // source to drift. Order is imposed here (request order, then
        // historical, then the writer-table order) because no source
        // promises sequence.
        let auth = HealthKitAuth()
        let current = try auth.authorizedShareTypes(
            sharing: requesting,
            includingWorkoutShare: true
        )
        let historical = try auth.authorizedShareTypes(
            sharing: historicalRequestTypes,
            includingWorkoutShare: true
        )
        let allowed = current.union(historical)
        var ordered: [HKSampleType] = []
        var seen = Set<HKSampleType>()
        func take(_ type: HKSampleType) {
            if allowed.contains(type), seen.insert(type).inserted {
                ordered.append(type)
            }
        }
        for dataType in requesting {
            take(try auth.resolveSampleType(for: dataType))
        }
        for dataType in historicalRequestTypes {
            take(try auth.resolveSampleType(for: dataType))
        }
        take(HKObjectType.workoutType())
        if let energy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) {
            take(energy)
        }
        for identifier in HealthKitWriter.distanceIdentifiersForCleanup {
            if let distance = HKObjectType.quantityType(forIdentifier: identifier) {
                take(distance)
            }
        }
        return ordered
    }
}

extension HealthKitSourceDeleter {
    /// Human-readable type bucket for the wipe ledger (F5). Covers the
    /// derived wipe set; anything else renders a fail-safe generic —
    /// never an enum-debug string in user-facing copy.
    static func displayName(for type: HKObjectType) -> String {
        if type == HKObjectType.workoutType() { return "workouts" }
        if type == HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { return "sleep" }
        let quantities: [(HKQuantityTypeIdentifier, String)] = [
            (.stepCount, "steps"),
            (.distanceWalkingRunning, "walking and running distance"),
            (.distanceCycling, "cycling distance"),
            (.distanceSwimming, "swimming distance"),
            (.distanceRowing, "rowing distance"),
            (.distanceWheelchair, "wheelchair distance"),
            (.distanceDownhillSnowSports, "downhill distance"),
            (.distanceCrossCountrySkiing, "skiing distance"),
            (.activeEnergyBurned, "active energy"),
            (.heartRate, "heart rate"),
            (.restingHeartRate, "resting heart rate"),
            (.heartRateVariabilitySDNN, "heart rate variability"),
            (.bodyMass, "weight"),
            (.oxygenSaturation, "blood oxygen"),
            (.respiratoryRate, "respiratory rate"),
        ]
        for (identifier, name) in quantities {
            if type == HKObjectType.quantityType(forIdentifier: identifier) {
                return name
            }
        }
        return "health data"
    }
}

enum HealthKitDeleteError: Error {
    /// `delete` reported failure without an error. Defensive: the API
    /// contract pairs `success == false` with an error, but the wipe must
    /// not treat silent-false as success.
    case deleteReturnedFalse
    /// Share access missing for the type: fail the type fast instead of
    /// issuing a query that may never call back.
    case notAuthorized
}
