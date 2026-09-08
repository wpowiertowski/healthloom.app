// TestDoubles.swift
// HealthLoomTests
//
// Shared test doubles (WP-30 N3: moved — not widened — out of
// `CoachChatViewModelTests.swift` on the next touch that needed them
// cross-file, so reuse extends the shared file instead of widening more
// `private`s).

import CoachKit
import Foundation
import FoundationModels
import SyncKit
import Testing

/// Empty health data: every read returns nothing, so refreshes complete
/// instantly without touching HealthKit.
struct EmptyReadStore: HealthReadStore {
    func dailySteps(from start: Date, to end: Date) async -> [DailyQuantityValue] { [] }
    func dailyRestingHeartRate(from start: Date, to end: Date) async -> [QuantityReading] { [] }
    func dailyHeartRateVariability(from start: Date, to end: Date) async -> [QuantityReading] { [] }
    func sleepStageSegments(from start: Date, to end: Date) async -> [SleepStageSegment] { [] }
    func workouts(from start: Date, to end: Date) async -> [WorkoutRecord] { [] }
}

struct StreamBoom: Error {}

/// Controllable `CoachSession`: fixed chunks with an optional throw after
/// `failAfterChunks`, an optional never-yield mode (consumer cancel ends
/// iteration), and a per-chunk delay so tests can stop mid-stream.
final class TestCoachSession: CoachSession, @unchecked Sendable {
    let chunks: [String]
    let failAfterChunks: Int?
    let suspendForever: Bool
    let chunkDelay: Duration

    init(
        chunks: [String] = ["Hello ", "world."],
        failAfterChunks: Int? = nil,
        suspendForever: Bool = false,
        chunkDelay: Duration = .milliseconds(50)
    ) {
        self.chunks = chunks
        self.failAfterChunks = failAfterChunks
        self.suspendForever = suspendForever
        self.chunkDelay = chunkDelay
    }

    var isResponding: Bool { false }
    func prewarm() {}
    func respond(to prompt: String) async throws -> String { chunks.joined() }
    func respond<Content: Generable>(to prompt: String, generating type: Content.Type) async throws -> Content {
        throw StreamBoom()
    }
    func stream(to prompt: String) -> AsyncThrowingStream<String, Error> {
        let chunks = chunks
        let failAfterChunks = failAfterChunks
        let suspendForever = suspendForever
        let chunkDelay = chunkDelay
        return AsyncThrowingStream { continuation in
            if suspendForever { return }
            let task = Task {
                for (index, chunk) in chunks.enumerated() {
                    try? await Task.sleep(for: chunkDelay)
                    if Task.isCancelled { break }
                    if failAfterChunks == index {
                        continuation.finish(throwing: StreamBoom())
                        return
                    }
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Records `prewarm()` calls (WP-37 first-token-latency pin: `onAppear`
/// must warm the session so the first token doesn't pay cold-start).
/// Chat-shaped, never throws; lock-guarded counter, immutable otherwise.
final class PrewarmProbeSession: CoachSession, Sendable {
    private let lock = NSLock()
    private var _prewarmCount = 0

    var prewarmCount: Int { lock.withLock { _prewarmCount } }

    var isResponding: Bool { false }
    func prewarm() {
        lock.withLock { _prewarmCount += 1 }
    }
    func respond(to prompt: String) async throws -> String { "" }
    func respond<Content: Generable>(to prompt: String, generating type: Content.Type) async throws -> Content {
        throw StreamBoom()
    }
    func stream(to prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
