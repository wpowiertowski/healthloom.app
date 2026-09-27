// HealthStoreProtocol.swift
//
// WP-08 (implementation-plan.md) step 1 / architecture.md §4 D2, D4, D13.
// The critical seam this WP exists to build: with all real `HKHealthStore`
// access behind this protocol, `HealthKitWriter` (HealthKitWriter.swift) can
// be driven by a mock in unit tests (no HealthKit entitlement needed — see
// Tests/SyncKitTests/HealthKitWriter/MockHealthStore.swift) *and* by
// `SyncEngine` (WP-09, next) against the real store in production, without
// SyncEngine's own tests ever touching a real `HKHealthStore`.
//
// Guarded with #if canImport(HealthKit) per the WP-06/WP-07 platform
// boundary this package established — see HealthKitAuth.swift's header for
// the detailed rationale. (On this repo's current macOS development host,
// HealthKit happens to be importable and every API this file calls is safe
// without an entitlement — WP-06/07 both confirmed this — but the guard is
// kept anyway as the portable boundary the brief asks for.)
//
// ## Why this protocol does *not* pass raw NSPredicate/HKQuery through
//
// implementation-plan.md's WP-08 sketch mentions
// `HKQuery.predicateForObjects(withMetadataKey:allowedValues:)` directly, and
// an earlier draft of this file took that literally: a protocol method
// shaped like `samples(ofType:matching predicate: NSPredicate) -> [HKSample]`.
// That does not actually give a usable test seam. HealthKit's predicate
// factory methods (`HKQuery.predicateForSamples(withStart:end:options:)`,
// `.predicateForObjects(withMetadataKey:)`, `.predicateForObjects(from:)`, …)
// return opaque, HealthKit-private `NSPredicate` subclasses that only a real
// `HKHealthStore`'s query engine knows how to evaluate — calling
// `.evaluate(with:)` on them directly against an in-memory array (what a mock
// would need to do) is undefined/unsupported. Worse, `HKSource` has no public
// initializer, so a mock could never construct a "foreign app's" source to
// prove delete-by-source *doesn't* touch it, since every object a test
// process constructs reports the same `HKSource.default()`.
//
// So this protocol is deliberately shaped one level higher: each method
// describes *what* HealthKit-semantic operation is needed (existence-by-
// window, delete-by-external-ID, delete-by-this-app's-own-writes) rather than
// *how* to query for it. `HealthKitStore` (this file, below) is the only
// place that builds the real `HKQuery` predicates; `MockHealthStore` (test
// target) implements the identical semantics against its own in-memory
// bookkeeping using plain Swift filtering — no predicate evaluation, no fake
// `HKSource`, and both conform to exactly the same protocol so
// `HealthKitWriter`'s own logic (HealthKitWriter.swift) never needs to know
// which one it's talking to.
#if canImport(HealthKit)
import HealthKit

/// Abstracts every `HKHealthStore` operation `HealthKitWriter` needs: save,
/// batched existence-check, delete-by-external-ID, delete-by-app-source.
///
/// Conforming types: `HealthKitStore` (below — the real `HKHealthStore`
/// adapter) for production, and `MockHealthStore` (test target only) for
/// unit tests that must run without a HealthKit entitlement.
public protocol HealthStoreProtocol: Sendable {
    /// Save every object in `objects` with exactly **one** underlying
    /// HealthKit save call (architecture.md D4: "batched... never one query
    /// per sample" — the same invariant applies to writes, not just existence
    /// checks). Callers should not call this once per sample; `objects` *is*
    /// the batch/page.
    func save(_ objects: [HKObject]) async throws(HealthKitWriterError)

    /// The `healthloom`-stamped external IDs (`HKMetadataKeyExternalUUID`,
    /// architecture.md D4) of every sample of `sampleType` whose date range
    /// intersects `[start, end]`, collected with exactly **one** underlying
    /// query — never one query per sample, per D4's core invariant. Callers
    /// diff their incoming page against this set in memory (WP-09's job).
    func existingExternalIDs(
        ofType sampleType: HKSampleType,
        start: Date,
        end: Date
    ) async throws(HealthKitWriterError) -> Set<String>

    /// Every app-written, `healthloom`-stamped sample of `sampleType` whose
    /// date range intersects `[start, end]`, returned with its external ID
    /// *and* interval (WP-12b / architecture.md D13.4's retroactive conflict
    /// cleanup -- it must test each written sample's interval against the
    /// current watch-coverage index, which the ID-set-only
    /// `existingExternalIDs` above can't support). Same single-query
    /// invariant and same predicate scope (date window + external-ID
    /// metadata + this app's own source) as `existingExternalIDs`.
    func appWrittenSampleRecords(
        ofType sampleType: HKSampleType,
        start: Date,
        end: Date
    ) async throws(HealthKitWriterError) -> [AppWrittenSampleRecord]

    /// Delete every object of `objectType` whose `HKMetadataKeyExternalUUID`
    /// metadata value is a member of `externalIDs`. Deletes nothing else —
    /// in particular, samples of the same type with a different (or no)
    /// external ID are left untouched. Returns the number of objects actually
    /// deleted. Used for "update" (delete-by-external-ID + re-insert, since
    /// HK samples are immutable — architecture.md D4) and D13.4's retroactive
    /// conflict cleanup.
    @discardableResult
    func deleteObjects(
        ofType objectType: HKObjectType,
        externalIDs: Set<String>
    ) async throws(HealthKitWriterError) -> Int

    /// Delete every object of `objectType` this app itself wrote — "delete-
    /// by-source" (architecture.md D4 / WP-35's disconnect-and-wipe flow).
    /// The real adapter scopes this to `HKSource.default()` (the running
    /// app); test doubles use their own bookkeeping of which entries were
    /// written via `save(_:)` on themselves. Returns the number deleted.
    @discardableResult
    func deleteAllAppData(
        ofType objectType: HKObjectType
    ) async throws(HealthKitWriterError) -> Int
}

/// The real `HealthStoreProtocol` adapter: every method here is a thin,
/// direct translation into `HKHealthStore`/`HKQuery` calls, with zero
/// business logic of its own (that lives in `HealthKitWriter`, which is the
/// public type app/`SyncEngine` code actually holds).
public final class HealthKitStore: HealthStoreProtocol, Sendable {
    private let healthStore: HKHealthStore

    /// `HKHealthStore` is `Sendable` and Apple's own guidance is one store
    /// per app (same "share one instance" posture as `HealthKitAuth` —
    /// HealthKitAuth.swift). Defaults to a fresh store for convenience;
    /// production call sites that already hold a `HealthKitAuth`-owned store
    /// may inject it here instead so both DI'd types share the same instance.
    public init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    public func save(_ objects: [HKObject]) async throws(HealthKitWriterError) {
        guard !objects.isEmpty else { return }
        do {
            try await healthStore.save(objects)
        } catch {
            throw HealthKitWriterError(wrapping: error)
        }
    }

    /// **Existence-query strategy** (see this file's header for the design
    /// rationale, and progress.md's WP-08 entry for the full writeup):
    /// combines HealthKit's date-range predicate
    /// (`HKQuery.predicateForSamples(withStart:end:options:)`), a metadata-
    /// key-*existence* predicate (`HKQuery.predicateForObjects(
    /// withMetadataKey: HKMetadataKeyExternalUUID)` — no `allowedValues:`,
    /// since this method's signature is a time window, not a candidate ID
    /// list) and a same-app-source predicate (`HKQuery.predicateForObjects(
    /// from: .default())`) into one `NSCompoundPredicate`, run through
    /// exactly **one** `HKSampleQuery` (limit `HKObjectQueryNoLimit`) — this
    /// is architecture.md D4's "one HK query per (type, time window)"
    /// invariant, met literally. The external-ID values themselves are then
    /// read out of each returned sample's metadata client-side (there is no
    /// way to have HealthKit return "just the metadata values" without
    /// fetching the samples). The `allowedValues:` predicate form the WP-08
    /// brief also suggests trying is used instead in `deleteObjects(
    /// ofType:externalIDs:)` below, where a concrete candidate-ID set already
    /// exists to pass as `allowedValues:` — see that method's doc comment.
    public func existingExternalIDs(
        ofType sampleType: HKSampleType,
        start: Date,
        end: Date
    ) async throws(HealthKitWriterError) -> Set<String> {
        let datePredicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let metadataPredicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID)
        let sourcePredicate = HKQuery.predicateForObjects(from: .default())
        let compound = NSCompoundPredicate(
            andPredicateWithSubpredicates: [datePredicate, metadataPredicate, sourcePredicate]
        )
        let samples = try await querySamples(ofType: sampleType, matching: compound)
        return Set(samples.compactMap { $0.metadata?[HKMetadataKeyExternalUUID] as? String })
    }

    /// Identical predicate strategy (and single-query invariant) as
    /// `existingExternalIDs(ofType:start:end:)` above -- the only difference
    /// is what's read out of each returned sample: the external ID *plus*
    /// its own start/end dates, for WP-12b's retroactive cleanup to test
    /// against the current watch-coverage index (architecture.md D13.4).
    public func appWrittenSampleRecords(
        ofType sampleType: HKSampleType,
        start: Date,
        end: Date
    ) async throws(HealthKitWriterError) -> [AppWrittenSampleRecord] {
        let datePredicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let metadataPredicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID)
        let sourcePredicate = HKQuery.predicateForObjects(from: .default())
        let compound = NSCompoundPredicate(
            andPredicateWithSubpredicates: [datePredicate, metadataPredicate, sourcePredicate]
        )
        let samples = try await querySamples(ofType: sampleType, matching: compound)
        return samples.compactMap { sample in
            guard let externalID = sample.metadata?[HKMetadataKeyExternalUUID] as? String else { return nil }
            return AppWrittenSampleRecord(externalID: externalID, start: sample.startDate, end: sample.endDate)
        }
    }

    /// Uses `HKQuery.predicateForObjects(withMetadataKey:allowedValues:)` —
    /// the exact predicate form the WP-08 brief names — because here, unlike
    /// `existingExternalIDs(ofType:start:end:)` above, the caller already has
    /// a concrete candidate set (`externalIDs`) to test for, so HealthKit can
    /// do the membership filtering server-side in the same single query
    /// rather than this method fetching every sample in some date window and
    /// filtering client-side. No date window is needed at all: an external ID
    /// uniquely identifies (at most) one sample regardless of when it falls,
    /// which is exactly what D13.4's retroactive cleanup needs (it deletes
    /// specific now-conflicting samples that may be anywhere in the lookback
    /// window, not a single contiguous range).
    @discardableResult
    public func deleteObjects(
        ofType objectType: HKObjectType,
        externalIDs: Set<String>
    ) async throws(HealthKitWriterError) -> Int {
        guard !externalIDs.isEmpty else { return 0 }
        let predicate = HKQuery.predicateForObjects(
            withMetadataKey: HKMetadataKeyExternalUUID,
            allowedValues: Array(externalIDs)
        )
        do {
            return try await healthStore.deleteObjects(of: objectType, predicate: predicate)
        } catch {
            throw HealthKitWriterError(wrapping: error)
        }
    }

    @discardableResult
    public func deleteAllAppData(
        ofType objectType: HKObjectType
    ) async throws(HealthKitWriterError) -> Int {
        let predicate = HKQuery.predicateForObjects(from: .default())
        do {
            return try await healthStore.deleteObjects(of: objectType, predicate: predicate)
        } catch {
            throw HealthKitWriterError(wrapping: error)
        }
    }

    // MARK: - Private

    /// Bridges the completion-handler-based `HKSampleQuery` (still the only
    /// query type that works generically across both `HKQuantityType` and
    /// `HKCategoryType` `HKSampleType`s from a single call site — the newer
    /// `HKSampleQueryDescriptor<Sample>` requires a *concrete* `Sample:
    /// HKSample` generic parameter fixed at compile time, which doesn't fit
    /// this method's runtime-erased `HKSampleType` parameter) into
    /// async/await.
    private func querySamples(
        ofType sampleType: HKSampleType,
        matching predicate: NSPredicate
    ) async throws(HealthKitWriterError) -> [HKSample] {
        do {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKSample], Error>) in
                let query = HKSampleQuery(
                    sampleType: sampleType,
                    predicate: predicate,
                    limit: HKObjectQueryNoLimit,
                    sortDescriptors: nil
                ) { _, samples, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: samples ?? [])
                    }
                }
                healthStore.execute(query)
            }
        } catch {
            throw HealthKitWriterError(wrapping: error)
        }
    }
}
extension HealthKitWriterError {
    /// Wraps a HealthKit failure, classifying the locked-device refusal
    /// (`HKError.errorDatabaseInaccessible`) as `.protectedDataUnavailable`
    /// so it can't reach the Sync Log as an opaque error string. Every
    /// HealthKit call site in the writer wraps through here.
    init(wrapping error: any Error) {
        let nsError = error as NSError
        if nsError.domain == HKErrorDomain, nsError.code == HKError.Code.errorDatabaseInaccessible.rawValue {
            self = .protectedDataUnavailable
        } else {
            self = .underlying(String(describing: error))
        }
    }
}

#endif
