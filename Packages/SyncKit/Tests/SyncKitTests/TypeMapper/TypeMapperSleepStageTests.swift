// TypeMapperSleepStageTests.swift
//
// WP-07 (implementation-plan.md) "Tests:" line: "sleep multi-stage session
// (incl. unknown stage, zero-length segment)." Also covers the "Segments
// must not overlap; clamp to session bounds" rule (WP-07 step 3) with a
// dedicated overlapping-segments scenario, since the golden fixture's
// segments are already contiguous and wouldn't exercise clamping at all.

import CoreModel
import Foundation
import GoogleHealthClient
import Testing
@testable import SyncKit

@Suite struct TypeMapperSleepStageTests {
    /// A session with an unrecognized stage string ("napping") and a
    /// zero-length segment: the unknown stage maps to `.asleepUnspecified`
    /// (WP-07 step 3's explicit fallback) and the zero-length segment is
    /// dropped entirely rather than emitted as a degenerate sample.
    @Test func unknownStageAndZeroLengthSegment() {
        let point = TypeMapperFixtures.sleepPoint(
            start: TypeMapperFixtures.date("2026-07-08T23:00:00Z"),
            end: TypeMapperFixtures.date("2026-07-09T01:00:00Z"),
            segments: [
                .init("2026-07-08T23:00:00Z", "2026-07-08T23:10:00Z", "AWAKE"),
                .init("2026-07-08T23:10:00Z", "2026-07-08T23:15:00Z", "napping"), // unknown
                .init("2026-07-08T23:15:00Z", "2026-07-08T23:15:00Z", "LIGHT"),  // zero-length
                .init("2026-07-08T23:15:00Z", "2026-07-09T01:00:00Z", "LIGHT"),
            ]
        )
        guard case .category(let segments) = TypeMapper.decide(point) else {
            Issue.record("expected .category")
            return
        }
        // The zero-length segment must be dropped -- three, not four, emitted.
        #expect(segments.count == 3)
        #expect(segments.map(\.stage) == [.awake, .asleepUnspecified, .asleepCore])
        #expect(segments[0].start == TypeMapperFixtures.date("2026-07-08T23:00:00Z"))
        #expect(segments[0].end == TypeMapperFixtures.date("2026-07-08T23:10:00Z"))
        #expect(segments[1].start == TypeMapperFixtures.date("2026-07-08T23:10:00Z"))
        #expect(segments[1].end == TypeMapperFixtures.date("2026-07-08T23:15:00Z"))
        #expect(segments[2].start == TypeMapperFixtures.date("2026-07-08T23:15:00Z"))
        #expect(segments[2].end == TypeMapperFixtures.date("2026-07-09T01:00:00Z"))
    }

    /// Overlapping input segments (a short "awake" nested entirely inside a
    /// preceding "light" segment) must not produce overlapping output:
    /// the later, fully-overlapped segment is dropped rather than emitted
    /// alongside the segment it overlaps.
    @Test func overlappingSegmentsAreSuppressedNotDoubled() {
        let point = TypeMapperFixtures.sleepPoint(
            start: TypeMapperFixtures.date("2026-07-08T22:00:00Z"),
            end: TypeMapperFixtures.date("2026-07-09T00:00:00Z"),
            segments: [
                .init("2026-07-08T22:00:00Z", "2026-07-08T23:00:00Z", "LIGHT"),
                .init("2026-07-08T22:30:00Z", "2026-07-08T22:45:00Z", "AWAKE"), // fully inside the light segment above
                .init("2026-07-08T23:00:00Z", "2026-07-09T00:00:00Z", "DEEP"),
            ]
        )
        guard case .category(let segments) = TypeMapper.decide(point) else {
            Issue.record("expected .category")
            return
        }
        #expect(segments.count == 2)
        #expect(segments.map(\.stage) == [.asleepCore, .asleepDeep])
        // No overlap: each segment's start >= the previous segment's end.
        for index in 1..<segments.count {
            #expect(segments[index].start >= segments[index - 1].end)
        }
    }

    /// Segments extending outside the session's own bounds are clamped to
    /// them, never extending an emitted sample past the session window.
    @Test func segmentsClampToSessionBounds() {
        let point = TypeMapperFixtures.sleepPoint(
            start: TypeMapperFixtures.date("2026-07-08T23:00:00Z"),
            end: TypeMapperFixtures.date("2026-07-09T00:00:00Z"),
            segments: [
                // Starts 30 minutes before the session and ends 30 minutes
                // after it -- both edges must be clamped inward.
                .init("2026-07-08T22:30:00Z", "2026-07-09T00:30:00Z", "DEEP"),
            ]
        )
        guard case .category(let segments) = TypeMapper.decide(point) else {
            Issue.record("expected .category")
            return
        }
        #expect(segments.count == 1)
        #expect(segments[0].start == TypeMapperFixtures.date("2026-07-08T23:00:00Z"))
        #expect(segments[0].end == TypeMapperFixtures.date("2026-07-09T00:00:00Z"))
    }

    /// A session whose payload decodes to zero usable segments (all dropped,
    /// or an empty segment array) is dropped entirely -- never an empty
    /// `.category([])`.
    @Test func sessionWithNoUsableSegmentsIsSkipped() {
        let point = TypeMapperFixtures.sleepPoint(
            start: TypeMapperFixtures.date("2026-07-08T23:00:00Z"),
            end: TypeMapperFixtures.date("2026-07-09T00:00:00Z"),
            segments: [
                .init("2026-07-08T23:00:00Z", "2026-07-08T23:00:00Z", "LIGHT"), // zero-length
            ]
        )
        #expect(TypeMapper.decide(point) == .skip)
    }

    /// Malformed/missing session payload (no `sessionPayload` at all) never
    /// crashes -- drops instead.
    @Test func missingSessionPayloadIsSkipped() {
        let point = GoogleDataPoint(
            id: "sleep-broken",
            dataType: .sleep,
            start: TypeMapperFixtures.date("2026-07-08T23:00:00Z"),
            end: TypeMapperFixtures.date("2026-07-09T00:00:00Z"),
            source: DataSource(platform: nil, deviceDisplayName: nil, recordingMethod: nil),
            values: [:],
            sessionPayload: nil
        )
        #expect(TypeMapper.decide(point) == .skip)
    }

    @Test func malformedSessionPayloadIsSkipped() {
        let point = GoogleDataPoint(
            id: "sleep-broken",
            dataType: .sleep,
            start: TypeMapperFixtures.date("2026-07-08T23:00:00Z"),
            end: TypeMapperFixtures.date("2026-07-09T00:00:00Z"),
            source: DataSource(platform: nil, deviceDisplayName: nil, recordingMethod: nil),
            values: [:],
            sessionPayload: Data("not json".utf8)
        )
        #expect(TypeMapper.decide(point) == .skip)
    }

    // catches: a night with no stage breakdown (a nap, some classic sleeps)
    // being dropped instead of recorded as sleep (WP-51).
    @Test func stagelessSessionIsOneUnspecifiedSample() {
        let point = TypeMapperFixtures.sleepPoint(segments: [])
        guard case .category(let samples) = TypeMapper.decide(point) else {
            Issue.record("expected one sleep sample")
            return
        }
        #expect(samples.count == 1)
        #expect(samples.first?.stage == .asleepUnspecified)
        #expect(samples.first?.start == point.start)
        #expect(samples.first?.end == point.end)
    }

    // catches: classic sleep's ASLEEP / RESTLESS counted as awake -- restless
    // is movement while asleep, and both are sleep time.
    @Test func classicSleepStagesAreAsleep() {
        let point = TypeMapperFixtures.sleepPoint(
            start: TypeMapperFixtures.date("2026-07-08T23:00:00Z"),
            end: TypeMapperFixtures.date("2026-07-09T01:00:00Z"),
            segments: [
                .init("2026-07-08T23:00:00Z", "2026-07-09T00:00:00Z", "ASLEEP"),
                .init("2026-07-09T00:00:00Z", "2026-07-09T01:00:00Z", "RESTLESS"),
            ]
        )
        guard case .category(let samples) = TypeMapper.decide(point) else {
            Issue.record("expected sleep samples")
            return
        }
        #expect(samples.map(\.stage) == [.asleepUnspecified, .asleepUnspecified])
    }
}
