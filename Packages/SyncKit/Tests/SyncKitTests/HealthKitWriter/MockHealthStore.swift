// MockHealthStore.swift
//
// WP-08 (implementation-plan.md) "Tests:" line: "with a mock store ... batch
// grouping, dedupe diff logic, delete-by-externalID targets only requested
// IDs." This is that mock -- a `HealthStoreProtocol` conformer backed by a
// plain in-memory array, requiring no HealthKit entitlement, no simulator,
// and no real `HKHealthStore` at all.
//
// See HealthStoreProtocol.swift's header ("Why this protocol does *not* pass
// raw NSPredicate/HKQuery through") for why this mock implements each
// operation's *semantics* directly (date-window overlap, metadata-key
// presence, an explicit `isAppWritten` flag standing in for `HKSource`, which
// has no public initializer a test could use to fabricate a "foreign app")
// rather than attempting to evaluate real HealthKit predicates against its
// own storage.

#if canImport(HealthKit)
import Foundation
import HealthKit
@testable import SyncKit

/// Records every call it receives (for "one save call per batch, not per
/// sample" / "delete targets only the requested IDs" assertions) and answers
/// queries against a plain in-memory list of samples -- no HealthKit store,
/// no entitlement.
final class MockHealthStore: HealthStoreProtocol, @unchecked Sendable {
    /// Every batch passed to `save(_:)`, in call order. A correct caller that
    /// batches properly (WP-08 step 3) produces exactly one entry per page;
    /// `.count` after a single `save(batchOfN)` call must be `1`, not `N`.
    private(set) var savedBatches: [[HKObject]] = []

    /// Every `deleteObjects(ofType:externalIDs:)` call received, in order --
    /// lets a test assert *which* IDs/types were actually requested, not just
    /// the resulting count.
    private(set) var deleteObjectsCalls: [(objectType: HKObjectType, externalIDs: Set<String>)] = []

    /// Every `deleteAllAppData(ofType:)` call received, in order.
    private(set) var deleteAllAppDataCalls: [HKObjectType] = []

    /// If set, the next call to the matching method throws this error instead
    /// of performing its normal in-memory operation -- lets tests exercise
    /// `HealthKitWriter`'s error propagation without needing a real HK failure.
    var saveError: HealthKitWriterError?
    var existingExternalIDsError: HealthKitWriterError?
    var appWrittenSampleRecordsError: HealthKitWriterError?
    var deleteObjectsError: HealthKitWriterError?
    var deleteAllAppDataError: HealthKitWriterError?

    /// One entry per sample currently "in the store". `isAppWritten` stands
    /// in for HealthKit's real per-object `HKSource` attribution (which a
    /// test process cannot fabricate -- see this file's header) so
    /// `deleteAllAppData` tests can seed both "this app wrote it" and
    /// "some other app/Apple Health wrote it" fixtures and assert the latter
    /// survives.
    private(set) var entries: [(sample: HKSample, isAppWritten: Bool)] = []

    init() {}

    /// Seed a sample directly into the store, bypassing `save(_:)` -- for
    /// setting up "already present" / "foreign, non-app-written" fixtures
    /// before exercising the method under test.
    func seed(_ sample: HKSample, isAppWritten: Bool) {
        entries.append((sample, isAppWritten))
    }

    /// Test-only inspection helper (not part of `HealthStoreProtocol`): how
    /// many samples of `objectType` remain in the store right now.
    func sampleCount(ofType objectType: HKObjectType) -> Int {
        entries.count { $0.sample.sampleType == objectType }
    }

    // MARK: - HealthStoreProtocol

    func save(_ objects: [HKObject]) async throws(HealthKitWriterError) {
        if let saveError {
            self.saveError = nil
            throw saveError
        }
        savedBatches.append(objects)
        for object in objects {
            guard let sample = object as? HKSample else { continue }
            entries.append((sample, true))
        }
    }

    func existingExternalIDs(
        ofType sampleType: HKSampleType,
        start: Date,
        end: Date
    ) async throws(HealthKitWriterError) -> Set<String> {
        if let existingExternalIDsError {
            self.existingExternalIDsError = nil
            throw existingExternalIDsError
        }
        // Mirrors HKQuery's default (no strict-start/end options) date-range
        // semantics: sample.startDate < end && sample.endDate > start, i.e.
        // interval overlap with [start, end] -- see HealthKitStore's real
        // adapter (HealthStoreProtocol.swift) for the same predicate applied
        // against a real store.
        let matching = entries.filter { entry in
            entry.sample.sampleType == sampleType
                && entry.sample.startDate < end
                && entry.sample.endDate > start
                && entry.sample.metadata?[HKMetadataKeyExternalUUID] != nil
        }
        return Set(matching.compactMap { $0.sample.metadata?[HKMetadataKeyExternalUUID] as? String })
    }

    /// WP-12b: mirrors `HealthKitStore.appWrittenSampleRecords`'s semantics
    /// against the in-memory list -- same date-overlap rule as
    /// `existingExternalIDs` above, plus the `isAppWritten` flag standing in
    /// for the real adapter's `HKSource.default()` predicate (see this
    /// file's header).
    func appWrittenSampleRecords(
        ofType sampleType: HKSampleType,
        start: Date,
        end: Date
    ) async throws(HealthKitWriterError) -> [AppWrittenSampleRecord] {
        if let appWrittenSampleRecordsError {
            self.appWrittenSampleRecordsError = nil
            throw appWrittenSampleRecordsError
        }
        return entries.compactMap { entry in
            guard entry.isAppWritten,
                  entry.sample.sampleType == sampleType,
                  entry.sample.startDate < end,
                  entry.sample.endDate > start,
                  let externalID = entry.sample.metadata?[HKMetadataKeyExternalUUID] as? String
            else { return nil }
            return AppWrittenSampleRecord(
                externalID: externalID,
                start: entry.sample.startDate,
                end: entry.sample.endDate
            )
        }
    }

    @discardableResult
    func deleteObjects(
        ofType objectType: HKObjectType,
        externalIDs: Set<String>
    ) async throws(HealthKitWriterError) -> Int {
        deleteObjectsCalls.append((objectType, externalIDs))
        if let deleteObjectsError {
            self.deleteObjectsError = nil
            throw deleteObjectsError
        }
        guard !externalIDs.isEmpty else { return 0 }
        let before = entries.count
        entries.removeAll { entry in
            guard entry.sample.sampleType == objectType else { return false }
            guard let id = entry.sample.metadata?[HKMetadataKeyExternalUUID] as? String else { return false }
            return externalIDs.contains(id)
        }
        return before - entries.count
    }

    /// Same keep-the-first rule as the real adapter
    /// (`HealthKitStore.duplicateCopies`), over app-written entries.
    @discardableResult
    func deleteDuplicateAppWrites(ofType sampleType: HKSampleType) async throws(HealthKitWriterError) -> Int {
        let candidates = entries.filter { $0.isAppWritten && $0.sample.sampleType == sampleType }.map(\.sample)
        let extras = Set(HealthKitStore.duplicateCopies(in: candidates).map(ObjectIdentifier.init))
        let before = entries.count
        entries.removeAll { extras.contains(ObjectIdentifier($0.sample)) }
        return before - entries.count
    }

    @discardableResult
    func deleteAllAppData(ofType objectType: HKObjectType) async throws(HealthKitWriterError) -> Int {
        deleteAllAppDataCalls.append(objectType)
        if let deleteAllAppDataError {
            self.deleteAllAppDataError = nil
            throw deleteAllAppDataError
        }
        let before = entries.count
        entries.removeAll { entry in
            entry.sample.sampleType == objectType && entry.isAppWritten
        }
        return before - entries.count
    }
}
#endif
