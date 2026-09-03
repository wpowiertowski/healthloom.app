// ToolArguments.swift
//
// WP-24 (review round 2, #20): shared argument shapes so per-tool copies
// can't drift -- a bounds or wording fix lands once, for every tool that
// takes it.

import Foundation
import FoundationModels

/// Day-window arguments shared by the day-windowed tools (`getSteps`,
/// `getWorkouts`): same field name, same guide text, same initializer.
@Generable
public nonisolated struct DaysArguments: Sendable {
    @Guide(description: "Number of days to summarize, 1 to 30.")
    public var days: Int

    public init(days: Int) {
        self.days = days
    }
}
