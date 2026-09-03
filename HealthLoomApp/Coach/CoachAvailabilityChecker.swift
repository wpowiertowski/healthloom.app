// CoachAvailabilityChecker.swift
//
// WP-25 review #19: the availability seam as a protocol, matching the
// codebase's other dependency seams (`GoogleConsentCoordinating`-style)
// instead of the bare closure the first cut used -- call sites needing a
// fake availability share `FixedCoachAvailabilityChecker` rather than
// hand-rolling closures.

import CoachKit
import Foundation

/// Where the chat UI reads coach availability from. Live in production,
/// fixed under UI-test flags and in unit tests.
protocol CoachAvailabilityChecking: Sendable {
    func current() async -> CoachAvailability
}

/// Production: the on-device model's live state (itself MainActor-bound via
/// the framework type, hence the async seam).
struct LiveCoachAvailabilityChecker: CoachAvailabilityChecking {
    func current() async -> CoachAvailability {
        AvailabilityGate.current()
    }
}

/// Forced state: UI-test launches (`-UITestScriptedCoach` forces
/// `.available`, `-UITestCoachUnavailable=<case>` forces the named
/// unavailable case) and unit tests.
struct FixedCoachAvailabilityChecker: CoachAvailabilityChecking {
    let availability: CoachAvailability

    func current() async -> CoachAvailability {
        availability
    }
}
