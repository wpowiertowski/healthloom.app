// DisclaimerTests.swift
//
// WP-38 launch gate: the non-medical disclaimer must be present in
// onboarding (WelcomeView footnote, pre-consent) AND in the SafetyLayer
// suffix (generation time). Both sides pin the FULL string (third-party
// F6) — a substring assert would stay green through a quiet rewrite of
// the surrounding promise.
//
// The footnote constant is asserted directly because the full onboarding
// UI flow is quarantined (HealthKit sheet, PR #7). Its rendering is
// covered twice: OnboardingUITests' disclaimer test (visible + hittable
// in the running app) and OnboardingSnapshotTests (pixels at XS/XL/AXXXL).

import CoachKit
import Foundation
import Testing
@testable import HealthLoom

@Suite("Launch disclaimer (both surfaces)")
struct DisclaimerTests {
    @Test("welcome footnote is the approved pre-consent text, verbatim")
    func onboardingFootnote() {
        #expect(OnboardingDisclaimer.welcomeFootnote == """
            HealthLoom is a wellness coach, not a medical professional. \
            Nothing here is medical advice, diagnosis, or treatment — talk \
            to a qualified clinician about symptoms, medications, or whether \
            to seek care.
            """)
    }

    @Test("safety suffix is the approved generation-time text, verbatim")
    func safetyLayer() {
        #expect(SafetyLayer.text == """
            Safety guidance (not editable, always applies): I am a wellness coach, \
            not a medical professional, and nothing I say is medical advice, diagnosis, \
            or treatment. I do not diagnose conditions and I do not interpret ECG, \
            atrial-fibrillation, irregular-rhythm, blood-oxygen, or other clinical \
            readings -- for any question about those, or about symptoms, medications, \
            or whether to seek care, I recommend talking to a qualified clinician promptly. \
            I stay within general fitness, sleep, activity, and healthy-habit coaching, \
            and I say so when a request is outside that scope. If someone shows signs \
            of disordered eating or an unhealthy relationship with food, exercise, or \
            body image, I encourage reaching out to a trusted healthcare professional \
            or support resource.
            """)
    }
}
