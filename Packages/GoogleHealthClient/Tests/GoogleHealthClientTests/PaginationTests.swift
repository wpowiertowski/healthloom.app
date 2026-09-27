// PaginationTests.swift
//
// WP-05 required test: "pagination stitches 2 pages, preserves window."
// architecture.md D1 / WP-05 step 4: "the page token continues within that
// window (do not re-derive the window per page)." WP-51: the window and the
// token travel in the GET query (`filter`, `pageToken`), not a body.

import Foundation
import Testing
@testable import GoogleHealthClient

@Suite("GoogleHealthClient pagination")
struct PaginationTests {
    // catches: page 2 re-deriving its window, the page token not being sent,
    // or pages stitching out of order.
    @Test("reconcile stitches 2 pages in order and both requests carry an identical filter window")
    func stitchesTwoPagesWithStableWindow() async throws {
        let http = RecordingHTTPSession { request, _ in
            if TestClientFactory.isTokenRequest(request) {
                return (TestClientFactory.tokenJSON(), httpResponse(statusCode: 200))
            }
            if TestClientFactory.query("pageToken", in: request) == "PAGE2TOKEN" {
                return (await Fixture.data("paged-steps-p2"), httpResponse(statusCode: 200))
            }
            return (await Fixture.data("paged-steps-p1"), httpResponse(statusCode: 200))
        }
        let client = TestClientFactory.client(http: http)

        let since = Date(timeIntervalSince1970: 1_800_000_000)
        let until = since.addingTimeInterval(3 * 3600)

        let page1 = try await client.reconcile(type: .steps, since: since, until: until)
        #expect(page1.points.map { $0.values["count"] } == [200, 300])
        #expect(page1.nextPageToken == "PAGE2TOKEN")

        let page2 = try await client.reconcile(type: .steps, since: since, until: until, pageToken: page1.nextPageToken)
        #expect(page2.points.map { $0.values["count"] } == [150])
        #expect(page2.nextPageToken == nil)

        let stitchedIDs = (page1.points + page2.points).map(\.id)
        #expect(Set(stitchedIDs).count == 3, "each bucket keeps a distinct stable ID")

        let dataRequests = await http.requests.filter { !TestClientFactory.isTokenRequest($0) }
        #expect(dataRequests.count == 2)
        let firstRequest = try #require(dataRequests.first)
        let secondRequest = try #require(dataRequests.last)
        let firstFilter = try #require(TestClientFactory.query("filter", in: firstRequest))
        #expect(TestClientFactory.query("filter", in: secondRequest) == firstFilter)
        #expect(TestClientFactory.query("pageToken", in: firstRequest) == nil)
        #expect(TestClientFactory.query("pageToken", in: secondRequest) == "PAGE2TOKEN")
    }
}
