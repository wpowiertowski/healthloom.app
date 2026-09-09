import Foundation
import Testing
@testable import GoogleHealthClient

@Test func moduleNamePlaceholder() async throws {
    #expect(GoogleHealthClientPlaceholder.moduleName == "GoogleHealthClient")
    #expect(GoogleHealthClientPlaceholder.dependsOn == ["CoreModel", "Secrets"])
}

@Test("default base URL is the Google Health API, never the legacy Fitbit host (WP-38)")
func defaultBaseURLIsGoogleHealth() {
    #expect(GoogleHealthClientConfig.defaultBaseURL == "https://health.googleapis.com/v4/")
    #expect(GoogleHealthClientConfig().baseURL == GoogleHealthClientConfig.defaultBaseURL)
}

@Test("reconcile requests go to the default base URL, not a legacy host (third-party F13)")
func reconcileUsesDefaultBaseURL() async throws {
    let http = RecordingHTTPSession { request, _ in
        if TestClientFactory.isTokenRequest(request) {
            return (TestClientFactory.tokenJSON(), httpResponse(statusCode: 200))
        }
        return (await Fixture.data("paged-steps-p1"), httpResponse(statusCode: 200))
    }
    let client = TestClientFactory.client(http: http)
    let since = Date(timeIntervalSince1970: 1_800_000_000)
    _ = try await client.reconcile(type: .steps, since: since, until: since.addingTimeInterval(3600))
    let dataRequests = await http.requests.filter { !TestClientFactory.isTokenRequest($0) }
    let url = try #require(dataRequests.first?.url?.absoluteString)
    #expect(url.hasPrefix(GoogleHealthClientConfig.defaultBaseURL))
    #expect(!url.contains("fitbit"))
}
