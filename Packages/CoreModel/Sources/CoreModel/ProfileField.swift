// ProfileField.swift
// CoreModel
//
// The atomic unit of `KnowledgeProfile` (WP-19) and, filtered, of `HealthContext`
// (WP-20). See implementation-plan.md WP-02 step 2 and architecture.md D7/D8.

import Foundation

/// One derived (or user-pinned) fact about the user, in the human-readable,
/// source-tagged, timestamped shape architecture.md D7 requires for AI context —
/// display text a person could read directly, never a raw value dump.
nonisolated public struct ProfileField: Codable, Sendable, Hashable {
    /// Stable identifier for this field (e.g. `"steps.dailyAverage30d"`), used for
    /// correction-pinning (WP-19/WP-30 "Correct") and exclusion toggles.
    public var key: String

    /// Human-readable text, e.g. `"~8,200 steps/day (30-day avg)"`.
    public var displayText: String

    /// Provenance string, e.g. `"HealthKit · Fitbit Air"`.
    public var source: String

    /// When this field was derived/last updated — powers staleness display and
    /// `HealthContext` freshness.
    public var asOf: Date

    /// User- or policy-level exclusion from AI context (architecture.md D7 "Forget").
    public var excludedFromAI: Bool

    /// Clinical signals (ECG, AFib/IRN-derived fields) — architecture.md D8.
    public var isClinical: Bool

    /// - Parameter excludedFromAI: pass `nil` to get D8's default — clinical fields
    ///   start excluded, non-clinical fields start included. Pass an explicit value to
    ///   override (e.g. the user opted a clinical field back in).
    public init(
        key: String,
        displayText: String,
        source: String,
        asOf: Date,
        excludedFromAI: Bool? = nil,
        isClinical: Bool = false
    ) {
        self.key = key
        self.displayText = displayText
        self.source = source
        self.asOf = asOf
        self.isClinical = isClinical
        // D8: "Clinical signals ... are off by default in the AI context."
        self.excludedFromAI = excludedFromAI ?? isClinical
    }
}
