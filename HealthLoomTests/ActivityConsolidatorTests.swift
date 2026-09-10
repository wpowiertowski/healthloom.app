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
            uuid: uuid, activityName: "Run", start: start, end: end,
            sourceName: "Workout", isHealthLoomImport: false, isAppleWatch: true
        )
    }

    static func fitbitImportedWorkout(start: Date = at(7), end: Date = at(7.75)) -> WorkoutSummary {
        WorkoutSummary(
            uuid: UUID(), activityName: "Run", start: start, end: end,
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
