// GoogleHealthRequestTests.swift
//
// WP-51: the request shape the published v4 reference specifies -- GET with
// an empty body, kebab-case type in the path, `:reconcile` unless the type
// isn't reconcilable, and an AIP-160 `filter` whose field follows the
// type's time shape (snake-case prefix). The pre-WP-51 client POSTed a JSON
// body and got 404 for every type.

import CoreModel
import Foundation
import Testing
@testable import GoogleHealthClient

@Suite("Google Health requests")
struct GoogleHealthRequestTests {
    /// 2027-01-15T08:00:00Z; the window runs three hours.
    private static let since = Date(timeIntervalSince1970: 1_800_000_000)
    private static let until = since.addingTimeInterval(3 * 3600)

    private static func schema(_ type: GoogleDataType) throws -> GoogleDataTypeSchema {
        try #require(GoogleDataTypeSchema.schema(for: type), "\(type) has no schema")
    }

    // catches: a window on the wrong field for the type's time shape -- the
    // API rejects or silently empties a filter on a field the type lacks.
    @Test func filterFieldFollowsTheTimeShape() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(try Self.schema(.steps).filter(since: Self.since, until: Self.until, timeZone: utc)
            == #"steps.interval.start_time >= "2027-01-15T08:00:00Z" AND steps.interval.start_time < "2027-01-15T11:00:00Z""#)
        #expect(try Self.schema(.heartRate).filter(since: Self.since, until: Self.until, timeZone: utc)
            == #"heart_rate.sample_time.physical_time >= "2027-01-15T08:00:00Z" AND heart_rate.sample_time.physical_time < "2027-01-15T11:00:00Z""#)
        #expect(try Self.schema(.sleep).filter(since: Self.since, until: Self.until, timeZone: utc)
            == #"sleep.interval.end_time >= "2027-01-15T08:00:00Z" AND sleep.interval.end_time < "2027-01-15T11:00:00Z""#)
        #expect(try Self.schema(.electrocardiogram).filter(since: Self.since, until: Self.until, timeZone: utc)
            == #"electrocardiogram.interval.start_time >= "2027-01-15T08:00:00Z""#)
    }

    // catches: civil times and dates read in UTC instead of the wearer's zone
    // (a Los Angeles evening would land on the wrong day), and today's daily
    // summary excluded by an exclusive upper bound.
    @Test func civilFiltersUseTheWearersZone() throws {
        let la = try #require(TimeZone(identifier: "America/Los_Angeles"))
        #expect(try Self.schema(.exercise).filter(since: Self.since, until: Self.until, timeZone: la)
            == #"exercise.interval.civil_start_time >= "2027-01-15T00:00:00" AND exercise.interval.civil_start_time < "2027-01-15T03:00:00""#)
        #expect(try Self.schema(.dailyRestingHeartRate).filter(since: Self.since, until: Self.until, timeZone: la)
            == #"daily_resting_heart_rate.date >= "2027-01-15" AND daily_resting_heart_rate.date < "2027-01-16""#)
    }

    private static func recordedRequest(for type: GoogleDataType) async throws -> URLRequest {
        let http = RecordingHTTPSession { request, _ in
            if TestClientFactory.isTokenRequest(request) {
                return (TestClientFactory.tokenJSON(), httpResponse(statusCode: 200))
            }
            return (Data(#"{"dataPoints":[]}"#.utf8), httpResponse(statusCode: 200))
        }
        _ = try await TestClientFactory.client(http: http).reconcile(type: type, since: since, until: until)
        let requests = await http.requests.filter { !TestClientFactory.isTokenRequest($0) }
        return try #require(requests.first)
    }

    // catches: the POST-with-body shape that 404'd, and the type missing its
    // kebab-case path or the `:reconcile` suffix.
    @Test func reconcileIsAGetWithAQuery() async throws {
        let request = try await Self.recordedRequest(for: .heartRate)
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.url?.path == "/v4/users/me/dataTypes/heart-rate/dataPoints:reconcile")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer data-access-token")
        #expect(TestClientFactory.query("filter", in: request)?.hasPrefix("heart_rate.sample_time.physical_time") == true)
        #expect(TestClientFactory.query("pageSize", in: request) == "1000")
    }

    // catches: ECG sent to `:reconcile`, which doesn't serve it, and sessions
    // asking for more than the API's 25-per-page cap.
    @Test func nonReconcilableTypesAreListedAndSessionsPageBy25() async throws {
        let ecg = try await Self.recordedRequest(for: .electrocardiogram)
        #expect(ecg.url?.path == "/v4/users/me/dataTypes/electrocardiogram/dataPoints")
        let sleep = try await Self.recordedRequest(for: .sleep)
        #expect(TestClientFactory.query("pageSize", in: sleep) == "25")
    }

    // catches: a type Google only offers through roll-ups (or that isn't a
    // time series) hitting the network and logging a bare 404.
    @Test(arguments: [GoogleDataType.totalCalories, .caloriesInHeartRateZone, .food])
    func unreadableTypesSayWhyWithoutANetworkCall(type: GoogleDataType) async {
        await #expect(throws: GoogleHealthClientError.notAvailableFromGoogle) {
            _ = try await TestClientFactory.inertClient().reconcile(type: type, since: Self.since, until: Self.until)
        }
    }

    // catches: a synced type left without a schema row, so it would never
    // decode. Every type the app syncs is readable, except the three that
    // Google only offers some other way.
    @Test func everySyncedTypeHasASchemaRow() {
        let notReadable: Set<GoogleDataType> = [.totalCalories, .caloriesInHeartRateZone, .food]
        for type in GoogleDataType.allCases where type.writability != .skip && !notReadable.contains(type) {
            #expect(GoogleDataTypeSchema.schema(for: type) != nil, "\(type)")
        }
    }

    // catches: the response union key not matching the type (the decoder
    // would report every point as missing its object).
    @Test func unionKeyIsTheCamelCaseName() {
        #expect(GoogleDataTypeSchema.unionKey(for: .heartRate) == "heartRate")
        #expect(GoogleDataTypeSchema.unionKey(for: .runVO2Max) == "runVo2Max")
        #expect(GoogleDataTypeSchema.unionKey(for: .dailyRestingHeartRate) == "dailyRestingHeartRate")
        #expect(GoogleDataTypeSchema.unionKey(for: .steps) == "steps")
    }

    // catches: IDs that change between syncs (the pipeline's "already
    // written" check would write duplicates every run), and two heart-rate
    // zones of one interval colliding on one ID.
    @Test func derivedIDsAreStableAndDistinct() throws {
        let body = Data(#"""
        {"dataPoints":[
          {"activeZoneMinutes":{"interval":{"startTime":"2026-07-01T08:00:00Z","endTime":"2026-07-01T09:00:00Z"},"heartRateZone":"FAT_BURN","activeZoneMinutes":"12"}},
          {"activeZoneMinutes":{"interval":{"startTime":"2026-07-01T08:00:00Z","endTime":"2026-07-01T09:00:00Z"},"heartRateZone":"CARDIO","activeZoneMinutes":"4"}}
        ]}
        """#.utf8)
        let client = TestClientFactory.inertClient()
        let first = try client.decodePage(body, type: .activeZoneMinutes).points.map(\.id)
        let again = try client.decodePage(body, type: .activeZoneMinutes).points.map(\.id)
        #expect(first == again)
        #expect(Set(first).count == 2)
    }

    // catches: listed points (which do carry a source) losing the device name
    // the Activities view shows ("Fitbit Air").
    @Test func listedPointsKeepTheirSource() throws {
        let body = Data(#"""
        {"dataPoints":[{"name":"users/me/dataTypes/electrocardiogram/dataPoints/9",
          "dataSource":{"platform":"FITBIT","recordingMethod":"ACTIVELY_MEASURED","device":{"displayName":"Fitbit Air"}},
          "electrocardiogram":{"interval":{"startTime":"2026-07-01T08:00:00Z","endTime":"2026-07-01T08:00:30Z"},"beatsPerMinuteAvg":"64"}}]}
        """#.utf8)
        let page = try TestClientFactory.inertClient().decodePage(body, type: .electrocardiogram)
        let point = try #require(page.points.first)
        #expect(point.id == "users/me/dataTypes/electrocardiogram/dataPoints/9")
        #expect(point.source.deviceDisplayName == "Fitbit Air")
        #expect(point.source.platform == "FITBIT")
        #expect(point.values == ["bpm": 64])
    }
}
