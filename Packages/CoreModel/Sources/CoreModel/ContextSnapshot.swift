// ContextSnapshot.swift
// CoreModel
//
// The exact `HealthContext` sent to a `CoachProvider` for one turn, persisted verbatim
// so the "What did the coach see?" trace UI (architecture.md D7, WP-30) can render
// precisely what was shared — never a reconstruction. See implementation-plan.md WP-02
// step 2.

import Foundation
import SwiftData

@Model
public final class ContextSnapshot {
    /// Stable identifier `ChatTurn.contextSnapshotID` links back to.
    @Attribute(.unique) public var id: UUID

    /// The exact `HealthContext` sent, JSON-encoded verbatim (not re-derived at
    /// display time — that could drift from what was actually sent).
    public var json: Data

    public var createdAt: Date

    /// Which producer assembled this context (`ContextAssembler.Purpose`
    /// raw value: `"chat"` or `"dailyInsight"`). Lets the retention policy
    /// and the WP-30 trace distinguish per producer instead of by age alone.
    /// Defaults to `"chat"` so pre-column rows read as chat assemblies.
    /// The declaration-level default is load-bearing: it becomes the store
    /// schema default, so lightweight migration of on-disk stores (which have
    /// no migration plan in this repo) succeeds when the column is added.
    /// An `init`-only default would NOT do this -- the `@Model` macro reads
    /// the declaration initializer, not the init parameter default.
    public var purpose: String = "chat"

    public init(id: UUID = UUID(), json: Data, createdAt: Date = .now, purpose: String = "chat") {
        self.id = id
        self.json = json
        self.createdAt = createdAt
        self.purpose = purpose
    }
}
