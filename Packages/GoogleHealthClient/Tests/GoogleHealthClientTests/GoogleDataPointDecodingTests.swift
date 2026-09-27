// GoogleDataPointDecodingTests.swift
//
// WP-51: decoding the real Google Health API v4 response -- `dataPoints[]`
// of typed union members (`heartRate: {sampleTime, beatsPerMinute}` ...).
// Fixtures under Fixtures/GoogleHealth follow the published reference; each
// records its provenance in a `_comment`. The contract that matters is the
// output: the value names and units TypeMapper reads (`bpm`, `count`,
// `mass` in kg ...), which these tests pin per type.

import CoreModel
import Foundation
import Testing
@testable import GoogleHealthClient

@Suite("GoogleDataPoint decoding")
struct GoogleDataPointDecodingTests {
    private static func date(_ string: String) throws -> Date {
        try #require(ISO8601Formatting.date(from: string))
    }

    // catches: any synced type's response fields or units drifting from what
    // TypeMapper reads -- the pre-WP-51 client read a flat `value{}` that
    // the real API never sends. One row per fixture, values in the units
    // TypeMapper expects.
    @Test("each fixture decodes to TypeMapper's value names and units", arguments: [
        ("steps", GoogleDataType.steps, ["count": 482.0]),
        ("floors", .floors, ["count": 6]),
        ("distance", .distance, ["distance": 15]),
        ("active-energy-burned", .activeEnergyBurned, ["kcal": 312.5]),
        ("heart-rate", .heartRate, ["bpm": 58]),
        ("daily-resting-heart-rate", .dailyRestingHeartRate, ["bpm": 52]),
        ("heart-rate-variability", .heartRateVariability, ["rmssd_ms": 38.2]),
        ("oxygen-saturation", .oxygenSaturation, ["percentage": 97]),
        ("respiratory-rate", .respiratoryRateSleepSummary, ["breathsPerMinute": 14.5]),
        ("vo2-max", .vo2Max, ["value": 42.3]),
        ("run-vo2-max", .runVO2Max, ["value": 45.1]),
        ("weight", .weight, ["mass": 70.5]),
        ("height", .height, ["meters": 1.78]),
        ("body-fat", .bodyFat, ["percentage": 22]),
        ("blood-glucose-mgdl", .bloodGlucose, ["mg_per_dl": 98]),
        ("core-body-temperature", .coreBodyTemperature, ["celsius": 37.1]),
        ("hydration-log", .hydrationLog, ["liters": 0.5]),
        ("nutrition-log", .nutritionLog, ["energy_kcal": 650, "carbs_g": 70, "fat_g": 22, "protein_g": 35]),
        ("nutrition-log-partial", .nutritionLog, ["energy_kcal": 120, "protein_g": 18]),
    ])
    func decodesToTypeMapperContract(fixture: String, type: GoogleDataType, expected: [String: Double]) async throws {
        let page = try TestClientFactory.inertClient().decodePage(await Fixture.data(fixture), type: type)
        let first = try #require(page.points.first, "\(fixture): no points")
        #expect(first.dataType == type)
        #expect(first.values.count == expected.count, "\(fixture): \(first.values.keys.sorted())")
        for (key, value) in expected {
            let actual = try #require(first.values[key], "\(fixture): missing \(key)")
            #expect(abs(actual - value) < 1e-9, "\(fixture).\(key) = \(actual)")
        }
    }

    // catches: interval times not read from `interval`, and a steps bucket
    // losing its bounds or picking up a payload it shouldn't carry.
    @Test func stepsIntervalsAndSource() async throws {
        let page = try TestClientFactory.inertClient().decodePage(await Fixture.data("steps"), type: .steps)
        #expect(page.nextPageToken == nil)
        #expect(page.points.count == 2)
        let first = try #require(page.points.first)
        #expect(first.start == (try Self.date("2026-07-01T00:00:00Z")))
        #expect(first.end == (try Self.date("2026-07-01T01:00:00Z")))
        #expect(first.sessionPayload == nil)
        // Reconciled points carry no `dataSource`; they're labelled honestly.
        #expect(first.source.platform == "Google Health")
        #expect(first.source.deviceDisplayName == nil)
    }

    // catches: an instant sample read as a window (sampleTime → start == end).
    @Test func sampleTimeIsAnInstant() async throws {
        let page = try TestClientFactory.inertClient().decodePage(await Fixture.data("heart-rate"), type: .heartRate)
        let first = try #require(page.points.first)
        #expect(first.start == (try Self.date("2026-07-01T07:30:00Z")))
        #expect(first.start == first.end)
    }

    // catches: a daily summary not spanning its civil day in the user's zone.
    @Test func dailySummarySpansItsCivilDay() async throws {
        var config = GoogleHealthClientConfig()
        config.civilTimeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let client = TestClientFactory.inertClient(config: config)
        let page = try client.decodePage(await Fixture.data("daily-resting-heart-rate"), type: .dailyRestingHeartRate)
        let first = try #require(page.points.first)
        #expect(first.start == (try Self.date("2026-07-01T07:00:00Z")))
        #expect(first.end == (try Self.date("2026-07-02T07:00:00Z")))
    }

    // catches: the session's typed object not reaching the session decoders
    // (they read stages from `sessionPayload`), or its API name not used as
    // the ID when the API provides one.
    @Test func sleepSessionKeepsItsTypedObject() async throws {
        let page = try TestClientFactory.inertClient().decodePage(await Fixture.data("sleep"), type: .sleep)
        let point = try #require(page.points.first)
        #expect(point.id == "users/me/dataTypes/sleep/dataPoints/1111111111111111111")
        #expect(point.start == (try Self.date("2026-07-08T23:15:00Z")))
        #expect(point.end == (try Self.date("2026-07-09T06:45:00Z")))
        #expect(point.values.isEmpty)
        let payload = try #require(point.sessionPayload)
        let object = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let stages = try #require(object["stages"] as? [[String: Any]])
        #expect(stages.count == 5)
        #expect(stages.first?["type"] as? String == "AWAKE")
    }

    // catches: garbage bodies surfacing as anything but a typed error.
    @Test func malformedJSONThrowsTypedError() {
        #expect(throws: GoogleHealthClientError.decodingFailed("invalid JSON")) {
            try TestClientFactory.inertClient().decodePage(Data("{not valid json".utf8), type: .steps)
        }
    }

    // catches: a point without its union object decoding to an empty sample
    // instead of a named reason in the Sync Log.
    @Test func missingUnionObjectNamesIt() {
        let body = Data(#"{"dataPoints":[{"dataPointName":""}]}"#.utf8)
        #expect(throws: GoogleHealthClientError.decodingFailed("steps: missing steps")) {
            try TestClientFactory.inertClient().decodePage(body, type: .steps)
        }
    }

    // catches: a renamed value field (the pre-WP-51 bug class) writing empty
    // samples silently -- it must name what it expected, never a value.
    @Test func unrecognisedValueFieldsNameTheExpectedKeys() {
        let body = Data(#"{"dataPoints":[{"heartRate":{"sampleTime":{"physicalTime":"2026-07-01T07:30:00Z"},"bpm":"58"}}]}"#.utf8)
        #expect(throws: GoogleHealthClientError.decodingFailed("heart_rate: none of bpm found")) {
            try TestClientFactory.inertClient().decodePage(body, type: .heartRate)
        }
    }

    // catches: a missing time field decoding to a zero date.
    @Test func missingTimeFieldNamesIt() {
        let body = Data(#"{"dataPoints":[{"weight":{"weightGrams":70500}}]}"#.utf8)
        #expect(throws: GoogleHealthClientError.decodingFailed("weight: missing sampleTime.physicalTime")) {
            try TestClientFactory.inertClient().decodePage(body, type: .weight)
        }
    }
}
