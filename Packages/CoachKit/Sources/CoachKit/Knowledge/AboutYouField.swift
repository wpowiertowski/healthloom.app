// AboutYouField.swift
//
// WP-61: what the user tells the coach about themselves on the You tab --
// goals, injuries and limits, activity preferences. Each is a
// correction-sourced profile field under a fixed key (`setAboutYou`), so
// it rides the machinery user goals already had: it survives every
// `refresh()`, sorts ahead of every derived rank when the context is
// trimmed (`ContextAssembler.orderingRank`), and reaches the model inside
// the health-context block framed as data, not instructions.

import Foundation

public enum AboutYouField: String, CaseIterable, Sendable {
    case goals = "user.goals"
    case injuries = "user.injuries"
    case activityPreferences = "user.activityPreferences"

    /// The profile key it's stored under. The model sees it beside the
    /// text, so it names what the text is.
    public var key: String { rawValue }

    /// Longest entry kept, in characters. Standalone user fields are the
    /// last dropped when the context is trimmed, so three long entries
    /// could otherwise crowd out the health data they're meant to add to.
    public static let maxLength = 300

    /// Whether a profile key belongs to one of these fields.
    public static func isAboutYou(_ key: String) -> Bool {
        AboutYouField(rawValue: key) != nil
    }
}
