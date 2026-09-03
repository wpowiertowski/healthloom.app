// UITestScriptedCoachSession.swift
//
// WP-25 (implementation-plan.md): scripted `CoachSession` double for the
// chat UI test, living in the app target -- CoachKit's own
// `ScriptedCoachSession` is a unit-test-target type the app binary can't
// see. Selected purely at runtime via `launchConfiguration.scriptedCoach`
// (the `StubGoogleReconcileClient` precedent -- no `#if DEBUG`, so Debug
// and Release wire identically; without the flag this type is inert).
//
// Fidelity notes (WP-25 review #6): single-flight is enforced like the live
// session's `concurrentRequests`, `isResponding` spans every call kind, and
// structured generation answers from an optional scripted value instead of
// unconditionally throwing.

import CoachKit
import Foundation
import FoundationModels

/// Scripted chat partner: streams a fixed reply in chunks.
/// `@unchecked Sendable`: every `var` below is guarded by `lock`
/// (round-2 #10) -- nothing mutable is touched off-lock, so the promise
/// holds despite the absence of actor isolation.
final class UITestScriptedCoachSession: CoachSession, @unchecked Sendable {
    static let reply = "Scripted coach reply: rest well and hydrate."

    private let chunks: [String]
    private let lock = NSLock()
    private var _isResponding = false
    /// Scripted answer for structured calls; unset throws, mirroring the
    /// test-target double (an unconfigured guided call fails loudly, never
    /// silently). Lock-guarded like the rest: this class promises
    /// `Sendable` with no actor, so even test-only configuration must be
    /// synchronized.
    var scriptedStructured: Any? {
        get { lock.withLock { _scriptedStructured } }
        set { lock.withLock { _scriptedStructured = newValue } }
    }
    private var _scriptedStructured: Any?
    private var inFlight = false

    var isResponding: Bool {
        lock.withLock { _isResponding }
    }

    init(chunks: [String] = ["Scripted ", "coach ", "reply: ", "rest ", "well and ", "hydrate."]) {
        self.chunks = chunks
    }

    func prewarm() {}

    private func beginCall() throws {
        try lock.withLock {
            if inFlight {
                throw ScriptedCoachError.concurrentRequest
            }
            inFlight = true
            _isResponding = true
        }
    }

    private func endCall() {
        lock.withLock {
            inFlight = false
            _isResponding = false
        }
    }

    func respond(to prompt: String) async throws -> String {
        try beginCall()
        defer { endCall() }
        return Self.reply
    }

    func respond<Content: Generable>(to prompt: String, generating type: Content.Type) async throws -> Content {
        try beginCall()
        defer { endCall() }
        guard let value = scriptedStructured as? Content else { throw ScriptedCoachError.noStructuredReply }
        return value
    }

    func stream(to prompt: String) -> AsyncThrowingStream<String, Error> {
        do {
            try beginCall()
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let chunks = chunks
        return AsyncThrowingStream { [weak self] continuation in
            // Half a second per chunk (~3s total): keeps the in-flight
            // state (stop button, disabled input, streaming bubble)
            // observable through XCUI's slow polling -- a sub-second stream
            // routinely finished before the test's stop-button query ran.
            let task = Task {
                for chunk in chunks {
                    try? await Task.sleep(for: .milliseconds(500))
                    if Task.isCancelled { break }
                    continuation.yield(chunk)
                }
                // `endCall()` BEFORE `finish()` (round-2 #8): `finish()`
                // unblocks the consumer's `for try await`, whose resumption
                // (and a rapid back-to-back second `send()` reusing this
                // cached session) must already see `inFlight == false`, or
                // a valid send spuriously throws `concurrentRequest`. No
                // ordering primitive enforced this before -- the MainActor
                // hop merely won the race in practice.
                self?.endCall()
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum ScriptedCoachError: Error {
    case concurrentRequest
    case noStructuredReply
}
