// TuningProposal.swift
// CoachEval
//
// WP-31: the hill-climbing workflow record (WWDC26 session 335). The loop
// is propose → human review → adopt-or-reject, and proposals are
// human-reviewed, never auto-adopted: a proposal carries its target
// (SafetyLayer text or default prompt), the exact from→to diff, and a
// reviewer sign-off. Adopting means a code change to the target plus a
// full eval re-run, not a runtime edit — the SafetyLayer suffix is
// written once and never edited at runtime (D10), so tuning lands in
// source, under review, like any clinical copy change.
//
// Until the SDK ships the Evaluations module, proposals are authored
// manually from nightly failures ("failures file as bugs against the
// SafetyLayer text or context assembly" — §9); when the framework lands,
// its hill-climbing harness fills in this same record shape instead of
// inventing a new one.

import Foundation

/// Which tuning knob a proposal targets. Both are compile-time constants —
/// there is no runtime prompt store to hill-climb against.
public enum TuningTarget: String, Sendable {
    case safetyLayer
    case defaultPrompt
}

/// Lifecycle with no auto-adopt: `proposed` → `approved`/`rejected` by a
/// human reviewer; `adopted` only after the code change lands and the eval
/// set re-runs green.
public enum ProposalStatus: String, Sendable {
    case proposed
    case approved
    case adopted
    case rejected
}

/// One hill-climbing proposal. Value type, Sendable — it crosses from the
/// nightly report into review tooling without shared state.
public struct TuningProposal: Sendable, Hashable {
    public let id: String
    public let target: TuningTarget
    public let rationale: String
    public let from: String
    public let to: String
    public let status: ProposalStatus
    public let reviewer: String?

    public init(
        id: String,
        target: TuningTarget,
        rationale: String,
        from: String,
        to: String,
        status: ProposalStatus = .proposed,
        reviewer: String? = nil
    ) {
        self.id = id
        self.target = target
        self.rationale = rationale
        self.from = from
        self.to = to
        self.status = status
        self.reviewer = reviewer
    }

    /// A reviewed proposal must name its reviewer. For `adopted`, the
    /// reviewer field records who signed off — the transition history
    /// (proposed → approved → adopted) lives in review tooling, not in
    /// this single-snapshot record, so the bool proves sign-off, not the
    /// path. Structural backstop for "never auto-adopted".
    public var reviewIsComplete: Bool {
        switch status {
        case .proposed: true
        case .approved, .rejected: reviewer != nil
        case .adopted: reviewer != nil
        }
    }
}
