// OnboardingCompletionTests.swift
//
// WP-50: onboarding runs once per install, until "Disconnect & wipe".

import Foundation
import Testing
@testable import HealthLoom

@Suite("Onboarding completion")
struct OnboardingCompletionTests {
    // catches: every cold launch onboarding again (the bug), and a finished
    // flag not being read on the normal launch route.
    @Test func normalLaunchHonoursTheFlag() throws {
        let ephemeral = try EphemeralDefaults(prefix: "onboarding")
        let completion = OnboardingCompletion(defaults: ephemeral.defaults)
        #expect(!OnboardingCompletion.startsInApp(route: .default, completion: completion))
        completion.markCompleted()
        #expect(OnboardingCompletion.startsInApp(route: .default, completion: completion))
    }

    // catches: a flag left in the simulator by one UI test run skipping the
    // next run's onboarding. With persistence off the route alone decides.
    @Test func persistenceOffIgnoresTheRoutesFlag() {
        #expect(!OnboardingCompletion.startsInApp(route: .default, completion: nil))
        #expect(!OnboardingCompletion.startsInApp(route: .onboardingGoogle, completion: nil))
    }

    // catches: an explicit onboarding route (the skip-Google UI test) being
    // bypassed because the flag happens to be set.
    @Test func explicitOnboardingRouteAlwaysOnboards() throws {
        let ephemeral = try EphemeralDefaults(prefix: "onboarding")
        let completion = OnboardingCompletion(defaults: ephemeral.defaults)
        completion.markCompleted()
        #expect(!OnboardingCompletion.startsInApp(route: .onboardingGoogle, completion: completion))
    }

    // catches: the seeded UI-test tab routes suddenly requiring onboarding.
    @Test func tabRoutesStartInTheApp() {
        for route in [InitialRoute.data, .coach, .settings, .you] {
            #expect(OnboardingCompletion.startsInApp(route: route, completion: nil), "\(route)")
        }
    }

    // catches: the flag moving somewhere "Disconnect & wipe" doesn't reach
    // (Keychain, another suite) -- the wipe removes the app's whole defaults
    // domain, and onboarding must come back after it.
    @Test func removingTheDefaultsDomainBringsOnboardingBack() throws {
        let ephemeral = try EphemeralDefaults(prefix: "onboarding")
        OnboardingCompletion(defaults: ephemeral.defaults).markCompleted()
        ephemeral.defaults.removePersistentDomain(forName: ephemeral.suiteName)
        let afterWipe = OnboardingCompletion(defaults: ephemeral.defaults)
        #expect(!afterWipe.isCompleted)
        #expect(!OnboardingCompletion.startsInApp(route: .default, completion: afterWipe))
    }
}
