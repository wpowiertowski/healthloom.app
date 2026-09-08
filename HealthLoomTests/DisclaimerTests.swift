// DisclaimerTests.swift
//
// WP-38 launch gate: the non-medical disclaimer must be present in
// onboarding (WelcomeView footnote, pre-consent) AND in the SafetyLayer
// suffix (generation time). Both sides pinned here — the onboarding UI
// test is quarantined (HealthKit sheet, PR #7), so the footnote constant
// is asserted directly; its rendering rides the scaffold snapshot path.

import CoachKit
import Foundation
import Testing
@testable import HealthLoom

@Suite("Launch disclaimer (both surfaces)")
struct DisclaimerTests {
    @Test("welcome footnote names the non-medical boundary")
    func onboardingFootnote() {
        let footnote = OnboardingDisclaimer.welcomeFootnote
        #expect(footnote.contains("not a medical professional"))
        #expect(footnote.contains("medical advice"))
        #expect(footnote.contains("clinician"))
    }

    @Test("safety suffix names the non-medical boundary")
    func safetyLayer() {
        #expect(SafetyLayer.text.contains("not a medical professional"))
        #expect(SafetyLayer.text.contains("medical advice"))
        #expect(SafetyLayer.text.contains("clinician"))
    }

}
