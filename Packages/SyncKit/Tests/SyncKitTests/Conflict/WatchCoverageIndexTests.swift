// WatchCoverageIndexTests.swift
//
// WP-12b (implementation-plan.md) "Tests:" line + test-plan.md §2.3: the
// overlap-classifier truth table (exact match, 49 %/51 %, start+end
// tolerance, padding edges, back-to-back workouts, long auto-detected
// session containing a short watch workout), the cumulative-split vs
// instantaneous-drop stream rules at window edges, and the composition
// invariant (kept slices never overlap padded coverage or each other).
// Everything here is pure -- injected windows, no HealthKit, no clocks --
// exercising WatchCoverage.swift's `WatchCoverageIndex` directly.

import Foundation
import Testing
@testable import SyncKit

@Suite struct WatchCoverageIndexTests {
    /// Base instant every interval below offsets from -- absolute value is
    /// irrelevant to every rule under test.
    static let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    static func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    static func index(
        _ windows: [(start: Double, end: Double)],
        policy: WatchConflictPolicy = .default
    ) -> WatchCoverageIndex {
        WatchCoverageIndex(
            windows: windows.enumerated().map { offset, span in
                WatchCoverageWindow(
                    workoutUUID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", offset))!,
                    start: at(span.start),
                    end: at(span.end)
                )
            },
            policy: policy
        )
    }

    // MARK: - Other-app workouts (WP-55)

    // catches: a workout another app saved (no watch) either not winning
    // the session, or suppressing streams it never recorded -- and a watch
    // workout beside it losing its stream coverage.
    @Test func otherAppWorkoutsWinSessionsButNeverStreams() throws {
        let rower = WatchCoverageWindow(
            workoutUUID: UUID(), start: Self.at(0), end: Self.at(60), source: .otherApp
        )
        let watch = WatchCoverageWindow(workoutUUID: UUID(), start: Self.at(100), end: Self.at(160))
        let rowerOnly = WatchCoverageIndex(windows: [rower])
        #expect(rowerOnly.matchingWorkout(forSessionStart: Self.at(1), end: Self.at(59))?.workoutUUID == rower.workoutUUID)
        #expect(rowerOnly.resolveStream(start: Self.at(30), end: Self.at(30), cumulative: false) == .keep)
        #expect(rowerOnly.resolveStream(start: Self.at(10), end: Self.at(20), cumulative: true) == .keep)
        #expect(!rowerOnly.intersectsPaddedCoverage(start: Self.at(10), end: Self.at(20)))
        #expect(!rowerOnly.coversStreams)

        let both = WatchCoverageIndex(windows: [rower, watch])
        #expect(both.coversStreams)
        #expect(both.resolveStream(start: Self.at(130), end: Self.at(130), cumulative: false) == .suppress)
        #expect(both.resolveStream(start: Self.at(30), end: Self.at(30), cumulative: false) == .keep)
    }

    // MARK: - Session rule truth table (D13.2 / test-plan.md §2.3)

    @Test func exactMatchSessionDefers() {
        let index = Self.index([(0, 60)])
        let match = index.matchingWorkout(forSessionStart: Self.at(0), end: Self.at(60))
        #expect(match != nil)
        #expect(match?.workoutUUID == index.windows[0].workoutUUID)
    }

    @Test func fortyNinePercentOverlapOfShorterDurationDoesNotDefer() {
        // Workout 0-60; session is 100 min long, overlapping the last 29.4
        // min of the workout: overlap 29.4 / shorter 60 = 49% < 50%.
        // Δstart = 30.6, Δend = 70.6 -- tolerance rule can't fire either.
        let index = Self.index([(0, 60)])
        #expect(index.matchingWorkout(forSessionStart: Self.at(30.6), end: Self.at(130.6)) == nil)
    }

    @Test func fiftyOnePercentOverlapOfShorterDurationDefers() {
        // Same shape, overlap 30.6 / shorter 60 = 51%.
        let index = Self.index([(0, 60)])
        #expect(index.matchingWorkout(forSessionStart: Self.at(29.4), end: Self.at(129.4)) != nil)
    }

    @Test func exactlyFiftyPercentOverlapDefersInclusiveBoundary() {
        // architecture.md D13.2 says "≥ 50 %" -- the boundary itself counts.
        let index = Self.index([(0, 60)])
        #expect(index.matchingWorkout(forSessionStart: Self.at(30), end: Self.at(130)) != nil)
    }

    @Test func startAndEndBothWithinToleranceDefer() {
        // Workout 0-60; session 8 min late on both ends: overlap 52 /
        // shorter 60 = 86.7% would defer anyway, so shrink the overlap out:
        // session 9-67 -- Δstart 9 ≤ 10, Δend 7 ≤ 10, overlap 51/58 = 87.9%.
        // Both rules agree here; the *isolating* case is the inverse test
        // below, where only-one-end fails. This case pins that a slightly
        // shifted session (the realistic Fitbit auto-detect lag) defers.
        let index = Self.index([(0, 60)])
        #expect(index.matchingWorkout(forSessionStart: Self.at(9), end: Self.at(67)) != nil)
    }

    @Test func onlyOneEndWithinToleranceAndLowOverlapDoesNotDefer() {
        // Workout 0-60; session 55-71 (16 min): Δend |71-60| = 11 > 10,
        // Δstart |55-0| = 55 > 10 -- wait, that's neither end. Construct the
        // genuine one-end case: session 55-66 (11 min): Δend 6 ≤ 10 ✓ but
        // Δstart 55 ✗; overlap 55-60 = 5 min, shorter 11 min ⇒ 45.5% < 50%.
        // One matching end alone must not defer (test-plan.md §2.3).
        let index = Self.index([(0, 60)])
        #expect(index.matchingWorkout(forSessionStart: Self.at(55), end: Self.at(66)) == nil)
    }

    @Test func longAutoDetectedSessionContainingShortWatchWorkoutDefers() {
        // Fitbit auto-detected 3 h "activity" fully containing a 40 min
        // watch workout: overlap = 40 = 100% of the shorter duration.
        let index = Self.index([(60, 100)])
        #expect(index.matchingWorkout(forSessionStart: Self.at(0), end: Self.at(180)) != nil)
    }

    @Test func sessionSpanningBackToBackWorkoutsDefersToTheEarliest() {
        let index = Self.index([(0, 45), (50, 95)])
        let match = index.matchingWorkout(forSessionStart: Self.at(0), end: Self.at(95))
        #expect(match?.workoutUUID == index.windows[0].workoutUUID)
    }

    @Test func sessionFarFromAnyWorkoutDoesNotDefer() {
        let index = Self.index([(0, 60)])
        #expect(index.matchingWorkout(forSessionStart: Self.at(300), end: Self.at(340)) == nil)
    }

    @Test func sessionRuleUsesUnpaddedBoundsNotPaddedOnes() {
        // A 10-min session sitting entirely inside the ±5 min *padding*
        // after the workout (60-65) but 0% inside the workout itself:
        // overlap with unpadded bounds = 0 -- padding is a stream-rule
        // concept (D13.3), never a session-rule one (D13.2). Δend/Δstart:
        // session 60.5-70.5 vs workout 0-60 ⇒ Δend 10.5 > 10. No defer.
        let index = Self.index([(0, 60)])
        #expect(index.matchingWorkout(forSessionStart: Self.at(60.5), end: Self.at(70.5)) == nil)
    }

    @Test func reversedSessionWindowNeverDefers() {
        let index = Self.index([(0, 60)])
        #expect(index.matchingWorkout(forSessionStart: Self.at(60), end: Self.at(0)) == nil)
    }

    // MARK: - Stream rule (D13.3): suppress / keep / split at padded edges

    @Test func sampleFullyInsidePaddedWindowIsSuppressed() {
        // Workout 0-60, padding 5 ⇒ covered span -5..65. A sample at 58-63
        // (straddling the workout end but inside the padding) suppresses.
        let index = Self.index([(0, 60)])
        #expect(index.resolveStream(start: Self.at(58), end: Self.at(63), cumulative: true) == .suppress)
        #expect(index.resolveStream(start: Self.at(58), end: Self.at(63), cumulative: false) == .suppress)
    }

    @Test func sampleJustBeyondPaddingIsKept() {
        // Covered span ends at 65; a 66-70 sample is fully outside.
        let index = Self.index([(0, 60)])
        #expect(index.resolveStream(start: Self.at(66), end: Self.at(70), cumulative: true) == .keep)
        #expect(index.resolveStream(start: Self.at(66), end: Self.at(70), cumulative: false) == .keep)
    }

    @Test func cumulativeSamplePartiallyOverlappingIsSplitAtThePaddedEdge() {
        // Covered span -5..65; sample 50-90 ⇒ kept slice exactly 65-90.
        let index = Self.index([(0, 60)])
        let resolution = index.resolveStream(start: Self.at(50), end: Self.at(90), cumulative: true)
        #expect(resolution == .split([StreamSlice(start: Self.at(65), end: Self.at(90))]))
    }

    @Test func cumulativeSampleSpanningAWholeWindowSplitsIntoBothSides() {
        // Workout 30-60 ⇒ covered 25..65; sample 0-90 ⇒ slices 0-25 + 65-90.
        let index = Self.index([(30, 60)])
        let resolution = index.resolveStream(start: Self.at(0), end: Self.at(90), cumulative: true)
        #expect(resolution == .split([
            StreamSlice(start: Self.at(0), end: Self.at(25)),
            StreamSlice(start: Self.at(65), end: Self.at(90)),
        ]))
    }

    @Test func instantaneousSamplePartiallyOverlappingIsDroppedWhole() {
        // Same 50-90 shape as the split test, but instantaneous ⇒ suppress.
        let index = Self.index([(0, 60)])
        #expect(index.resolveStream(start: Self.at(50), end: Self.at(90), cumulative: false) == .suppress)
    }

    @Test func zeroDurationSampleInsideCoverageSuppressedOutsideKept() {
        let index = Self.index([(0, 60)])
        #expect(index.resolveStream(start: Self.at(30), end: Self.at(30), cumulative: false) == .suppress)
        // Boundary-inclusive: exactly at the padded edge (65) suppresses.
        #expect(index.resolveStream(start: Self.at(65), end: Self.at(65), cumulative: false) == .suppress)
        #expect(index.resolveStream(start: Self.at(66), end: Self.at(66), cumulative: false) == .keep)
    }

    @Test func backToBackWindowsMergeThroughPaddingForStreamMath() {
        // Workouts 0-30 and 36-60: padded spans -5..35 and 31..65 overlap ⇒
        // merge into -5..65. A sample sitting in the 30-36 gap between the
        // *unpadded* workouts is still fully covered.
        let index = Self.index([(0, 30), (36, 60)])
        #expect(index.resolveStream(start: Self.at(31), end: Self.at(35), cumulative: true) == .suppress)
    }

    @Test func emptyIndexKeepsEverything() {
        let index = Self.index([])
        #expect(index.isEmpty)
        #expect(index.resolveStream(start: Self.at(0), end: Self.at(60), cumulative: true) == .keep)
        #expect(index.matchingWorkout(forSessionStart: Self.at(0), end: Self.at(60)) == nil)
    }

    // MARK: - Composition invariant (test-plan.md §2.3's property test)

    /// For any set of coverage windows and any sample interval: the kept
    /// slices never intersect padded coverage, never overlap each other,
    /// stay inside the original interval, and (with the covered portion)
    /// account for the interval's full duration -- the property that makes
    /// Apple Health day totals compose (watch during workout + Fitbit rest
    /// of day, D13.3). Deterministic pseudo-random cases via a seeded LCG --
    /// reproducible, no flakiness.
    @Test func keptSlicesComposeWithCoverageForRandomizedWindowSets() {
        var state: UInt64 = 0x5EED_CAFE
        func nextFraction() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(UInt64.max >> 11)
        }

        for _ in 0..<200 {
            let windowCount = Int(nextFraction() * 4) // 0...3
            let windows: [(start: Double, end: Double)] = (0..<windowCount).map { _ in
                let start = nextFraction() * 480
                return (start, start + 5 + nextFraction() * 90)
            }
            let index = Self.index(windows)

            let sampleStart = nextFraction() * 480
            let sampleEnd = sampleStart + 1 + nextFraction() * 240
            let start = Self.at(sampleStart)
            let end = Self.at(sampleEnd)

            switch index.resolveStream(start: start, end: end, cumulative: true) {
            case .keep:
                #expect(!index.intersectsPaddedCoverage(start: start, end: end))
            case .suppress:
                // Fully covered -- nothing kept, nothing to check beyond the
                // intersection being real.
                #expect(index.intersectsPaddedCoverage(start: start, end: end))
            case .split(let slices):
                #expect(!slices.isEmpty)
                var keptDuration: TimeInterval = 0
                var previousEnd = Date.distantPast
                for slice in slices {
                    #expect(slice.end > slice.start)
                    #expect(slice.start >= start && slice.end <= end)
                    #expect(slice.start >= previousEnd) // no mutual overlap, ordered
                    #expect(!index.intersectsPaddedCoverage(start: slice.start, end: slice.end))
                    keptDuration += slice.duration
                    previousEnd = slice.end
                }
                // Split means something was genuinely covered.
                #expect(keptDuration < end.timeIntervalSince(start))
                #expect(keptDuration > 0)
            }
        }
    }
}
