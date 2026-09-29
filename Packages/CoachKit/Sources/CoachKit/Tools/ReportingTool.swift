// ReportingTool.swift
//
// WP-78: tells the chat what the coach is doing while a tool runs, so the
// typing indicator can say "Reading workout 2…" instead of waiting silently
// through a tool call. `CoachTools.all` wraps every tool in one; the wrapper
// forwards the tool's name, description and schema untouched, so the model
// sees exactly the tool it wraps.

import Foundation
import FoundationModels

/// Where tool activity goes: `began` as a tool starts, `ended` with the
/// same label once it answers or fails.
public struct CoachToolActivity: Sendable {
    public let began: @MainActor @Sendable (_ label: String) -> Void
    public let ended: @MainActor @Sendable (_ label: String) -> Void

    public init(
        began: @escaping @MainActor @Sendable (_ label: String) -> Void,
        ended: @escaping @MainActor @Sendable (_ label: String) -> Void
    ) {
        self.began = began
        self.ended = ended
    }
}

/// A coach tool that reports its activity around each call.
public struct ReportingTool<Base: Tool & Sendable>: Tool, Sendable where Base.Arguments: Sendable {
    public typealias Arguments = Base.Arguments
    public typealias Output = Base.Output

    let base: Base
    /// What the indicator says while this call runs.
    let label: @Sendable (Base.Arguments) -> String
    let activity: CoachToolActivity

    public init(_ base: Base, activity: CoachToolActivity, label: @escaping @Sendable (Base.Arguments) -> String) {
        self.base = base
        self.activity = activity
        self.label = label
    }

    public nonisolated var name: String { base.name }
    public nonisolated var description: String { base.description }
    public nonisolated var parameters: GenerationSchema { base.parameters }
    public nonisolated var includesSchemaInInstructions: Bool { base.includesSchemaInInstructions }

    public nonisolated func call(arguments: Base.Arguments) async throws -> Base.Output {
        let label = label(arguments)
        await activity.began(label)
        do {
            let output = try await base.call(arguments: arguments)
            await activity.ended(label)
            return output
        } catch {
            await activity.ended(label)
            throw error
        }
    }
}
