// CoachSessionTests.swift
//
// WP-22 round-1 review: the cumulative-to-delta rule behind the protocol's
// streaming contract, tested as the pure static it is -- no session, no model.

import Foundation
import FoundationModels
import Testing

@testable import CoachKit

@Suite("LiveCoachSession.delta")
struct DeltaTests {
    @Test("extends-prefix yields only the new suffix")
    func prefixYieldsSuffix() {
        #expect(LiveCoachSession.delta(previous: "Hi", snapshot: "Hi there") == " there")
    }

    @Test("identical snapshots yield nothing")
    func identicalYieldsEmpty() {
        #expect(LiveCoachSession.delta(previous: "done", snapshot: "done") == "")
    }

    @Test("empty previous yields the whole snapshot")
    func emptyPreviousYieldsAll() {
        #expect(LiveCoachSession.delta(previous: "", snapshot: "Hello") == "Hello")
    }

    @Test("emoji ZWJ extension does not re-emit the response")
    func zwjExtension() {
        // U+1F468 MAN followed by a ZWJ family extension: grapheme-cluster
        // hasPrefix fails (the whole sequence is one cluster not prefixed by
        // "👨"). Scalar diff shares U+1F468 and yields only the ZWJ
        // continuation, which appends correctly.
        let previous = "Nice work \u{1F468}"
        let snapshot = "Nice work \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let delta = LiveCoachSession.delta(previous: previous, snapshot: snapshot)
        #expect(previous + delta == snapshot)
        #expect(delta == "\u{200D}\u{1F469}\u{200D}\u{1F467}")
    }

    @Test("combining-mark extension appends, not duplicates")
    func combiningMark() {
        // e + U+0301 COMBINING ACUTE (decomposed "café"): grapheme-cluster
        // hasPrefix fails, scalar diff shares "cafe" and yields the mark.
        let previous = "cafe"
        let snapshot = "cafe\u{301}"
        let delta = LiveCoachSession.delta(previous: previous, snapshot: snapshot)
        #expect(previous + delta == snapshot)
        #expect(delta == "\u{301}")
    }

    @Test("revision inside a multi-byte sequence never emits U+FFFD")
    func multibyteRevisionBoundary() {
        // a + U+0301 + x revised to a + U+0308 + x: the byte loop stops on
        // the differing continuation byte and must snap back to the lead
        // byte, or the delta starts mid-sequence and decodes to a replacement
        // character.
        let delta = LiveCoachSession.delta(previous: "a\u{301}x", snapshot: "a\u{308}x")
        #expect(!delta.contains("\u{FFFD}"))
        #expect(delta == "\u{308}x")
    }

    @Test("a shrinking snapshot yields nothing")
    func shrinkingYieldsEmpty() {
        // Delivered text can't be retracted under append semantics.
        #expect(LiveCoachSession.delta(previous: "Hello", snapshot: "Hel") == "")
    }

    @Test("joining deltas reproduces a streamed response")
    func deltasJoin() {
        let snapshots = ["H", "Hi", "Hi t", "Hi th", "Hi the", "Hi ther", "Hi there"]
        var previous = ""
        var joined = ""
        for snapshot in snapshots {
            let delta = LiveCoachSession.delta(previous: previous, snapshot: snapshot)
            joined += delta
            previous = snapshot
        }
        #expect(joined == "Hi there")
    }
}

/// Round-4 #8: the streaming *plumbing* -- not just the pure `delta` rule --
/// is where both round-1 bugs lived (cumulative snapshots forwarded as if
/// they were deltas, and the orphaned pump task wedging `isResponding`), and
/// it had no coverage at all. `deltaStream` is generic over the snapshot
/// sequence precisely so these run without a `LanguageModelSession`.
@Suite("LiveCoachSession.deltaStream")
@MainActor
struct DeltaStreamTests {
    @Test("cumulative snapshots reach the consumer as incremental deltas")
    func cumulativeSnapshotsBecomeDeltas() async throws {
        // What the framework actually yields: each snapshot is the whole
        // response so far. A concatenating consumer (the protocol's
        // documented contract) must see only the new text.
        let source = AsyncThrowingStream<String, Error> { continuation in
            for snapshot in ["Hi", "Hi", "Hi there", "Hi there!"] {
                continuation.yield(snapshot)
            }
            continuation.finish()
        }
        var received: [String] = []
        for try await delta in LiveCoachSession.deltaStream(snapshots: source) {
            received.append(delta)
        }
        // The repeated snapshot contributes nothing -- no empty yields.
        #expect(received == ["Hi", " there", "!"])
        #expect(received.joined() == "Hi there!")
    }

    @Test("a failing snapshot sequence finishes the stream with that error")
    func errorFinishesTheStream() async throws {
        struct StreamFailure: Error {}
        let source = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield("partial")
            continuation.finish(throwing: StreamFailure())
        }
        var received: [String] = []
        await #expect(throws: StreamFailure.self) {
            for try await delta in LiveCoachSession.deltaStream(snapshots: source) {
                received.append(delta)
            }
        }
        // Text delivered before the failure is not retracted.
        #expect(received == ["partial"])
    }

    @Test("an empty snapshot sequence finishes without yielding")
    func emptySequenceFinishes() async throws {
        let source = AsyncThrowingStream<String, Error> { $0.finish() }
        var received: [String] = []
        for try await delta in LiveCoachSession.deltaStream(snapshots: source) {
            received.append(delta)
        }
        #expect(received.isEmpty)
    }
}


@Suite("UnwiredTierSession fail-closed")
struct UnwiredTierSessionTests {
    @Test("every answering method fails namedly, never serves")
    func failsNamedly() async {
        let session = UnwiredTierSession(tier: .privateCloudCompute)
        #expect(!session.isResponding)
        await #expect(throws: CoachError.tierUnavailable(tier: .privateCloudCompute, reason: UnwiredTierSession.unwiredReason)) {
            try await session.respond(to: "hi")
        }
        var streamed: [String] = []
        await #expect(throws: CoachError.tierUnavailable(tier: .privateCloudCompute, reason: UnwiredTierSession.unwiredReason)) {
            for try await delta in session.stream(to: "hi") {
                streamed.append(delta)
            }
        }
        #expect(streamed.isEmpty)
    }

    @Test("the default build routes on-device live and everything else closed")
    func defaultBuildRoutesByTier() async {
        // No model touched: the unwired arm constructs without one, and the
        // on-device arm is never built here — the test asserts the routing
        // decision (type identity), then exercises only the unwired side.
        // (Live generation stays manual, test plan §7.)
        let factory = CoachSessionFactory()
        let pcc = factory.makeSession(for: .oneShot, instructions: "x", tier: .privateCloudCompute)
        #expect(pcc is UnwiredTierSession)
        await #expect(throws: CoachError.self) {
            try await pcc.respond(to: "hi")
        }
    }
}
