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

    @Test("decodes activity type, distance, and energy from sessionPayload")
    func fullDecode() {
        let payload = envelope(sessionPayload: [
            "exercise.activity_type": "high_intensity_interval_training",
            "exercise.distance": 1200.5,
            "exercise.energy": 340.0,
        ])
        let sample = LocalSample(
            externalID: "ext-1", dataType: "exercise", payloadJSON: payload,
            start: .now, end: .now.addingTimeInterval(1800), source: "Fitbit Air"
        )
        let fields = sample.decodedExercisePayload
        #expect(fields.activityName == "High Intensity Interval Training")
        #expect(fields.distanceMeters == 1200.5)
        #expect(fields.energyKilocalories == 340.0)
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
