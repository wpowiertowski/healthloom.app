// ResilienceTests.swift
//
// WP-05 required tests: "401→refresh→retry exactly once"; "429 backoff
// schedule (virtual clock)"; malformed JSON is covered in
// GoogleDataPointDecodingTests. test-plan.md §2.4 additionally asks for
// Retry-After to be honored, which is covered here too.

import Foundation
import Testing
@testable import GoogleHealthClient

@Suite("GoogleHealthClient resilience")
struct ResilienceTests {
    @Test("a 401 triggers exactly one forced refresh and one retry, then succeeds")
    func unauthorizedTriggersSingleRefreshAndRetry() async throws {
        let http = RecordingHTTPSession { request, allRequests in
            if TestClientFactory.isTokenRequest(request) {
                return (TestClientFactory.tokenJSON(), httpResponse(statusCode: 200))
            }
            let dataRequestsSoFar = allRequests.filter { !TestClientFactory.isTokenRequest($0) }.count
            if dataRequestsSoFar == 1 {
                return (Data(), httpResponse(statusCode: 401))
            }
            return (await Fixture.data("steps"), httpResponse(statusCode: 200))
        }
        let client = TestClientFactory.client(http: http)

        let page = try await client.reconcile(type: .steps, since: Date(), until: Date())
        #expect(page.points.count == 2)

        let tokenRequestCount = await http.requestCount(urlContains: "oauth2.googleapis.com/token")
        #expect(tokenRequestCount == 2) // initial validAccessToken refresh + forced refresh after 401

        let dataRequestCount = await http.requests.filter { !TestClientFactory.isTokenRequest($0) }.count
        #expect(dataRequestCount == 2) // original request + exactly one retry
    }

    @Test("a persistent 401 throws .unauthorized after exactly one retry (no infinite loop)")
    func persistentUnauthorizedThrowsAfterOneRetry() async throws {
        let http = RecordingHTTPSession { request, _ in
            if TestClientFactory.isTokenRequest(request) {
                return (TestClientFactory.tokenJSON(), httpResponse(statusCode: 200))
            }
            return (Data(), httpResponse(statusCode: 401))
        }
        let client = TestClientFactory.client(http: http)

        do {
            _ = try await client.reconcile(type: .steps, since: Date(), until: Date())
            Issue.record("Expected .unauthorized to be thrown")
        } catch {
            #expect(error == .unauthorized)
        }

        let dataRequestCount = await http.requests.filter { !TestClientFactory.isTokenRequest($0) }.count
        #expect(dataRequestCount == 2) // original + exactly one retry, then give up
    }

    @Test("429 backs off exponentially (base 1s, doubling) until maxAttempts, then throws .rateLimited")
    func backoffScheduleOn429() async throws {
        let sleeper = RecordingSleeper()
        let http = RecordingHTTPSession { request, _ in
            if TestClientFactory.isTokenRequest(request) {
                return (TestClientFactory.tokenJSON(), httpResponse(statusCode: 200))
            }
            return (await Fixture.data("error-429"), httpResponse(statusCode: 429))
        }
        let client = TestClientFactory.client(http: http, sleeper: sleeper, jitter: ZeroJitterSource())

        do {
            _ = try await client.reconcile(type: .steps, since: Date(), until: Date())
            Issue.record("Expected .rateLimited to be thrown")
        } catch {
            #expect(error == .rateLimited)
        }

        // Default BackoffPolicy: baseDelay 1s, maxAttempts 5 -> 5 data
        // requests total, 4 sleeps between them, doubling and uncapped here
        // (well under the 60s cap).
        let durations = await sleeper.recordedDurations
        #expect(durations == [1.0, 2.0, 4.0, 8.0])

        let dataRequestCount = await http.requests.filter { !TestClientFactory.isTokenRequest($0) }.count
        #expect(dataRequestCount == 5)
    }

    @Test("a Retry-After header overrides the exponential schedule for that attempt")
    func honorsRetryAfterHeader() async throws {
        let sleeper = RecordingSleeper()
        let http = RecordingHTTPSession { request, allRequests in
            if TestClientFactory.isTokenRequest(request) {
                return (TestClientFactory.tokenJSON(), httpResponse(statusCode: 200))
            }
            let dataCallIndex = allRequests.filter { !TestClientFactory.isTokenRequest($0) }.count
            if dataCallIndex == 1 {
                return (await Fixture.data("error-429"), httpResponse(statusCode: 429, headers: ["Retry-After": "30"]))
            }
            return (await Fixture.data("steps"), httpResponse(statusCode: 200))
        }
        let client = TestClientFactory.client(http: http, sleeper: sleeper, jitter: ZeroJitterSource())

        let page = try await client.reconcile(type: .steps, since: Date(), until: Date())
        #expect(page.points.count == 2)

        let durations = await sleeper.recordedDurations
        #expect(durations == [30.0])
    }

    @Test("a giant Retry-After is clamped to the cap, never a day-long park")
    func retryAfterClampedToCap() async throws {
        // Round-7 item 8: Retry-After: 86400 must sleep 60s (capDelay),
        // not park foreground Sync Now for a day.
        let sleeper = RecordingSleeper()
        let http = RecordingHTTPSession { request, allRequests in
            if TestClientFactory.isTokenRequest(request) {
                return (TestClientFactory.tokenJSON(), httpResponse(statusCode: 200))
            }
            let dataCallIndex = allRequests.filter { !TestClientFactory.isTokenRequest($0) }.count
            if dataCallIndex == 1 {
                return (await Fixture.data("error-429"), httpResponse(statusCode: 429, headers: ["Retry-After": "86400"]))
            }
            return (await Fixture.data("steps"), httpResponse(statusCode: 200))
        }
        let client = TestClientFactory.client(http: http, sleeper: sleeper, jitter: ZeroJitterSource())
        _ = try await client.reconcile(type: .steps, since: Date(), until: Date())
        #expect(await sleeper.recordedDurations == [60.0])
    }

    @Test("retry-after clamp is exact at the boundary")
    func retryAfterClampBoundary() {
        // Pure-function pin: within-cap wins verbatim, over-cap
        // clamps, negatives floor at zero.
        let policy = BackoffPolicy()
        #expect(policy.delay(forAttempt: 1, retryAfter: 30, jitterFraction: 0) == 30.0)
        #expect(policy.delay(forAttempt: 1, retryAfter: 60, jitterFraction: 0) == 60.0)
        #expect(policy.delay(forAttempt: 1, retryAfter: 86400, jitterFraction: 0) == 60.0)
        #expect(policy.delay(forAttempt: 1, retryAfter: -5, jitterFraction: 0) == 0.0)
        #expect(policy.delay(forAttempt: 1, retryAfter: nil, jitterFraction: 0) == 1.0)
    }

    @Test("5xx also backs off and eventually throws .server with the last status code")
    func backoffScheduleOn5xx() async throws {
        let sleeper = RecordingSleeper()
        let http = RecordingHTTPSession { request, _ in
            if TestClientFactory.isTokenRequest(request) {
                return (TestClientFactory.tokenJSON(), httpResponse(statusCode: 200))
            }
            return (Data(), httpResponse(statusCode: 503))
        }
        let client = TestClientFactory.client(http: http, sleeper: sleeper, jitter: ZeroJitterSource())

        do {
            _ = try await client.reconcile(type: .steps, since: Date(), until: Date())
            Issue.record("Expected .server to be thrown")
        } catch {
            #expect(error == .server(status: 503))
        }
    }
}
