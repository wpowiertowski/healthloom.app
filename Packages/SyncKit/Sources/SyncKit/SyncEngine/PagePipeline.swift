// PagePipeline.swift
//
// Shared page pipeline (round-4-sync item 15): the pull→map→write/upsert
// core `SyncEngine.processPage` and `BackfillCoordinator.processPage`
// duplicated verbatim (~140 lines each; drift had already started —
// comment-only divergence today, logic divergence tomorrow). ONE
// implementation used by BOTH: points + knownExternalIDs in,
// `PageProcessing` out. Round-4-sync item 6's within-page
// check-then-insert lives here — fixed once, both engines inherit.
//
// Isolation boundary, stated exactly: `ModelContext` is executor-bound,
// so the pipeline never takes one. `processPage` maps, filters, batches,
// and writes (all `Sendable` values plus `await`ed MainActor deps) and
// returns the `.localOnly` points for the CALLER to upsert on its own
// executor via the static helpers below (both `sync`, so they run where
// the caller runs). `PagePipeline` itself is stateless + `Sendable` —
// each engine constructs one per call from deps it already holds, so no
// init changes were needed on either side.

#if canImport(HealthKit)
import CoreModel
import Foundation
import GoogleHealthClient
import HealthKit
import SwiftData

/// What one page produced: the count contract is WP-09's, unchanged —
/// one Google data point contributes exactly once (written, upserted, or
/// skipped); a multi-sample expansion still counts one.
nonisolated struct PageProcessing: Sendable {
    /// External IDs newly written to HealthKit this page (count only —
    /// the shared set already absorbed them; see `processPage`).
    var writtenCount: Int
    /// Points the caller must upsert via `upsertLocalSample` (its own
    /// executor) before counting this page done.
    var localOnlyPoints: [GoogleDataPoint]
    var workoutCount: Int
    var skipCount: Int
    var itemCount: Int {
        writtenCount + workoutCount + localOnlyPoints.count + skipCount
    }
}

nonisolated struct PagePipeline: Sendable {
    /// Maximum pages per walk (round-6 item 8): a legitimate window
    /// never approaches this; beyond it the server is echoing or the
    /// window is pathological — stop with partial progress kept.
    static let maxPages = 100

    /// Dedupe for one mapped arm (round-7 item 3 + fix-round F1): skip
    /// iff the point's base ID is known (legacy pre-suffix rows carry
    /// the bare point ID), or its split parts are known (the flip-flop
    /// direction), or EVERY emitted UUID is known (re-syncs reproduce
    /// expansion UUIDs exactly). Partial presence is unreachable —
    /// batch saves are atomic — so no per-sample subset writes.
    ///
    /// The `'#'` separator is reserved by CONVENTION (round-7 fix F1,
    /// softened per fix-round N2): wire IDs observed to date contain
    /// no `'#'`, but that is asserted, not pinned — a future ID shape
    /// containing it would false-skip (under-write) here, so any ID
    /// shape change must add a pinning test alongside it.
    /// `splitBases` is computed once per page from the queried set
    /// (in-page inserts are base IDs, already covered by the base
    /// leg) — not scanned per point.
    ///
    /// ONE coherent unstamped-sample rule (round-9 items 4+6+9+11):
    /// callers enforce UUID presence via `checkedUUIDs` BEFORE
    /// reaching here (unstamped members throw — fail loud, item-13
    /// doctrine — never silently written every sync, never silently
    /// dropped). So this function never observes an empty set from
    /// production paths; the single expression below folds every leg
    /// with no special case to diverge later.
    private static func isKnown(
        baseID: String,
        uuids: [String],
        splitBases: Set<String>,
        in known: Set<String>
    ) -> Bool {
        known.contains(baseID) || splitBases.contains(baseID) || (!uuids.isEmpty && uuids.allSatisfy(known.contains))
    }

    /// Emitted UUIDs or throw (round-9 items 4+6): every sample the
    /// pipeline is about to count must carry the stamp the existence
    /// set is queried by — otherwise it is undedupable (rewritten
    /// every sync, or dropped and never revisited). Throws the
    /// dedicated `UnstampedSample` error LOUDLY, so the run fails with
    /// the offending point identified, the cursor unmoved, and the
    /// window retried. Internal so the unit test pins it directly
    /// (unreachable through `processPage` — every emitter stamps —
    /// which is exactly why it needs its own pin).
    /// Workout-spec stamp gate (round-10 item 9): the `.workout` arm's
    /// equivalent of `checkedUUIDs` — the spec must carry exactly the
    /// point's base UUID (workout-level metadata keeps the base, never
    /// a suffix). Internal so the unit test pins it directly
    /// (unreachable through `processPage` — the mapper always stamps
    /// `point.id` — which is exactly why it needs its own pin).
    static func checkedWorkoutUUID(_ workout: MappedWorkout, baseID: String) throws {
        guard workout.metadata.externalUUID == baseID else {
            throw UnstampedSample(pointID: baseID)
        }
    }

    static func checkedUUIDs<T: HKObject>(_ objects: [T], baseID: String) throws -> [String] {
        let uuids = objects.compactMap(emittedUUID)
        guard uuids.count == objects.count else {
            throw UnstampedSample(pointID: baseID)
        }
        return uuids
    }

    private static func emittedUUID(of object: HKObject) -> String? {
        object.metadata?[HKMetadataKeyExternalUUID] as? String
    }

    let conflictFilter: any ConflictFiltering
    let writer: HealthKitWriter

    /// Bounded multi-page walk over a page fetcher (round-6 item 8):
    /// BOTH engines' repeat-while-pageToken loops route through here.
    /// Same-token-break (an echoing server returning its own token
    /// forever spins burning quota — foreground Sync Now was
    /// unstoppable), the page cap above, and a cancellation probe per
    /// page (a cancelled walk throws into the callers' existing
    /// stop-not-failure catches). The existence set threads through
    /// the walk internally and never escapes: a throwing page
    /// discards it exactly like the old per-page commit (which never
    /// escaped a failed run either — retries re-query fresh).
    /// `.localOnly` points accumulate for the CALLER to upsert on its
    /// own executor — and that confinement is why `.localOnly` points
    /// ACCUMULATE here instead of committing per page (round-10 item
    /// 14): this pipeline resumes off-actor after its awaits, and
    /// `ModelContext` is not thread-safe, so context writes stay with
    /// the caller. The accumulation is bounded by the page cap above
    /// and points are small value types — a deliberate trade, stated
    /// here instead of hidden. On a throwing page, throws
    /// `PageWalkPartial` (instead of the raw page error) carrying the
    /// completed pages' count AND their `.localOnly` points — callers
    /// upsert those rows on their own executor (committing completed
    /// pages even on failure) and unwrap `partial.underlying` for the
    /// cancellation identity the stop-not-failure branches need.
    func processPages(
        knownExternalIDs: Set<String>,
        fetch: @Sendable (String?) async throws -> Page
    ) async throws -> (total: Int, localOnly: [GoogleDataPoint], hitPageCap: Bool) {
        // Round-7 fix F1: base IDs with STORED split parts, derived
        // once from the queried set (in-page inserts are base IDs,
        // already covered by the base leg — see `isKnown`).
        var known = knownExternalIDs
        let splitBases: Set<String> = Set(knownExternalIDs.compactMap { uuid in
            uuid.firstIndex(of: "#").map { String(uuid[..<$0]) }
        })
        var total = 0
        var localOnly: [GoogleDataPoint] = []
        var token: String? = nil
        var pages = 0
        var hitPageCap = false
        while true {
            try Task.checkCancellation()
            if pages >= Self.maxPages {
                hitPageCap = true
                break
            }
            do {
                let page = try await fetch(token)
                let processed = try await processPage(page.points, knownExternalIDs: &known, splitBases: splitBases)
                total += processed.itemCount
                localOnly += processed.localOnlyPoints
                pages += 1
                guard let next = page.nextPageToken, next != token else { break }
                token = next
            } catch {
                throw PageWalkPartial(total: total, localOnly: localOnly, underlying: error)
            }
        }
        return (total, localOnly, hitPageCap)
    }

    /// Maps, conflict-filters, batches, and writes/upserts every point in
    /// one page. `knownExternalIDs` is the per-(type, window) existence
    /// set, threaded by `inout` (never re-queried per page — D4's
    /// invariant); it is committed only on success (see below).
    ///
    /// Within-page duplicates (round-4-sync item 6): every arm
    /// check-then-INSERTS per point within the loop, so the same
    /// `point.id` twice in one page writes + counts once — the old shape
    /// (union only after the page save) double-wrote and double-counted,
    /// violating the exactly-once contract the header claims.
    ///
    /// Failure semantics, preserved exactly: the loop works on a LOCAL
    /// copy committed to the caller's set only after the batch save
    /// succeeds. A throwing save therefore leaves the caller's set
    /// untouched — same as the old post-save-union shape — so a retried
    /// window re-pulls the failed points instead of skipping them as
    /// "known". (The `.workout` arm saves directly per point, exactly as
    /// before: a workout written before a later throw stays written —
    /// the retry's fresh existence query finds it, same as before.)
    func processPage(
        _ points: [GoogleDataPoint],
        knownExternalIDs: inout Set<String>,
        splitBases: Set<String> = []
    ) async throws -> PageProcessing {
        var known = knownExternalIDs
        var batch: [HKObject] = []
        var writtenCount = 0
        var localOnlyPoints: [GoogleDataPoint] = []
        var skipCount = 0
        var workoutCount = 0

        for point in points {
            // `await`: `TypeMapper.map(_:)` is MainActor-isolated;
            // `conflictFilter.resolve` is declared `async` regardless of
            // isolation (SyncEngineTypes.swift).
            let mapped = await conflictFilter.resolve(await TypeMapper.map(point), for: point)
            switch mapped {
            case .quantity(let sample):
                let singleUUIDs = try Self.checkedUUIDs([sample], baseID: point.id)
                guard !Self.isKnown(baseID: point.id, uuids: singleUUIDs, splitBases: splitBases, in: known) else { continue }
                known.insert(point.id)
                batch.append(sample)
                writtenCount += 1
            case .quantities(let samples):
                // A cumulative sample split at watch-coverage edges
                // (architecture.md D13.3) — N part samples for one point,
                // each with its own derived UUID (round-7 item 3). One
                // point, one itemCount contribution.
                let pageUUIDs = try Self.checkedUUIDs(samples, baseID: point.id)
                guard !Self.isKnown(baseID: point.id, uuids: pageUUIDs, splitBases: splitBases, in: known) else { continue }
                known.insert(point.id)
                batch.append(contentsOf: samples)
                writtenCount += 1
            case .category(let samples):
                let pageUUIDs = try Self.checkedUUIDs(samples, baseID: point.id)
                guard !Self.isKnown(baseID: point.id, uuids: pageUUIDs, splitBases: splitBases, in: known) else { continue }
                known.insert(point.id)
                batch.append(contentsOf: samples)
                writtenCount += 1
            case .correlation(let correlation):
                // An `HKCorrelation` is itself a plain
                // `HKObject`/`HKSample` built synchronously by
                // `TypeMapper.map(_:)` — same batch/existence-diff path
                // as every other arm, no parallel mechanism.
                let correlationUUIDs = try Self.checkedUUIDs([correlation], baseID: point.id)
                guard !Self.isKnown(baseID: point.id, uuids: correlationUUIDs, splitBases: splitBases, in: known) else { continue }
                known.insert(point.id)
                batch.append(correlation)
                writtenCount += 1
            case .workout(let workout):
                // Unavoidably write-direct: `HKWorkoutBuilder`
                // saves the workout itself, so it never flows through
                // `writer.save(_:)` — but the idempotency *mechanism* is
                // identical (query-side existence diff, same set).
                // Anything reaching here already passed D13's conflict
                // resolution above.
                // Round-10 item 9: the same UUID-presence enforcement
                // as every other arm — the spec's stamp is what the
                // existence query matches post-save (workout-level
                // metadata keeps the BASE uuid), so a missing or
                // drifted stamp would rewrite every sync, silently
                // (the UnstampedSample-loud class). `checkedUUIDs`
                // reads built objects and the workout isn't built until
                // `saveWorkout`, so the equivalent gate runs on the
                // spec's stamp here (same error, same fail-loud).
                try Self.checkedWorkoutUUID(workout, baseID: point.id)
                guard !known.contains(point.id) else { continue }
                _ = try await writer.saveWorkout(workout)
                known.insert(point.id)
                workoutCount += 1
            case .localOnly:
                // Round-6 item 11: the same within-page gate as every
                // other arm — the old unconditional append upserted
                // twice and counted twice for a duplicated point,
                // contradicting this file's exactly-once contract
                // (the upsert itself is idempotent, so no corruption —
                // but the count lied and the write was wasted).
                guard !known.contains(point.id) else { continue }
                known.insert(point.id)
                localOnlyPoints.append(point)
            case .skip:
                skipCount += 1
            }
        }

        if !batch.isEmpty {
            try await writer.save(batch)
        }
        knownExternalIDs = known
        return PageProcessing(
            writtenCount: writtenCount,
            localOnlyPoints: localOnlyPoints,
            workoutCount: workoutCount,
            skipCount: skipCount
        )
    }

    /// Upserts by `externalID`: fetches any existing row first — never a
    /// blind reinsert — so `linkedWatchWorkoutUUID` (set later by WP-12b's
    /// conflict resolution, architecture.md D13.2) is never wiped back to
    /// `nil` by a routine re-sync re-touching the same point. `sync`: call
    /// on the executor that owns `context`.
    static func upsertLocalSample(for point: GoogleDataPoint, context: ModelContext) throws {
        let externalID = point.id
        let payload = SharedLocalPayload(point: point)
        // Round-8 item 13: encode failure (non-finite doubles) throws
        // LOUDLY — the old `(try? ...) ?? Data()` wrote a zero-byte
        // payload row that downstream readers choke on, while counting
        // the point and committing the cursor past it (never re-pulled:
        // unrecoverable). A throw fails the page → the run → the cursor
        // stays unmoved and the window retries (loud every run until
        // the data ages out or is fixed).
        let payloadJSON: Data
        do {
            payloadJSON = try JSONEncoder().encode(payload)
        } catch {
            throw UnencodableLocalPayload(pointID: point.id)
        }
        let sourceLabel = point.source.deviceDisplayName ?? point.source.platform ?? "unknown"
        let dataTypeKey = point.dataType.rawValue

        let descriptor = FetchDescriptor<LocalSample>(predicate: #Predicate { $0.externalID == externalID })
        if let existing = try? context.fetch(descriptor).first {
            existing.dataType = dataTypeKey
            existing.payloadJSON = payloadJSON
            existing.start = point.start
            existing.end = point.end
            existing.source = sourceLabel
        } else {
            context.insert(
                LocalSample(
                    externalID: externalID,
                    dataType: dataTypeKey,
                    payloadJSON: payloadJSON,
                    start: point.start,
                    end: point.end,
                    source: sourceLabel
                )
            )
        }
    }

    /// Stamps `LocalSample.linkedWatchWorkoutUUID` for every session the
    /// run's conflict filter deferred to a watch workout. Fetch-by-
    /// externalID sees rows `upsertLocalSample` inserted earlier in the
    /// same context (pending inserts are visible by default). A link
    /// whose row is missing is dropped silently — the window is fully
    /// re-pulled next run and the link re-recorded. `sync`: call on the
    /// executor that owns `context`.
    static func applyDeferredSessionLinks(_ links: [String: UUID], context: ModelContext) {
        guard !links.isEmpty else { return }
        for (externalID, workoutUUID) in links {
            let descriptor = FetchDescriptor<LocalSample>(predicate: #Predicate { $0.externalID == externalID })
            if let sample = try? context.fetch(descriptor).first {
                sample.linkedWatchWorkoutUUID = workoutUUID
            }
        }
    }
}

/// Partial progress from an interrupted page walk: the count processed
/// before the throwing page, plus the underlying error (rethrow target —
/// preserves cancellation identity and the redacted error row). Never
/// constructed outside `PagePipeline.processPages`.
/// Partial progress from a failed page walk (round-10 item 14): the
/// completed pages' count plus their `.localOnly` points, so callers
/// can commit those rows on their own executor even though the walk
/// failed. `underlying` is the page error (callers unwrap it for
/// cancellation identity — a bare `is CancellationError` check on the
/// wrapper itself would misclassify every cancelled walk as failed).
struct PageWalkPartial: Error {
    var total: Int
    var localOnly: [GoogleDataPoint]
    var underlying: any Error
}

/// Unencodable local payload (round-8 item 13): thrown when a point's
/// values cannot be encoded (non-finite doubles) — fails the page, the
/// run, and holds the cursor, instead of persisting a zero-byte row.
nonisolated struct UnencodableLocalPayload: Error, Sendable {
    var pointID: String
}

/// Unstamped sample (round-9 items 4+6): thrown when a sample the
/// pipeline is about to count carries no external-UUID stamp — fail
/// loud (item-13 doctrine), cursor unmoved, window retried.
nonisolated struct UnstampedSample: Error, Sendable {
    var pointID: String
}

/// Minimal, self-contained JSON shape for `LocalSample.payloadJSON` — the
/// field-identical union of `SyncEngine`'s `SyncEngineLocalPayload` and
/// `BackfillCoordinator`'s `BackfillLocalPayload` (same fields, same
/// order, so encoded bytes are unchanged — see the payload-shape test).
/// WP-14 owns the real per-type payload schema and may replace this shape
/// entirely; until then there is exactly one of it.
nonisolated struct SharedLocalPayload: Codable {
    var id: String
    var dataType: String
    var start: Date
    var end: Date
    var values: [String: Double]
    var sessionPayload: Data?
    var sourcePlatform: String?
    var sourceDeviceDisplayName: String?
    var sourceRecordingMethod: String?

    init(point: GoogleDataPoint) {
        self.id = point.id
        self.dataType = point.dataType.rawValue
        self.start = point.start
        self.end = point.end
        self.values = point.values
        self.sessionPayload = point.sessionPayload
        self.sourcePlatform = point.source.platform
        self.sourceDeviceDisplayName = point.source.deviceDisplayName
        self.sourceRecordingMethod = point.source.recordingMethod
    }
}
#endif
