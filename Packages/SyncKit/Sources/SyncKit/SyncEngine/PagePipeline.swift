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

    /// Dedupe for one mapped arm (round-7 item 3): skip iff the
    /// point's base ID is known (legacy pre-suffix rows carry the bare
    /// point ID) or EVERY emitted UUID is known (re-syncs reproduce
    /// expansion UUIDs exactly, so the full set matches). Partial
    /// presence is unreachable — batch saves are atomic — so no
    /// per-sample subset writes: a simple all-check suffices.
    private static func isKnown(baseID: String, uuids: [String], in known: Set<String>) -> Bool {
        known.contains(baseID) || uuids.allSatisfy(known.contains)
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
    /// own executor. On a throwing page, throws `PageWalkPartial`
    /// (instead of the raw page error) carrying whatever was processed
    /// before the failure — the runs' informational-count contract
    /// (partial progress reported on failed runs) survives the
    /// extraction. Callers add `partial.total` to their count and
    /// rethrow `partial.underlying` (which preserves cancellation
    /// identity for the stop-not-failure branches).
    func processPages(
        knownExternalIDs: Set<String>,
        fetch: @Sendable (String?) async throws -> Page
    ) async throws -> (total: Int, localOnly: [GoogleDataPoint], hitPageCap: Bool) {
        var known = knownExternalIDs
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
                let processed = try await processPage(page.points, knownExternalIDs: &known)
                total += processed.itemCount
                localOnly += processed.localOnlyPoints
                pages += 1
                guard let next = page.nextPageToken, next != token else { break }
                token = next
            } catch {
                throw PageWalkPartial(total: total, underlying: error)
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
        knownExternalIDs: inout Set<String>
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
                guard !Self.isKnown(baseID: point.id, uuids: [Self.emittedUUID(of: sample)].compactMap({ $0 }), in: known) else { continue }
                known.insert(point.id)
                batch.append(sample)
                writtenCount += 1
            case .quantities(let samples):
                // A cumulative sample split at watch-coverage edges
                // (architecture.md D13.3) — N part samples for one point,
                // each with its own derived UUID (round-7 item 3). One
                // point, one itemCount contribution.
                guard !Self.isKnown(baseID: point.id, uuids: samples.compactMap(Self.emittedUUID), in: known) else { continue }
                known.insert(point.id)
                batch.append(contentsOf: samples)
                writtenCount += 1
            case .category(let samples):
                guard !Self.isKnown(baseID: point.id, uuids: samples.compactMap(Self.emittedUUID), in: known) else { continue }
                known.insert(point.id)
                batch.append(contentsOf: samples)
                writtenCount += 1
            case .correlation(let correlation):
                // An `HKCorrelation` is itself a plain
                // `HKObject`/`HKSample` built synchronously by
                // `TypeMapper.map(_:)` — same batch/existence-diff path
                // as every other arm, no parallel mechanism.
                guard !Self.isKnown(baseID: point.id, uuids: [Self.emittedUUID(of: correlation)].compactMap({ $0 }), in: known) else { continue }
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
    static func upsertLocalSample(for point: GoogleDataPoint, context: ModelContext) {
        let externalID = point.id
        let payload = SharedLocalPayload(point: point)
        let payloadJSON = (try? JSONEncoder().encode(payload)) ?? Data()
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
struct PageWalkPartial: Error {
    var total: Int
    var underlying: any Error
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
