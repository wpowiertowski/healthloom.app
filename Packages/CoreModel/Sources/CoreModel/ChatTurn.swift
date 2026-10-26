// ChatTurn.swift
// CoreModel
//
// One message in the Coach conversation (WP-25 Chat UI). See implementation-plan.md
// WP-02 step 2.

import Foundation
import SwiftData

@Model
public final class ChatTurn {
    /// `"user" | "assistant"`.
    public var role: String

    public var content: String

    /// `ProviderID.rawValue` of whichever `CoachProvider` produced this turn (empty/
    /// irrelevant for user turns).
    public var provider: String

    /// Links to the `ContextSnapshot` sent for this turn (assistant turns only —
    /// `nil` for user turns, which don't have a context sent *to* them).
    public var contextSnapshotID: UUID?

    /// The model the provider reported serving this reply (WP-87), e.g.
    /// `claude-opus-5-5`; nil for user turns, offers, and tiers that report
    /// none (on-device). Optional with no default migration needed.
    public var servedModelID: String?

    public var createdAt: Date

    public init(
        role: String,
        content: String,
        provider: String = "",
        contextSnapshotID: UUID? = nil,
        servedModelID: String? = nil,
        createdAt: Date = .now
    ) {
        self.role = role
        self.content = content
        self.provider = provider
        self.contextSnapshotID = contextSnapshotID
        self.servedModelID = servedModelID
        self.createdAt = createdAt
    }
}
