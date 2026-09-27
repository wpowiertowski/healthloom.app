// GoogleOAuthClientTests.swift
//
// P-1.3: the real Google Cloud iOS OAuth client is wired in. Its redirect
// scheme is derived in code (`GoogleAuthConfig.iOSClient`) but must also be
// registered statically in the app's Info.plist (`project.yml`), or the
// consent sheet completes at Google and never returns to the app.

import Foundation
import GoogleHealthClient
import Testing
@testable import HealthLoom

@Suite("Google OAuth client")
struct GoogleOAuthClientTests {
    // catches: project.yml's CFBundleURLSchemes drifting from the client's
    // reversed-ID redirect -- sign-in would open and never come back.
    @Test func infoPlistRegistersTheRedirectScheme() throws {
        let urlTypes = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        let schemes = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(schemes.contains(AppEnvironment.googleAuthConfig.redirectURIScheme))
    }

    // catches: the placeholder (or a web/desktop client) shipping instead of
    // the iOS client, whose redirect Google validates against the bundle.
    @Test func configIsTheIOSClient() {
        let config = AppEnvironment.googleAuthConfig
        #expect(config.clientID.hasSuffix(".apps.googleusercontent.com"))
        #expect(config.redirectURI == "\(config.redirectURIScheme):/oauth2redirect")
        #expect(config.redirectURIScheme.hasPrefix("com.googleusercontent.apps."))
    }
}
