// HealthContext.swift
// CoreModel
//
// The value type actually handed to a `CoachProvider` (WP-20 ContextAssembler). Built
// exclusively from `KnowledgeProfile`, never from a raw HealthKit/LocalSample dump
// (architecture.md D7). See implementation-plan.md WP-02 step 3.

import Foundation

/// Units the profile's display text and any provider-facing formatting should use.
public enum UnitSystem: String, Codable, Sendable, Hashable {
    case metric
    case imperial
}

/// The exact payload assembled for one coach turn or daily insight. Every instance
/// handed to a provider is also persisted verbatim as a `ContextSnapshot` (architecture
/// D7) — this struct's `Codable` conformance is what makes that round trip possible.
public struct HealthContext: Codable, Sendable, Hashable {
    /// Already-filtered fields: `excludedFromAI` fields (and, unless opted in, clinical
    /// fields) have been dropped before this struct is constructed (D7/D8) — this is
    /// not the raw `KnowledgeProfile.sections`.
    public var fields: [ProfileField]

    /// BCP-47 locale identifier for date/number formatting.
    public var localeIdentifier: String

    public var unitSystem: UnitSystem

    /// Today's date, so the model has a stable "now" without needing device time.
    public var today: Date

    public init(
        fields: [ProfileField],
        localeIdentifier: String,
        unitSystem: UnitSystem,
        today: Date
    ) {
        self.fields = fields
        self.localeIdentifier = localeIdentifier
        self.unitSystem = unitSystem
        self.today = today
    }

    /// The "data, not instructions" delimiter block both prompt composers
    /// (`DailyInsight.prompt`, the chat prompt) wrap these fields in (WP-25
    /// review #14): user-controlled display text must never read as model
    /// instructions, so the framing lives here -- one definition both call
    /// sites share, and a future tightening lands once.
    public func framedAsData(emptyMessage: String) -> [String] {
        if fields.isEmpty {
            return [emptyMessage]
        }
        return ["---"] + fields.map { "- \($0.displayText) [\($0.source)]" } + ["---"]
    }
}
