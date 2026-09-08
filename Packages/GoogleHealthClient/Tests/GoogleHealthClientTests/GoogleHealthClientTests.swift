import Testing
@testable import GoogleHealthClient

@Test func moduleNamePlaceholder() async throws {
    #expect(GoogleHealthClientPlaceholder.moduleName == "GoogleHealthClient")
    #expect(GoogleHealthClientPlaceholder.dependsOn == ["CoreModel", "Secrets"])
}

@Test("default base URL is the Google Health API, never the legacy Fitbit host (WP-38)")
func defaultBaseURLIsGoogleHealth() {
    let config = GoogleHealthClientConfig()
    #expect(config.baseURL == "https://health.googleapis.com/v4/")
    #expect(!config.baseURL.contains("fitbit"))
}
