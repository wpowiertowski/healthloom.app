// CoachChatViewModelTests.swift
// HealthLoomTests
//
// WP-25 review round: unit coverage for the view-model rules the UI test
// can't reach deterministically -- newest-first cap ordering (#1),
// stop-before-first-token leaves no empty turn (#2), mid-stream errors
// persist the visible partial and report (#2), stop truncates the stream
// (#2/#3), and `send` reports queuing failures (#4).

import CoachKit
import CoreModel
import Foundation
import FoundationModels
import SwiftData
import SyncKit
import Testing
@testable import HealthLoom

/// Empty health data: every read returns nothing, so refreshes complete
/// instantly without touching HealthKit.
private struct EmptyReadStore: HealthReadStore {
    func dailySteps(from start: Date, to end: Date) async -> [DailyQuantityValue] { [] }
    func dailyRestingHeartRate(from start: Date, to end: Date) async -> [QuantityReading] { [] }
    func dailyHeartRateVariability(from start: Date, to end: Date) async -> [QuantityReading] { [] }
    func sleepStageSegments(from start: Date, to end: Date) async -> [SleepStageSegment] { [] }
    func workouts(from start: Date, to end: Date) async -> [WorkoutRecord] { [] }
}

private struct StreamBoom: Error {}

/// Controllable `CoachSession`: fixed chunks with an optional throw after
/// `failAfterChunks`, an optional never-yield mode (consumer cancel ends
/// iteration), and a per-chunk delay so tests can stop mid-stream.
private final class TestCoachSession: CoachSession, @unchecked Sendable {
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

private struct WaitTimeout: Error {}

@Suite("CoachChatViewModel")
@MainActor
struct CoachChatViewModelTests {
    private func makeViewModel(
        session: TestCoachSession,
        availability: CoachAvailability = .available,
        container: ModelContainer? = nil
    ) throws -> CoachChatViewModel {
        let container = try container ?? CoreModel.makeContainer(inMemory: true)
        let store = KnowledgeStore(
            modelContainer: container,
            healthReadStore: EmptyReadStore(),
            healthKitAuth: HealthKitAuth()
        )
        return CoachChatViewModel(deps: CoachChatViewModel.Dependencies(
            container: container,
            store: store,
            prompts: PromptManager(modelContainer: container),
            assembler: ContextAssembler(modelContainer: container),
            factory: CoachSessionFactory(build: { _, _ in session }),
            availability: FixedCoachAvailabilityChecker(availability: availability)
        ))
    }



    @Test("send streams the reply and links its context snapshot")
    func sendStreamsAndLinks() async throws {
        let viewModel = try makeViewModel(session: TestCoachSession())
        #expect(viewModel.send("hi") == true)
        try await waitForCondition({ !viewModel.isResponding })
        #expect(viewModel.turns.count == 2)
        #expect(viewModel.turns[0].role == "user")
        #expect(viewModel.turns[1].content == "Hello world.")
        #expect(viewModel.turns[1].contextSnapshotID != nil)
        #expect(viewModel.errorMessage == nil)
        // The linked snapshot decodes through the shared accessor.
        #expect(viewModel.resolveSharedContext(for: viewModel.turns[1]) == [])
    }

    @Test("history past the cap keeps the newest turns, not the oldest")
    func capKeepsNewest() async throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0 ..< (CoachChatViewModel.maxLoadedTurns + 5) {
            context.insert(ChatTurn(
                role: "user",
                content: "turn \(i)",
                createdAt: base.addingTimeInterval(Double(i))
            ))
        }
        try context.save()
        let viewModel = try makeViewModel(
            session: TestCoachSession(),
            container: container
        )
        viewModel.onAppear()
        #expect(viewModel.turns.count == CoachChatViewModel.maxLoadedTurns)
        #expect(viewModel.turns.first?.content == "turn 5")
        #expect(viewModel.turns.last?.content == "turn \(CoachChatViewModel.maxLoadedTurns + 4)")
    }

    @Test("stopping before the first token persists no empty turn")
    func stopBeforeFirstToken() async throws {
        let viewModel = try makeViewModel(session: TestCoachSession(suspendForever: true))
        #expect(viewModel.send("hi") == true)
        try await waitForCondition({ viewModel.isResponding })
        viewModel.stop()
        try await waitForCondition({ !viewModel.isResponding })
        #expect(viewModel.turns.count == 1)
        #expect(viewModel.turns[0].role == "user")
        #expect(viewModel.errorMessage == nil)
    }

    @Test("mid-stream error persists the visible partial and reports")
    func midStreamError() async throws {
        let viewModel = try makeViewModel(session: TestCoachSession(
            chunks: ["part ", "rest."],
            failAfterChunks: 1
        ))
        #expect(viewModel.send("hi") == true)
        try await waitForCondition({ !viewModel.isResponding })
        #expect(viewModel.turns.count == 2)
        #expect(viewModel.turns[1].content == "part ")
        #expect(viewModel.errorMessage?.contains("couldn't reply") == true)
    }

    @Test("stop truncates the stream to a non-empty partial")
    func stopTruncates() async throws {
        let viewModel = try makeViewModel(session: TestCoachSession(
            chunks: ["one ", "two ", "three ", "four."],
            chunkDelay: .milliseconds(200)
        ))
        #expect(viewModel.send("hi") == true)
        try await waitForCondition({ !viewModel.draft.isEmpty })
        viewModel.stop()
        try await waitForCondition({ !viewModel.isResponding })
        #expect(viewModel.turns.count == 2)
        let reply = viewModel.turns[1].content
        #expect(!reply.isEmpty)
        #expect(reply != "one two three four.")
        #expect(viewModel.errorMessage == nil)
    }

    @Test("send reports queuing failures without queueing")
    func sendReportsFailure() async throws {
        let unavailable = try makeViewModel(
            session: TestCoachSession(),
            availability: .modelNotReady
        )
        unavailable.onAppear()
        try await waitForCondition({ unavailable.availability != .available }, timeout: 2)
        #expect(unavailable.send("hi") == false)
        #expect(unavailable.turns.isEmpty)

        let viewModel = try makeViewModel(session: TestCoachSession())
        #expect(viewModel.send("   ") == false)
        #expect(viewModel.turns.isEmpty)
    }
}

@Suite("Coach stream survival + launch matrix (WP-25 round-2)")
@MainActor
struct CoachRoundTwoTests {
    @Test("tab switch mid-stream does not truncate the reply")
    func tabSwitchDoesNotTruncate() async throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let store = KnowledgeStore(
            modelContainer: container,
            healthReadStore: EmptyReadStore(),
            healthKitAuth: HealthKitAuth()
        )
        let viewModel = CoachChatViewModel(deps: CoachChatViewModel.Dependencies(
            container: container,
            store: store,
            prompts: PromptManager(modelContainer: container),
            assembler: ContextAssembler(modelContainer: container),
            factory: CoachSessionFactory(build: { _, _ in TestCoachSession(
                chunks: ["one ", "two ", "three."],
                chunkDelay: .milliseconds(200)
            ) }),
            availability: FixedCoachAvailabilityChecker(availability: .available)
        ))
        #expect(viewModel.send("hi") == true)
        try await waitForCondition({ viewModel.isResponding })
        // The view unmounts and remounts; the view model (and its stream)
        // outlives both.
        viewModel.onDisappear()
        viewModel.onAppear()
        try await waitForCondition({ !viewModel.isResponding })
        #expect(viewModel.turns.count == 2)
        #expect(viewModel.turns[1].content == "one two three.")
        #expect(viewModel.errorMessage == nil)
    }

    @Test("stale cached availability aborts before streaming")
    func staleCacheAborts() async throws {
        // No onAppear: the cached value is still the optimistic `.available`
        // while the live gate reports `.modelNotReady`.
        let container = try CoreModel.makeContainer(inMemory: true)
        let store = KnowledgeStore(
            modelContainer: container,
            healthReadStore: EmptyReadStore(),
            healthKitAuth: HealthKitAuth()
        )
        let viewModel = CoachChatViewModel(deps: CoachChatViewModel.Dependencies(
            container: container,
            store: store,
            prompts: PromptManager(modelContainer: container),
            assembler: ContextAssembler(modelContainer: container),
            factory: CoachSessionFactory(build: { _, _ in TestCoachSession() }),
            availability: FixedCoachAvailabilityChecker(availability: .modelNotReady)
        ))
        #expect(viewModel.send("hi") == true)
        try await waitForCondition({ !viewModel.isResponding })
        #expect(viewModel.errorMessage?.contains("isn't available") == true)
        // The already-queued user turn stays; no assistant turn streams.
        #expect(viewModel.turns.count == 1)
        #expect(viewModel.turns[0].role == "user")
    }

    @Test("launch flag matrix: route, store, and session mode")
    func launchMatrix() {
        // Plain launch: onboarding path, on-disk store, live session.
        var config = LaunchConfiguration.resolve(arguments: [])
        #expect(config.initialRoute == .default)
        #expect(config.useInMemoryContainer == false)
        #expect(config.coachSessionMode == .live)

        // Seed data: Data tab, in-memory.
        config = LaunchConfiguration.resolve(arguments: ["-UITestSeedData"])
        #expect(config.initialRoute == .data)
        #expect(config.useInMemoryContainer == true)

        // Stub Google alone: onboarding happy path untouched (round-2 #2
        // is about the route only -- the in-memory store rule predates
        // this diff and stays).
        config = LaunchConfiguration.resolve(arguments: ["-UITestStubGoogle"])
        #expect(config.initialRoute == .default)
        #expect(config.useInMemoryContainer == true)

        // Scripted coach: Coach tab, ON-DISK store (relaunch leg), scripted.
        config = LaunchConfiguration.resolve(arguments: ["-UITestScriptedCoach"])
        #expect(config.initialRoute == .coach)
        #expect(config.useInMemoryContainer == false)
        #expect(config.coachSessionMode == .scripted)

        // Forced unavailable: Coach tab, in-memory, forced case.
        config = LaunchConfiguration.resolve(arguments: ["-UITestCoachUnavailable"])
        #expect(config.initialRoute == .coach)
        #expect(config.useInMemoryContainer == true)
        #expect(config.coachSessionMode == .forced(.modelNotReady))

        config = LaunchConfiguration.resolve(arguments: ["-UITestCoachUnavailable=deviceNotEligible"])
        #expect(config.coachSessionMode == .forced(.deviceNotEligible))

        // Unknown forced value still renders an unavailable state.
        config = LaunchConfiguration.resolve(arguments: ["-UITestCoachUnavailable=bogus"])
        #expect(config.coachSessionMode == .forced(.modelNotReady))

        // Scripted + forced together: scripted keeps the on-disk store
        // (round-2 #7); forced wins the session (unavailable UI).
        config = LaunchConfiguration.resolve(arguments: ["-UITestScriptedCoach", "-UITestCoachUnavailable"])
        #expect(config.initialRoute == .coach)
        #expect(config.useInMemoryContainer == false)
        #expect(config.coachSessionMode == .forced(.modelNotReady))
    }
}

/// Shared poll helper for the chat suites (file scope so every suite in
/// this file can use it).
@MainActor
private func waitForCondition(
    _ condition: @MainActor @escaping () -> Bool,
    timeout: TimeInterval = 10
) async throws {
    let start = Date.now
    while !condition() {
        try await Task.sleep(for: .milliseconds(20))
        if Date.now.timeIntervalSince(start) > timeout {
            throw WaitTimeout()
        }
    }
}
