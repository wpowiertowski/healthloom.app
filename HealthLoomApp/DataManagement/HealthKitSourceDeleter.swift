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
import HealthKit

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
    /// Every HealthKit type this app can write (the sync writer's
    /// destination set). One list, shared by the wipe — a newly writable
    /// type added here is automatically covered by deletion.
    static let appWritableTypes: [HKObjectType] = [
        HKObjectType.quantityType(forIdentifier: .stepCount),
        HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning),
        HKObjectType.quantityType(forIdentifier: .activeEnergyBurned),
        HKObjectType.quantityType(forIdentifier: .heartRate),
        HKObjectType.quantityType(forIdentifier: .restingHeartRate),
        HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN),
        HKObjectType.quantityType(forIdentifier: .bodyMass),
        HKObjectType.quantityType(forIdentifier: .oxygenSaturation),
        HKObjectType.quantityType(forIdentifier: .respiratoryRate),
        HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
        HKObjectType.workoutType(),
    ].compactMap { $0 }
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
