// KnowledgeDerivationTests.swift
//
// WP-19 (implementation-plan.md) "Tests" line: derivation functions with
// synthetic sample arrays -- avg/trend math, empty data, single day,
// DST-crossing days; correction pinning is exercised end-to-end in
// KnowledgeStoreTests.swift (it needs the store's persistence layer).

@testable import CoachKit
import CoreModel
import Foundation
import SyncKit
import Testing

private let fixedLocale = Locale(identifier: "en_US")
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func day(_ offset: Int, from base: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> Date {
    utc.date(byAdding: .day, value: offset, to: utc.startOfDay(for: base))!
}

@Suite("KnowledgeDerivation.stepsField")
struct StepsFieldTests {
    @Test("empty input yields no field")
    func emptyInput() {
        #expect(KnowledgeDerivation.stepsField(dailyValues: [], windowDays: 30, asOf: .now, source: "HealthKit") == nil)
    }

    @Test("averages over days with data, not window length")
    func average() {
        let values = [
            DailyQuantityValue(day: day(0), value: 8000),
            DailyQuantityValue(day: day(1), value: 10000),
        ]
        let field = KnowledgeDerivation.stepsField(
            dailyValues: values, windowDays: 30, asOf: .now, source: "HealthKit", locale: fixedLocale
        )
        #expect(field?.displayText == "~9,000 steps/day (30-day avg)")
        #expect(field?.key == KnowledgeDerivation.stepsFieldKey)
        #expect(field?.source == "HealthKit")
    }

    @Test("single day of data still derives")
    func singleDay() {
        let field = KnowledgeDerivation.stepsField(
            dailyValues: [DailyQuantityValue(day: day(0), value: 5000)],
            windowDays: 30,
            asOf: .now,
            source: "HealthKit",
            locale: fixedLocale
        )
        #expect(field?.displayText == "~5,000 steps/day (30-day avg)")
    }
}

@Suite("KnowledgeDerivation vitals trend")
struct VitalsFieldTests {
    @Test("steady within the 5% band")
    func steady() {
        let readings = [
            QuantityReading(date: day(0), value: 58),
            QuantityReading(date: day(1), value: 59),
        ]
        let field = KnowledgeDerivation.restingHeartRateField(
            readings: readings, windowDays: 30, asOf: .now, source: "HealthKit", locale: fixedLocale
        )
        #expect(field?.displayText.contains("steady with your baseline") == true)
    }

    @Test("latest well above baseline reads higher")
    func higher() {
        let readings = [
            QuantityReading(date: day(0), value: 50),
            QuantityReading(date: day(1), value: 70),
        ]
        let field = KnowledgeDerivation.restingHeartRateField(
            readings: readings, windowDays: 30, asOf: .now, source: "HealthKit", locale: fixedLocale
        )
        #expect(field?.displayText.contains("higher than your baseline") == true)
    }

    @Test("latest well below baseline reads lower")
    func lower() {
        let readings = [
            QuantityReading(date: day(0), value: 70),
            QuantityReading(date: day(1), value: 50),
        ]
        let field = KnowledgeDerivation.heartRateVariabilityField(
            readings: readings, windowDays: 30, asOf: .now, source: "HealthKit", locale: fixedLocale
        )
        #expect(field?.displayText.contains("lower than your baseline") == true)
    }

    @Test("empty input yields no field")
    func empty() {
        #expect(
            KnowledgeDerivation.restingHeartRateField(readings: [], windowDays: 30, asOf: .now, source: "HealthKit")
                == nil
        )
    }
}

@Suite("KnowledgeDerivation.sleepFields")
struct SleepFieldsTests {
    @Test("empty input yields no fields")
    func empty() {
        #expect(KnowledgeDerivation.sleepFields(segments: [], nights: 14, asOf: .now, source: "HealthKit").isEmpty)
    }

    @Test("duration and stage split over two nights")
    func durationAndStageSplit() {
        // Night 1: 6h core + 1h deep. Night 2: 5h core + 2h REM.
        let n1 = day(0).addingTimeInterval(23 * 3600) // 11pm night-of-day(0)
        let n2 = day(1).addingTimeInterval(23 * 3600)
        let segments = [
            SleepStageSegment(start: n1, end: n1.addingTimeInterval(6 * 3600), stage: .core),
            SleepStageSegment(start: n1.addingTimeInterval(6 * 3600), end: n1.addingTimeInterval(7 * 3600), stage: .deep),
            SleepStageSegment(start: n2, end: n2.addingTimeInterval(5 * 3600), stage: .core),
            SleepStageSegment(start: n2.addingTimeInterval(5 * 3600), end: n2.addingTimeInterval(7 * 3600), stage: .rem),
        ]
        let fields = KnowledgeDerivation.sleepFields(
            segments: segments, nights: 14, asOf: .now, source: "HealthKit", calendar: utc
        )
        #expect(fields.count == 2)
        let durationField = fields.first { $0.key == KnowledgeDerivation.sleepDurationFieldKey }
        // (7h + 7h) / 2 nights = 7h avg.
        #expect(durationField?.displayText == "~7h 0m asleep/night (14-night avg, 2 nights recorded)")
        let stageField = fields.first { $0.key == KnowledgeDerivation.sleepStageSplitFieldKey }
        #expect(stageField?.displayText.contains("core") == true)
        #expect(stageField?.displayText.contains("deep") == true)
        #expect(stageField?.displayText.contains("REM") == true)
    }

    @Test("a segment just after midnight buckets to the prior night")
    func nightKeyAcrossMidnight() {
        // 1am on day(1) is within 12h of day(0)'s evening -- same "night of day(0)."
        let lateNightStart = day(1).addingTimeInterval(1 * 3600)
        let key = KnowledgeDerivation.nightKey(for: lateNightStart, calendar: utc)
        #expect(key == day(0))
    }

    @Test("a segment in the evening buckets to that same calendar day's night")
    func nightKeyEvening() {
        let evening = day(0).addingTimeInterval(22 * 3600)
        let key = KnowledgeDerivation.nightKey(for: evening, calendar: utc)
        #expect(key == day(0))
    }

    @Test("stage percentages always sum to exactly 100, even when naive rounding would not")
    func stagePercentagesSumTo100() {
        // 1/3 each of core/deep/rem: naive independent rounding of 33.33...%
        // each gives 33/33/33 = 99, not 100.
        let n1 = day(0).addingTimeInterval(23 * 3600)
        let third = 3600.0 * 2 // arbitrary equal-length segments
        let segments = [
            SleepStageSegment(start: n1, end: n1.addingTimeInterval(third), stage: .core),
            SleepStageSegment(start: n1.addingTimeInterval(third), end: n1.addingTimeInterval(2 * third), stage: .deep),
            SleepStageSegment(start: n1.addingTimeInterval(2 * third), end: n1.addingTimeInterval(3 * third), stage: .rem),
        ]
        let fields = KnowledgeDerivation.sleepFields(
            segments: segments, nights: 14, asOf: .now, source: "HealthKit", calendar: utc
        )
        let stageField = fields.first { $0.key == KnowledgeDerivation.sleepStageSplitFieldKey }
        let breakdown = stageField?.displayText.replacingOccurrences(of: "Sleep stages: ", with: "") ?? ""
        let percentages = breakdown.components(separatedBy: ", ").compactMap { component -> Int? in
            guard let percentPart = component.split(separator: "%").first else { return nil }
            return Int(percentPart)
        }
        #expect(percentages.count == 3)
        #expect(percentages.reduce(0, +) == 100)
    }
}

@Suite("KnowledgeDerivation.workoutsField")
struct WorkoutsFieldTests {
    @Test("no workouts and no supplements yields no field")
    func empty() {
        #expect(
            KnowledgeDerivation.workoutsField(
                workouts: [], exerciseSupplements: [], windowDays: 30, asOf: .now, source: "HealthKit"
            ) == nil
        )
    }

    @Test("a supplement linked to a counted workout is never described as a second activity")
    func linkedSupplementNotDoubleCounted() {
        let workoutID = UUID()
        let workouts = [
            WorkoutRecord(
                id: workoutID, start: day(0), end: day(0).addingTimeInterval(1800),
                activityName: "Running", totalEnergyKilocalories: 300, totalDistanceMeters: 5000
            ),
        ]
        let supplements = [
            ExerciseSupplement(
                externalID: "ext-1", linkedWatchWorkoutUUID: workoutID, start: day(0), source: "Fitbit Air",
                activityName: "Running", distanceMeters: 5000, energyKilocalories: 320
            ),
        ]
        let field = KnowledgeDerivation.workoutsField(
            workouts: workouts, exerciseSupplements: supplements, windowDays: 30, asOf: .now, source: "HealthKit"
        )
        #expect(field?.displayText == "1 workout in the last 30 days: 1\u{00D7} Running.")
    }

    @Test("an unlinked supplement adds to the count without a title collision")
    func unlinkedSupplementCounted() {
        let workouts = [
            WorkoutRecord(
                id: UUID(), start: day(0), end: day(0).addingTimeInterval(1800),
                activityName: "Cycling", totalEnergyKilocalories: nil, totalDistanceMeters: nil
            ),
        ]
        let supplements = [
            ExerciseSupplement(
                externalID: "ext-2", linkedWatchWorkoutUUID: nil, start: day(0), source: "Fitbit Air",
                activityName: "Running", distanceMeters: nil, energyKilocalories: nil
            ),
        ]
        let field = KnowledgeDerivation.workoutsField(
            workouts: workouts, exerciseSupplements: supplements, windowDays: 30, asOf: .now, source: "HealthKit"
        )
        #expect(field?.displayText.contains("2 workouts in the last 30 days") == true)
        #expect(field?.displayText.contains("plus 1 Fitbit Air session not currently linked") == true)
    }

    @Test("a supplement linked to a workout outside the current window still counts as unlinked")
    func linkedToAbsentWorkout() {
        let supplements = [
            ExerciseSupplement(
                externalID: "ext-3", linkedWatchWorkoutUUID: UUID(), start: day(0), source: "Fitbit Air",
                activityName: "Swimming", distanceMeters: nil, energyKilocalories: nil
            ),
        ]
        let field = KnowledgeDerivation.workoutsField(
            workouts: [], exerciseSupplements: supplements, windowDays: 30, asOf: .now, source: "HealthKit"
        )
        #expect(field?.displayText == "1 workout in the last 30 days; plus 1 Fitbit Air session not currently linked to a watch workout.")
    }

    @Test("unlinked supplements from different sources fall back to a generic label")
    func unlinkedSupplementsMixedSources() {
        let supplements = [
            ExerciseSupplement(
                externalID: "ext-4", linkedWatchWorkoutUUID: nil, start: day(0), source: "Fitbit Air",
                activityName: "Running", distanceMeters: nil, energyKilocalories: nil
            ),
            ExerciseSupplement(
                externalID: "ext-5", linkedWatchWorkoutUUID: nil, start: day(0), source: "Pixel Watch",
                activityName: "Cycling", distanceMeters: nil, energyKilocalories: nil
            ),
        ]
        let field = KnowledgeDerivation.workoutsField(
            workouts: [], exerciseSupplements: supplements, windowDays: 30, asOf: .now, source: "HealthKit"
        )
        #expect(field?.displayText.contains("plus 2 other sessions not currently linked") == true)
    }
}

@Suite("KnowledgeDerivation.localOnlyField")
struct LocalOnlyFieldTests {
    private func sample(type: GoogleDataType, start: Date, valuesSum: Double, source: String = "Fitbit Air") -> LocalSample {
        let payload = try! JSONSerialization.data(withJSONObject: ["values": ["v": valuesSum]])
        return LocalSample(
            externalID: UUID().uuidString, dataType: type.rawValue, payloadJSON: payload,
            start: start, end: start.addingTimeInterval(60), source: source
        )
    }

    @Test("no samples in window yields no field")
    func empty() {
        let field = KnowledgeDerivation.localOnlyField(
            dataType: .activeZoneMinutes, samples: [], windowStart: day(-7), windowDays: 7, asOf: .now
        )
        #expect(field == nil)
    }

    @Test("active zone minutes sums payload values into a real quantity")
    func activeZoneMinutes() {
        let samples = [
            sample(type: .activeZoneMinutes, start: day(0), valuesSum: 12),
            sample(type: .activeZoneMinutes, start: day(1), valuesSum: 20),
        ]
        let field = KnowledgeDerivation.localOnlyField(
            dataType: .activeZoneMinutes, samples: samples, windowStart: day(-1), windowDays: 7, asOf: .now
        )
        #expect(field?.displayText == "~32 Active Zone Minutes in the last 7 days.")
        #expect(field?.isClinical == false)
        #expect(field?.excludedFromAI == false)
    }

    @Test("clinical types (ECG, IRN) produce presence-only fields with no aggregated value")
    func clinicalPresenceOnly() {
        let samples = [sample(type: .electrocardiogram, start: day(0), valuesSum: 999)]
        let field = KnowledgeDerivation.localOnlyField(
            dataType: .electrocardiogram, samples: samples, windowStart: day(-1), windowDays: 7, asOf: .now
        )
        #expect(field?.isClinical == true)
        #expect(field?.excludedFromAI == true, "D8: clinical fields default-excluded from AI context")
        #expect(field?.displayText.contains("999") == false, "clinical types must never surface an aggregated value")
        #expect(field?.displayText == "1 ECG record in the last 7 days \u{2014} view in the Health app.")
    }

    @Test("samples outside the window are excluded")
    func windowFiltering() {
        let samples = [sample(type: .activeZoneMinutes, start: day(-30), valuesSum: 999)]
        let field = KnowledgeDerivation.localOnlyField(
            dataType: .activeZoneMinutes, samples: samples, windowStart: day(-7), windowDays: 7, asOf: .now
        )
        #expect(field == nil)
    }

    @Test("a future-dated sample (clock skew) does not count forever")
    func futureDatedSampleExcluded() {
        // Code review (2026-08-28) finding #9: `asOf` is the upper bound, not
        // just `windowStart` the lower one.
        let asOf = day(0)
        let samples = [sample(type: .activeZoneMinutes, start: day(5), valuesSum: 999)]
        let field = KnowledgeDerivation.localOnlyField(
            dataType: .activeZoneMinutes, samples: samples, windowStart: day(-7), windowDays: 7, asOf: asOf
        )
        #expect(field == nil)
    }

    @Test("source label is deterministic -- the most recent sample's device wins, not fetch order")
    func deterministicSourceLabel() {
        // Code review (2026-08-28) finding #12: reversing the input array's
        // order must not change the result.
        let older = sample(type: .activeZoneMinutes, start: day(0), valuesSum: 5, source: "Apple Watch")
        let newer = sample(type: .activeZoneMinutes, start: day(1), valuesSum: 5, source: "Fitbit Air")
        let forward = KnowledgeDerivation.localOnlyField(
            dataType: .activeZoneMinutes, samples: [older, newer], windowStart: day(-1), windowDays: 7, asOf: .now
        )
        let reversed = KnowledgeDerivation.localOnlyField(
            dataType: .activeZoneMinutes, samples: [newer, older], windowStart: day(-1), windowDays: 7, asOf: .now
        )
        #expect(forward?.source == "LocalSample \u{00B7} Fitbit Air")
        #expect(forward?.source == reversed?.source)
    }

    @Test("a genuine tie on start is still resolved deterministically via externalID")
    func deterministicTieBreak() {
        // Code review (2026-09-01): the test above never actually ties
        // `start` -- plain `max(by: { $0.start < $1.start })` breaks a
        // genuine tie by array-traversal order, not "independent of array
        // order" as the surrounding comment claimed. `externalID` is
        // `@Attribute(.unique)` (LocalSample.swift), so pairing it in as a
        // secondary key removes the tie entirely.
        let payload = try! JSONSerialization.data(withJSONObject: ["values": ["v": 5.0]])
        let tiedStart = day(0)
        let a = LocalSample(
            externalID: "aaa", dataType: GoogleDataType.activeZoneMinutes.rawValue, payloadJSON: payload,
            start: tiedStart, end: tiedStart.addingTimeInterval(60), source: "Apple Watch"
        )
        let b = LocalSample(
            externalID: "bbb", dataType: GoogleDataType.activeZoneMinutes.rawValue, payloadJSON: payload,
            start: tiedStart, end: tiedStart.addingTimeInterval(60), source: "Fitbit Air"
        )
        let forward = KnowledgeDerivation.localOnlyField(
            dataType: .activeZoneMinutes, samples: [a, b], windowStart: day(-1), windowDays: 7, asOf: .now
        )
        let reversed = KnowledgeDerivation.localOnlyField(
            dataType: .activeZoneMinutes, samples: [b, a], windowStart: day(-1), windowDays: 7, asOf: .now
        )
        #expect(forward?.source == "LocalSample \u{00B7} Fitbit Air")
        #expect(forward?.source == reversed?.source)
    }

    @Test("an extreme payload value never traps the Int conversion")
    func extremePayloadValueClamped() {
        // Code review (2026-09-01): `sumPayloadValues` is deliberately
        // unbounded (its own doc comment) -- `Int(total.rounded())` used to
        // trap once the sum exceeded `Int`'s range. A single absurd-but-finite
        // payload value must degrade to a clamped display, never crash.
        let samples = [sample(type: .activeZoneMinutes, start: day(0), valuesSum: 1e20)]
        let field = KnowledgeDerivation.localOnlyField(
            dataType: .activeZoneMinutes, samples: samples, windowStart: day(-1), windowDays: 7, asOf: .now
        )
        #expect(field?.displayText == "~1000000000 Active Zone Minutes in the last 7 days.")
    }
}

@Suite("KnowledgeDerivation.duration")
struct DurationTests {
    @Test("negative seconds (clock-skewed/malformed data) clamp to zero rather than going negative")
    func negativeSecondsClampToZero() {
        // Code review (2026-09-01): a `SleepStageSegment` with `end < start`
        // must never surface a nonsensical negative duration string.
        #expect(KnowledgeDerivation.duration(seconds: -90000) == "0m")
        #expect(KnowledgeDerivation.duration(seconds: -30) == "0m")
    }

    @Test("positive seconds still format normally")
    func positiveSecondsUnaffected() {
        #expect(KnowledgeDerivation.duration(seconds: 3600) == "1h 0m")
        #expect(KnowledgeDerivation.duration(seconds: 90) == "2m")
    }
}
