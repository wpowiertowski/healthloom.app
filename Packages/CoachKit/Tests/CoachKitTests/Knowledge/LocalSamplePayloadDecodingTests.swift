// LocalSamplePayloadDecodingTests.swift
//
// WP-19: pins the decode contract LocalSamplePayloadDecoding.swift's header
// documents against the exact wire shape `SyncEngine`/`BackfillCoordinator`
// emit (`values`, and `sessionPayload` as base64-encoded JSON with
// `exercise.*` dotted keys) -- the same fixture shape
// `ActivitiesModels.FitbitActivitySupplement`'s own tests already pin at the
// app-target layer.

@testable import CoachKit
import CoreModel
import Foundation
import Testing

@Suite("ExerciseSupplement decoding")
struct ExerciseSupplementTests {
    private func envelope(sessionPayload: [String: Any]?) -> Data {
        var envelope: [String: Any] = ["id": "ext-1", "dataType": "exercise", "values": [String: Double]()]
        if let sessionPayload {
            let sessionData = try! JSONSerialization.data(withJSONObject: sessionPayload)
            envelope["sessionPayload"] = sessionData.base64EncodedString()
        }
        return try! JSONSerialization.data(withJSONObject: envelope)
    }

    // catches: the coach's workout supplement losing the real exercise
    // object's fields (WP-51 shape: exerciseType + metricsSummary in mm/kcal).
    @Test("decodes the API's typed exercise object")
    func fullDecode() {
        let payload = envelope(sessionPayload: [
            "exerciseType": "HIIT",
            "displayName": "High Intensity Interval Training",
            "metricsSummary": ["distanceMillimeters": 1_200_500.0, "caloriesKcal": 340.0],
        ])
        let sample = LocalSample(
            externalID: "ext-1", dataType: "exercise", payloadJSON: payload,
            start: .now, end: .now.addingTimeInterval(1800), source: "Fitbit Air",
            linkedWatchWorkoutUUID: UUID()
        )
        let supplement = ExerciseSupplement(sample: sample)
        #expect(supplement.activityName == "High Intensity Interval Training")
        #expect(supplement.distanceMeters == 1200.5)
        #expect(supplement.energyKilocalories == 340.0)
        #expect(supplement.linkedWatchWorkoutUUID == sample.linkedWatchWorkoutUUID)
    }

    @Test("missing sessionPayload degrades to nil fields, never throws")
    func missingSessionPayload() {
        let sample = LocalSample(
            externalID: "ext-2", dataType: "exercise", payloadJSON: envelope(sessionPayload: nil),
            start: .now, end: .now, source: "Fitbit Air"
        )
        let supplement = ExerciseSupplement(sample: sample)
        #expect(supplement.activityName == nil)
        #expect(supplement.distanceMeters == nil)
        #expect(supplement.energyKilocalories == nil)
    }

    @Test("garbage payloadJSON degrades to nil fields, never throws")
    func garbagePayload() {
        let sample = LocalSample(
            externalID: "ext-3", dataType: "exercise", payloadJSON: Data([0xFF, 0x00, 0x12]),
            start: .now, end: .now, source: "Fitbit Air"
        )
        let supplement = ExerciseSupplement(sample: sample)
        #expect(supplement.activityName == nil)
    }
}

@Suite("sumPayloadValues")
struct SumPayloadValuesTests {
    @Test("sums every numeric value in the top-level values dict")
    func sumsAllValues() {
        let payload = try! JSONSerialization.data(withJSONObject: ["values": ["a": 5, "b": 7.5]])
        let sample = LocalSample(
            externalID: "ext-4", dataType: "active_zone_minutes", payloadJSON: payload,
            start: .now, end: .now, source: "Fitbit Air"
        )
        #expect(sumPayloadValues(sample) == 12.5)
    }

    @Test("missing values dict sums to zero, never throws")
    func missingValues() {
        let payload = try! JSONSerialization.data(withJSONObject: ["dataType": "active_zone_minutes"])
        let sample = LocalSample(
            externalID: "ext-5", dataType: "active_zone_minutes", payloadJSON: payload,
            start: .now, end: .now, source: "Fitbit Air"
        )
        #expect(sumPayloadValues(sample) == 0)
    }

    @Test("empty payloadJSON sums to zero, never throws")
    func emptyPayload() {
        let sample = LocalSample(
            externalID: "ext-6", dataType: "active_zone_minutes", payloadJSON: Data(),
            start: .now, end: .now, source: "Fitbit Air"
        )
        #expect(sumPayloadValues(sample) == 0)
    }
}
