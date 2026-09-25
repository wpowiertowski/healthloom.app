// ActivityConsolidatorTests.swift
//
// WP-12b (implementation-plan.md) step 5 / architecture.md D13.2: the
// consolidation logic behind the Activities view -- one entry per activity,
// watch workout primary with the linked Fitbit session's fields as an
// inline supplement (never a second entry), Fitbit-only workouts as full
// entries, unlinked deferred sessions surfaced standalone, day grouping.
// `ActivityConsolidator`/`FitbitActivitySupplement` (HealthLoomApp/
// Activities/ActivitiesModels.swift) are deliberately HealthKit-free so
// this suite needs no HK store -- `WorkoutSummary` fixtures are plain
// values, and the payload-decode test drives `FitbitActivitySupplement`'s
// `LocalSample` initializer with the exact JSON shape
// `SyncEngine`/`BackfillCoordinator` persist.

import CoreModel
import Foundation
import Testing
@testable import HealthLoom

@Suite("ActivityConsolidator")
struct ActivityConsolidatorTests {
    static let day = ISO8601DateFormatter().date(from: "2026-07-09T00:00:00Z")!

    static func at(_ hours: Double) -> Date { day.addingTimeInterval(hours * 3600) }

    static let watchUUID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    static func watchWorkout(
        uuid: UUID = watchUUID,
        start: Date = at(10),
        end: Date = at(10.67)
    ) -> WorkoutSummary {
        WorkoutSummary(
            uuid: uuid, activityName: "Run", family: .onFoot, start: start, end: end,
            sourceName: "Workout", isHealthLoomImport: false, isAppleWatch: true
        )
    }

    static func fitbitImportedWorkout(start: Date = at(7), end: Date = at(7.75)) -> WorkoutSummary {
        WorkoutSummary(
            uuid: UUID(), activityName: "Run", family: .onFoot, start: start, end: end,
            sourceName: "HealthLoom", isHealthLoomImport: true, isAppleWatch: false
        )
    }

    /// A deferred Fitbit session row exactly as the sync pipeline persists
    /// it (SyncEngineLocalPayload's envelope; the session payload is the
    /// Google Exercise wire shape ExerciseSessionDecoding.swift documents).
    static func deferredSession(
        externalID: String = "fitbit-run-1",
        linkedTo uuid: UUID? = watchUUID,
        start: Date = at(10.03),
        end: Date = at(10.72)
    ) -> LocalSample {
        let session = Data(
            #"{"exercise.activity_type":"run","exercise.distance":8000.0,"exercise.energy":520.0}"#.utf8
        )
        return LocalSample(
            externalID: externalID,
            dataType: GoogleDataType.exercise.rawValue,
            payloadJSON: Data(#"{"sessionPayload":"\#(session.base64EncodedString())"}"#.utf8),
            start: start,
            end: end,
            source: "Fitbit Air",
            linkedWatchWorkoutUUID: uuid
        )
    }

    @Test func supplementLinkedToNonAppleWatchWorkoutStillAttachesInline() {
        // The link is ground truth (resolver matched by coverage); the
        // `isAppleWatch` heuristic disagreeing must not drop the detail
        // row -- one entry, supplement attached, row keeping its own source
        // name (not the supplement's).
        let imported = Self.fitbitImportedWorkout()
        let supplement = FitbitActivitySupplement(sample: Self.deferredSession(linkedTo: imported.uuid))
        let entries = ActivityConsolidator.consolidate(workouts: [imported], supplements: [supplement])

        #expect(entries.count == 1)
        let entry = entries[0]
        #expect(entry.kind != .unlinkedFitbitSession)
        #expect(entry.supplement?.externalID == supplement.externalID)
        #expect(entry.supplement?.distanceMeters == 8000.0)
        #expect(entry.sourceLabel == "HealthLoom")
    }

    @Test func watchWorkoutWithLinkedSessionConsolidatesIntoOneEntryWithSupplement() {
        let workout = Self.watchWorkout()
        let supplement = FitbitActivitySupplement(sample: Self.deferredSession())

        let entries = ActivityConsolidator.consolidate(workouts: [workout], supplements: [supplement])

        #expect(entries.count == 1) // one activity, never two
        let entry = entries[0]
        #expect(entry.title == "Run")
        #expect(entry.sourceLabel.contains("Apple Watch"))
        #expect(entry.supplement?.externalID == "fitbit-run-1")
        #expect(entry.supplement?.distanceMeters == 8000.0)
        #expect(entry.supplement?.energyKilocalories == 520.0)
        #expect(entry.supplement?.source == "Fitbit Air")
    }

    @Test func fitbitOnlyWorkoutRendersAsAFullEntry() {
        let entries = ActivityConsolidator.consolidate(
            workouts: [Self.fitbitImportedWorkout()], supplements: []
        )

        #expect(entries.count == 1)
        #expect(entries[0].supplement == nil)
        #expect(!entries[0].sourceLabel.contains("Apple Watch"))
    }

    @Test func sessionLinkedToUnreadableWorkoutSurfacesStandalone() {
        // The linked watch workout isn't among the readable workouts (read
        // denied / deleted) -- the activity must not vanish.
        let supplement = FitbitActivitySupplement(sample: Self.deferredSession(linkedTo: UUID()))

        let entries = ActivityConsolidator.consolidate(workouts: [], supplements: [supplement])

        #expect(entries.count == 1)
        #expect(entries[0].kind == .unlinkedFitbitSession)
        #expect(entries[0].title == "Run")
        #expect(entries[0].sourceLabel == "Fitbit Air")
    }

    @Test func mixedDayConsolidatesEachActivityOnceNewestFirst() {
        let watch = Self.watchWorkout()
        let fitbitOnly = Self.fitbitImportedWorkout()
        let supplement = FitbitActivitySupplement(sample: Self.deferredSession())

        let entries = ActivityConsolidator.consolidate(
            workouts: [fitbitOnly, watch], supplements: [supplement]
        )

        #expect(entries.count == 2)
        #expect(entries[0].id == Self.watchUUID.uuidString) // 10:00 before 07:00, newest first
        #expect(entries[0].supplement != nil)
        #expect(entries[1].supplement == nil)
    }

    @Test func equalStartEntriesOrderDeterministicallyByID() {
        // Round-7 item 12: two unlinked supplements sharing a start
        // must order by ID — Dictionary iteration order is per-process,
        // so start-only sorting reordered equal entries across launches
        // (snapshot flake).
        let atSame = Self.at(9)
        let entries = ActivityConsolidator.consolidate(
            workouts: [],
            supplements: [
                FitbitActivitySupplement(sample: Self.deferredSession(externalID: "aa", linkedTo: nil, start: atSame, end: atSame)),
                FitbitActivitySupplement(sample: Self.deferredSession(externalID: "zz", linkedTo: nil, start: atSame, end: atSame)),
            ]
        )
        #expect(entries.map(\.id) == ["zz", "aa"])
    }

    @Test func groupedByDaySplitsAcrossCalendarDaysNewestDayFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = Self.watchWorkout()
        let yesterday = Self.fitbitImportedWorkout(
            start: Self.at(-17), end: Self.at(-16) // 07:00 the previous day
        )

        let entries = ActivityConsolidator.consolidate(workouts: [today, yesterday], supplements: [])
        let groups = ActivityConsolidator.groupedByDay(entries, calendar: calendar)

        #expect(groups.count == 2)
        #expect(groups[0].entries.map(\.id) == [today.uuid.uuidString])
        #expect(groups[1].entries.map(\.id) == [yesterday.uuid.uuidString])
        #expect(groups[0].day > groups[1].day)
    }

    @Test func malformedPayloadStillProducesARenderableSupplement() {
        let sample = LocalSample(
            externalID: "fitbit-run-broken",
            dataType: GoogleDataType.exercise.rawValue,
            payloadJSON: Data("not json".utf8),
            start: Self.at(10),
            end: Self.at(10.5),
            source: "Fitbit Air",
            linkedWatchWorkoutUUID: nil
        )

        let supplement = FitbitActivitySupplement(sample: sample)

        #expect(supplement.activityName == nil)
        #expect(supplement.distanceMeters == nil)
        #expect(supplement.energyKilocalories == nil)
        #expect(supplement.source == "Fitbit Air")

        let entries = ActivityConsolidator.consolidate(workouts: [], supplements: [supplement])
        #expect(entries.count == 1)
        #expect(entries[0].title == "Activity") // fallback title
    }
}

// MARK: - WP-46 / D16.8: activity detailing

@Suite("Activity detailing")
struct ActivityDetailingTests {
    private typealias Fixture = ActivityConsolidatorTests

    private static func entry(
        duration minutes: Double,
        distance: Double? = nil,
        heartRate: Double? = nil,
        swim: SwimLocation? = nil
    ) -> ActivityEntry {
        ActivityEntry(
            id: UUID().uuidString, kind: .unlinkedFitbitSession, title: "Run",
            start: Fixture.at(10), end: Fixture.at(10).addingTimeInterval(minutes * 60),
            sourceLabel: "Apple Watch", supplement: nil, family: .onFoot,
            distanceMeters: distance, averageHeartRate: heartRate, swimLocation: swim
        )
    }

    // catches: a standalone Fitbit session dropping its own distance, so an
    // 8 km run renders as "40 min" alone (the pre-WP-46 behaviour).
    @Test func standaloneFitbitSessionKeepsItsDistance() {
        let supplement = FitbitActivitySupplement(sample: Fixture.deferredSession(linkedTo: nil))
        let entries = ActivityConsolidator.consolidate(workouts: [], supplements: [supplement])
        guard let entry = entries.first else {
            Issue.record("expected one standalone entry")
            return
        }
        #expect(entry.distanceMeters == 8000)
        #expect(entry.badges.contains("8.0 km"))
        #expect(entry.family == .onFoot)
    }

    // catches: a linked supplement's distance copied onto the workout's own
    // badges, rendering the same 8 km twice (D13.2: supplement, never
    // duplicate).
    @Test func linkedSupplementDistanceStaysOnTheSupplement() {
        let workout = Fixture.watchWorkout()
        let supplement = FitbitActivitySupplement(sample: Fixture.deferredSession(linkedTo: workout.uuid))
        let entries = ActivityConsolidator.consolidate(workouts: [workout], supplements: [supplement])
        guard let entry = entries.first else {
            Issue.record("expected one consolidated entry")
            return
        }
        #expect(entry.supplement?.distanceMeters == 8000)
        #expect(entry.distanceMeters == nil)
        #expect(entry.badges == ["40 min"])
    }

    // catches: badges for stats the workout never recorded ("0 bpm", "0 m"),
    // or readings out of order.
    @Test func badgesListOnlyRecordedReadingsInOrder() {
        #expect(Self.entry(duration: 20).badges == ["20 min"])
        #expect(Self.entry(duration: 20, distance: 0, heartRate: 0).badges == ["20 min"])
        #expect(
            Self.entry(duration: 37, distance: 6200, heartRate: 147.6, swim: .openWater).badges
                == ["37 min", "6.2 km", "148 bpm", "Open water"]
        )
    }

    // catches: a sub-minute session rendering as "0 min".
    @Test func durationNeverRendersZeroMinutes() {
        #expect(Self.entry(duration: 0.4).durationText == "1 min")
    }

    // catches: sub-kilometre distances shown as "0.9 km", and totals past an
    // hour rendered in minutes.
    @Test func formatsDistanceAndTotalDuration() {
        #expect(ActivityFormat.distance(850) == "850 m")
        #expect(ActivityFormat.distance(6200) == "6.2 km")
        #expect(ActivityFormat.totalDuration(3 * 3600 + 49 * 60) == "3 h 49 m")
        #expect(ActivityFormat.totalDuration(49 * 60) == "49 m")
    }

    // catches: an off-by-one in the day span -- the mockup's list (oldest
    // session 12 Sep, viewed 21 Sep) reads "10 days".
    @Test func summaryCountsDaysInclusiveOfToday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        func day(_ d: Int) throws -> Date {
            try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: d, hour: 9)))
        }
        let oldest = ActivityEntry(
            id: "a", kind: .unlinkedFitbitSession, title: "Rowing", start: try day(12),
            end: try day(12).addingTimeInterval(20 * 60), sourceLabel: "Hydrow", supplement: nil, family: .endurance
        )
        let newest = ActivityEntry(
            id: "b", kind: .unlinkedFitbitSession, title: "Swim", start: try day(20),
            end: try day(20).addingTimeInterval(71 * 60), sourceLabel: "Apple Watch", supplement: nil, family: .water
        )
        let summary = ActivitySummary(entries: [oldest, newest], now: try day(21), calendar: calendar)
        #expect(summary.parts == ["2 sessions", "1 h 31 m", "10 days"])
        let single = ActivitySummary(entries: [newest], now: try day(20), calendar: calendar)
        #expect(single.parts == ["1 session", "1 h 11 m", "1 day"])
        #expect(ActivitySummary(entries: [], now: try day(21), calendar: calendar).sessions == 0)
    }

    // catches: bars not scaled to the longest session, and a divide-by-zero
    // when every listed session is zero-length.
    @Test func durationFractionIsRelativeToTheLongest() {
        let long = Self.entry(duration: 71)
        let short = Self.entry(duration: 20)
        #expect(ActivitySummary.durationFraction(of: long, in: [long, short]) == 1)
        #expect(abs(ActivitySummary.durationFraction(of: short, in: [long, short]) - 20.0 / 71.0) < 1e-9)
        let empty = Self.entry(duration: 0)
        #expect(ActivitySummary.durationFraction(of: empty, in: [empty]) == 0)
    }

    // catches: a Fitbit swim or ride drawn in another family's field. Each
    // wire key goes through the real decode path (CoreModel title-cases it),
    // so a change to either vocabulary shows up here.
    @Test func fitbitNamesMapToTheirFamilies() {
        let expected: [String: ActivityFamily] = [
            "run": .onFoot, "walk": .onFoot, "hike": .onFoot,
            "swim": .water,
            "bike": .endurance, "rowing": .endurance, "elliptical": .endurance, "stair_climbing": .endurance,
            "weights": .training, "yoga": .training, "hiit": .training, "core_training": .training,
            "workout": .training,
        ]
        for (wireKey, family) in expected {
            let session = Data(#"{"exercise.activity_type":"\#(wireKey)"}"#.utf8)
            let sample = LocalSample(
                externalID: "fitbit-\(wireKey)",
                dataType: GoogleDataType.exercise.rawValue,
                payloadJSON: Data(#"{"sessionPayload":"\#(session.base64EncodedString())"}"#.utf8),
                start: Fixture.at(10), end: Fixture.at(11),
                source: "Fitbit Air", linkedWatchWorkoutUUID: nil
            )
            let name = FitbitActivitySupplement(sample: sample).activityName
            #expect(ActivityFamily(fitbitActivityName: name) == family, "\(wireKey) -> \(name ?? "nil")")
        }
        #expect(ActivityFamily(fitbitActivityName: nil) == .training)
    }

    // catches: two activity families sharing a field, so kinds can't be told
    // apart down the list.
    @Test func everyFamilyHasItsOwnField() {
        let fields = ActivityFamily.allCases.map(ActivityRow.field)
        #expect(Set(fields).count == ActivityFamily.allCases.count)
    }
}
