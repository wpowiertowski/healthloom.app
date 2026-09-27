// ExercisePayloadDecodingTests.swift
//
// Code review (2026-08-28) finding #14: pins the shared decode contract now
// used by both CoachKit's `ExerciseSupplement` and the app target's
// `FitbitActivitySupplement`.

import Foundation
import Testing
@testable import CoreModel

@Suite("LocalSample.decodedExercisePayload")
struct ExercisePayloadDecodingTests {
    private func envelope(sessionPayload: [String: Any]?) -> Data {
        var envelope: [String: Any] = ["id": "ext-1", "dataType": "exercise", "values": [String: Double]()]
        if let sessionPayload {
            let sessionData = try! JSONSerialization.data(withJSONObject: sessionPayload)
            envelope["sessionPayload"] = sessionData.base64EncodedString()
        }
        return try! JSONSerialization.data(withJSONObject: envelope)
    }

    // catches: the real exercise object (WP-51) decoding to nothing -- type,
    // title, distance (millimeters → meters) and energy all come from it.
    @Test("decodes the API's typed exercise object")
    func fullDecode() {
        let payload = envelope(sessionPayload: [
            "exerciseType": "TRAIL_RUN",
            "displayName": "Morning trail run",
            "metricsSummary": ["distanceMillimeters": 1_200_500.0, "caloriesKcal": 340.0],
        ])
        let sample = LocalSample(
            externalID: "ext-1", dataType: "exercise", payloadJSON: payload,
            start: .now, end: .now.addingTimeInterval(1800), source: "Fitbit Air"
        )
        let fields = sample.decodedExercisePayload
        #expect(fields.activityName == "Morning trail run")
        #expect(fields.exerciseType == "TRAIL_RUN")
        #expect(fields.distanceMeters == 1200.5)
        #expect(fields.energyKilocalories == 340.0)
    }

    // catches: an activity without `displayName` rendering untitled -- the
    // enum is title-cased instead.
    @Test("falls back to the title-cased exercise type")
    func titleFallsBackToType() {
        let payload = envelope(sessionPayload: ["exerciseType": "TRAIL_RUN"])
        let sample = LocalSample(
            externalID: "ext-2", dataType: "exercise", payloadJSON: payload,
            start: .now, end: .now.addingTimeInterval(1800), source: "Fitbit Air"
        )
        #expect(sample.decodedExercisePayload.activityName == "Trail Run")
    }

    @Test("missing sessionPayload degrades to nil fields, never throws")
    func missingSessionPayload() {
        let sample = LocalSample(
            externalID: "ext-2", dataType: "exercise", payloadJSON: envelope(sessionPayload: nil),
            start: .now, end: .now, source: "Fitbit Air"
        )
        let fields = sample.decodedExercisePayload
        #expect(fields.activityName == nil)
        #expect(fields.distanceMeters == nil)
        #expect(fields.energyKilocalories == nil)
    }

    @Test("garbage payloadJSON degrades to nil fields, never throws")
    func garbagePayload() {
        let sample = LocalSample(
            externalID: "ext-3", dataType: "exercise", payloadJSON: Data([0xFF, 0x00, 0x12]),
            start: .now, end: .now, source: "Fitbit Air"
        )
        #expect(sample.decodedExercisePayload.activityName == nil)
    }
}
