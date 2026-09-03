// SafetyLayer.swift
// CoachKit
//
// WP-21 (implementation-plan.md) / architecture.md D10: the immutable safety
// suffix appended after every user-editable base prompt. Written once, never
// edited at runtime, never stored in `PromptVersion` rows -- only appended at
// use time by `PromptManager.effectivePrompt(base:)` so the suffix survives
// prompt edits, resets, and (WP-28/D15) mid-conversation tier switches.

import Foundation

/// Namespace for the immutable, non-editable safety suffix (D10).
public enum SafetyLayer {
    /// The exact suffix appended after the user's base prompt. Covers the
    /// WP-21 step-1 requirements: non-medical disclaimer, no-diagnosis /
    /// no-ECG-AFib-interpretation rule with clinician redirect, scope limits,
    /// and a disordered-eating help-seeking nudge.
    ///
    /// Owner-reviewed and approved 2026-09-03 (see progress.md WP-21) --
    /// treat any edit here as a product/clinical decision requiring
    /// re-review before launch, not a code-review call.
    public static let text = """
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
        """
}
