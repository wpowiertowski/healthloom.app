// CoachToolsTests.swift
//
// WP-24 "Tests" line: each tool against a seeded KnowledgeStore (output text
// golden); argument clamping; tools respect exclusions (excluded field never
// in any tool output). Real model/tool-calling round trips are on-device
// manual tests (test plan §7) -- no unit test touches the model.

@testable import CoachKit
import CoreModel
import Foundation
import FoundationModels
import SwiftData
import SyncKit
import Testing

@MainActor
private func makeToolsStore(
    configure: (MockHealthReadStore) -> Void = { _ in }
) throws -> (KnowledgeStore, ModelContainer) {
    let container = try CoreModel.makeContainer(inMemory: true)
    let readStore = MockHealthReadStore()
    configure(readStore)
    let store = KnowledgeStore(
        modelContainer: container,
        healthReadStore: readStore,
        healthKitAuth: HealthKitAuth()
    )
    return (store, container)
}

@MainActor
private func seedBaseline(_ readStore: MockHealthReadStore, now: Date) {
    let day: TimeInterval = 86_400
    readStore.steps = (0..<10).map {
        DailyQuantityValue(day: now.addingTimeInterval(-Double($0) * day), value: 8_000)
    }
    readStore.restingHeartRate = (0..<10).map {
        QuantityReading(date: now.addingTimeInterval(-Double($0) * day), value: 58)
    }
    readStore.heartRateVariability = (0..<10).map {
        QuantityReading(date: now.addingTimeInterval(-Double($0) * day), value: 42)
    }
    let sleepStart = now.addingTimeInterval(-10 * 3_600)
    readStore.sleepSegments = [
        SleepStageSegment(start: sleepStart, end: sleepStart.addingTimeInterval(7 * 3_600), stage: .core),
    ]
    readStore.workouts = [
        WorkoutRecord(
            id: UUID(),
            start: now.addingTimeInterval(-day),
            end: now.addingTimeInterval(-day + 1_800),
            activityName: "Running",
            totalEnergyKilocalories: 300,
            totalDistanceMeters: 5_000
        ),
    ]
}

@MainActor
private func excludeKeys(_ keys: [String], store: KnowledgeStore, in container: ModelContainer) throws {
    // Funneled write path (not direct row mutation): persists the flag and
    // refreshes the exclusion cache together, the same API WP-30's settings
    // UI will call. Asserts the profile actually carries each key -- a
    // missing key would silently test nothing.
    let context = ModelContext(container)
    guard let profile = try KnowledgeStore.fetchProfile(from: context) else {
        Issue.record("no profile to exclude from")
        return
    }
    for key in keys {
        #expect(profile.sections.contains(where: { $0.key == key }), "seeded profile lacks \(key)")
        try store.setExcludedFromAI(true, forKey: key)
    }
}

/// Stands in for the app's workout reads, recording what each tool asked
/// for -- the reads themselves are the app's (HealthLoomTests cover them).
@MainActor
private final class WorkoutQueriesProbe {
    var lists: [Int] = []
    var details: [(number: Int, measurement: String?)] = []

    var queries: CoachWorkoutQueries {
        CoachWorkoutQueries(
            list: { days in
                self.lists.append(days)
                return "list \(days)"
            },
            detail: { number, measurement in
                self.details.append((number, measurement))
                return "detail \(number)"
            }
        )
    }
}

/// Records tool activity reports in order.
@MainActor
private final class ActivityProbe {
    var events: [String] = []

    var activity: CoachToolActivity {
        CoachToolActivity(
            began: { self.events.append("began \($0)") },
            ended: { self.events.append("ended \($0)") }
        )
    }
}

@Suite("CoachTools wiring")
@MainActor
struct CoachToolsWiringTests {
    @Test("all builds five named tools in order, each reporting its activity")
    func buildsAllTools() throws {
        let (store, _) = try makeToolsStore()
        let tools: [any Tool] = CoachTools.all(store: store, workouts: WorkoutQueriesProbe().queries, activity: ActivityProbe().activity)
        #expect(tools.map(\.name) == ["getSteps", "getRecentSleep", "getWorkouts", "getWorkoutDetail", "getVitals"])
        #expect(tools[0] is ReportingTool<GetStepsTool>)
        #expect(tools[1] is ReportingTool<GetRecentSleepTool>)
        #expect(tools[2] is ReportingTool<GetWorkoutsTool>)
        #expect(tools[3] is ReportingTool<GetWorkoutDetailTool>)
        #expect(tools[4] is ReportingTool<GetVitalsTool>)
        // The model sees the wrapped tool's own schema and description.
        #expect(tools[3].description == GetWorkoutDetailTool.live(store: store, detail: { _, _ in "" }).description)
    }

    // catches: the typing indicator left naming a finished (or failed)
    // tool, or the detail call not saying which workout it reads.
    @Test("tools report what they're doing until they answer or fail")
    func toolsReportActivity() async throws {
        let (store, _) = try makeToolsStore()
        let probe = ActivityProbe()
        let tools = CoachTools.all(store: store, workouts: WorkoutQueriesProbe().queries, activity: probe.activity)
        guard let detail = tools[3] as? ReportingTool<GetWorkoutDetailTool> else {
            Issue.record("detail tool isn't reporting")
            return
        }
        _ = try await detail.call(arguments: .init(number: 2, measurement: "Ground contact time"))
        #expect(probe.events == ["began Reading workout 2 (ground contact time)", "ended Reading workout 2 (ground contact time)"])

        struct Probe: Error {}
        let failing = ReportingTool(GetStepsTool { _ in throw Probe() }, activity: probe.activity) { _ in "Checking your steps" }
        await #expect(throws: Probe.self) { try await failing.call(arguments: .init(days: 7)) }
        #expect(probe.events.suffix(2) == ["began Checking your steps", "ended Checking your steps"])
    }

    // catches: the list asked for more days than it numbers, or the detail
    // tool dropping the measurement (or passing a blank one as a name).
    @Test("workout tools hand the app the clamped window, the number and the measurement")
    func workoutToolsForwardTheirArguments() async throws {
        let (store, _) = try makeToolsStore()
        let probe = WorkoutQueriesProbe()
        let list = GetWorkoutsTool.live(store: store, list: probe.queries.list)
        let detail = GetWorkoutDetailTool.live(store: store, detail: probe.queries.detail)

        #expect(try await list.call(arguments: .init(days: 500)) == "list \(GetWorkoutsTool.windowDays)")
        _ = try await list.call(arguments: .init(days: 0))
        _ = try await detail.call(arguments: .init(number: 2, measurement: " Ground contact time "))
        _ = try await detail.call(arguments: .init(number: 3, measurement: "  "))
        _ = try await detail.call(arguments: .init(number: 1))

        #expect(probe.lists == [GetWorkoutsTool.windowDays, 1])
        #expect(probe.details.map(\.number) == [2, 3, 1])
        #expect(probe.details.map(\.measurement) == ["Ground contact time", nil, nil])
    }

    @Test("live tool output is the store summary, untransformed")
    func outputEqualsSummary() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, _) = try makeToolsStore {
            seedBaseline($0, now: now)
        }
        _ = try await store.refresh(now: now)

        #expect(try await GetStepsTool.live(store: store).call(arguments: .init(days: 7)) == store.stepsSummary(days: 7))
        #expect(try await GetRecentSleepTool.live(store: store).call(arguments: .init(nights: 7)) == store.sleepSummary(nights: 7))
        #expect(try await GetVitalsTool.live(store: store).call(arguments: .init()) == store.vitalsSummary())
    }

    @Test("seeded data flows into tool answers")
    func dataFlows() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, _) = try makeToolsStore {
            seedBaseline($0, now: now)
        }
        _ = try await store.refresh(now: now)

        let steps = try await GetStepsTool.live(store: store).call(arguments: .init(days: 7))
        #expect(steps.contains("8,000") || steps.contains("8000"))
        let vitals = try await GetVitalsTool.live(store: store).call(arguments: .init())
        #expect(vitals.contains("58"))
    }

    @Test("empty store answers with no-data sentences")
    func emptyStoreNoData() async throws {
        let (store, _) = try makeToolsStore()
        _ = try await store.refresh(now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(try await GetStepsTool.live(store: store).call(arguments: .init(days: 7)) == "No step data available for the last 7 days.")
        #expect(try await GetVitalsTool.live(store: store).call(arguments: .init()) == "No recent vitals available.")
    }
}

@Suite("CoachTools clamping")
@MainActor
struct CoachToolsClampingTests {
    @Test("shared window helper bounds to 1...maximum")
    func windowHelper() {
        #expect(Clamping.window(0, maximum: 30) == 1)
        #expect(Clamping.window(-5, maximum: 30) == 1)
        #expect(Clamping.window(7, maximum: 30) == 7)
        #expect(Clamping.window(30, maximum: 30) == 30)
        #expect(Clamping.window(500, maximum: 30) == 30)
        #expect(Clamping.window(500, maximum: 14) == 14)
    }

    @Test("out-of-range arguments behave as the clamped window")
    func clampedCallsMatch() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, _) = try makeToolsStore {
            seedBaseline($0, now: now)
        }
        _ = try await store.refresh(now: now)
        let steps = GetStepsTool.live(store: store)
        #expect(try await steps.call(arguments: .init(days: 500)) == store.stepsSummary(days: 30))
        #expect(try await steps.call(arguments: .init(days: 0)) == store.stepsSummary(days: 1))
        let sleep = GetRecentSleepTool.live(store: store)
        #expect(try await sleep.call(arguments: .init(nights: -3)) == store.sleepSummary(nights: 1))
        // Sleep's ceiling is the store's 14-night cache window, not the
        // 30-day tool convention -- the schema promises only 1-14.
        #expect(try await sleep.call(arguments: .init(nights: 500)) == store.sleepSummary(nights: 14))
    }

    @Test("answer-closure errors propagate instead of answering")
    func errorsPropagate() async throws {
        struct Probe: Error {}
        let tool = GetStepsTool { _ in throw Probe() }
        await #expect(throws: Probe.self) {
            try await tool.call(arguments: .init(days: 7))
        }
    }
}

@Suite("CoachTools exclusions (D7/D8)")
@MainActor
struct CoachToolsExclusionTests {
    @Test("excluded steps silence the steps tool")
    func excludedStepsRefuse() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, container) = try makeToolsStore {
            seedBaseline($0, now: now)
        }
        _ = try await store.refresh(now: now)
        try excludeKeys([KnowledgeDerivation.stepsFieldKey], store: store, in: container)

        let answer = try await GetStepsTool.live(store: store).call(arguments: .init(days: 7))
        #expect(answer == GetStepsTool.excludedMessage)
        #expect(!answer.contains("8,000") && !answer.contains("8000"))
    }

    @Test("one excluded sleep field silences the whole sleep topic")
    func partialSleepExclusionRefuses() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, container) = try makeToolsStore {
            seedBaseline($0, now: now)
        }
        _ = try await store.refresh(now: now)
        // Only the duration field excluded; the stage split is not -- the
        // tool still refuses rather than leaking duration substance.
        try excludeKeys([KnowledgeDerivation.sleepDurationFieldKey], store: store, in: container)

        let answer = try await GetRecentSleepTool.live(store: store).call(arguments: .init(nights: 7))
        #expect(answer == GetRecentSleepTool.excludedMessage)
    }

    @Test("one excluded vitals field silences the vitals tool")
    func partialVitalsExclusionRefuses() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, container) = try makeToolsStore {
            seedBaseline($0, now: now)
        }
        _ = try await store.refresh(now: now)
        try excludeKeys([KnowledgeDerivation.heartRateVariabilityFieldKey], store: store, in: container)

        let answer = try await GetVitalsTool.live(store: store).call(arguments: .init())
        #expect(answer == GetVitalsTool.excludedMessage)
        #expect(!answer.contains("58"))
    }

    @Test("unrelated exclusions don't silence other tools")
    func unrelatedExclusionPassesThrough() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, container) = try makeToolsStore {
            seedBaseline($0, now: now)
        }
        _ = try await store.refresh(now: now)
        try excludeKeys([KnowledgeDerivation.workoutsFieldKey], store: store, in: container)

        let steps = try await GetStepsTool.live(store: store).call(arguments: .init(days: 7))
        #expect(steps == store.stepsSummary(days: 7))
        let probe = WorkoutQueriesProbe()
        #expect(try await GetWorkoutsTool.live(store: store, list: probe.queries.list).call(arguments: .init(days: 7))
            == GetWorkoutsTool.excludedMessage)
        // catches: the detail tool reading workouts the user excluded.
        #expect(try await GetWorkoutDetailTool.live(store: store, detail: probe.queries.detail)
            .call(arguments: .init(number: 1, measurement: "heart rate")) == GetWorkoutDetailTool.excludedMessage)
        #expect(probe.lists.isEmpty && probe.details.isEmpty)
    }

    @Test("gate is false with no profile and empty keys")
    func gateDefaults() throws {
        let (store, _) = try makeToolsStore()
        #expect(try store.isAnyExcludedFromAI([KnowledgeDerivation.stepsFieldKey]) == false)
        #expect(try store.isAnyExcludedFromAI([]) == false)
    }

    @Test("refresh-populated cache silences without invalidation")
    func refreshCacheSilences() async throws {
        // A correction-sourced excluded field survives refresh byte-for-byte,
        // so the refresh itself populates the exclusion cache -- no
        // out-of-band mutation, no invalidation call, gate hits the cache.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, container) = try makeToolsStore {
            seedBaseline($0, now: now)
        }
        let seedContext = ModelContext(container)
        seedContext.insert(KnowledgeProfile(sections: [ProfileField(
            key: KnowledgeDerivation.stepsFieldKey,
            displayText: "User-corrected steps",
            source: KnowledgeStore.correctionSourceLabel,
            asOf: now,
            excludedFromAI: true,
            isClinical: false
        )]))
        try seedContext.save()
        _ = try await store.refresh(now: now)

        let answer = try await GetStepsTool.live(store: store).call(arguments: .init(days: 7))
        #expect(answer == GetStepsTool.excludedMessage)
    }
}


@Suite("Exclusion write path + shared shapes")
@MainActor
struct ExclusionWritePathTests {
    @Test("setExcludedFromAI round-trips through the gate, both directions")
    func setExcludedRoundTrip() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, _) = try makeToolsStore {
            seedBaseline($0, now: now)
        }
        _ = try await store.refresh(now: now)
        let keys = [KnowledgeDerivation.stepsFieldKey]

        #expect(try store.isAnyExcludedFromAI(keys) == false)
        try store.setExcludedFromAI(true, forKey: KnowledgeDerivation.stepsFieldKey)
        #expect(try store.isAnyExcludedFromAI(keys) == true)
        // ...and the tools answer (or refuse) off the same state, no
        // invalidation call needed -- the write path keeps the cache coherent.
        #expect(try await GetStepsTool.live(store: store).call(arguments: .init(days: 7)) == GetStepsTool.excludedMessage)
        try store.setExcludedFromAI(false, forKey: KnowledgeDerivation.stepsFieldKey)
        #expect(try store.isAnyExcludedFromAI(keys) == false)
        #expect(try await GetStepsTool.live(store: store).call(arguments: .init(days: 7)) == store.stepsSummary(days: 7))
    }

    @Test("day-window tools share one Arguments shape")
    func sharedArgumentsShape() {
        #expect(GetStepsTool.Arguments.self == DaysArguments.self)
        #expect(GetWorkoutsTool.Arguments.self == DaysArguments.self)
    }

    @Test("refusal messages come from the shared template")
    func refusalTemplate() {
        #expect(GetStepsTool.excludedMessage == CoachTools.excludedMessage(forTopic: "Step"))
        #expect(GetRecentSleepTool.excludedMessage == CoachTools.excludedMessage(forTopic: "Sleep"))
        #expect(GetWorkoutsTool.excludedMessage == CoachTools.excludedMessage(forTopic: "Workout"))
        #expect(GetWorkoutDetailTool.excludedMessage == GetWorkoutsTool.excludedMessage)
        #expect(GetVitalsTool.excludedMessage == CoachTools.excludedMessage(forTopic: "Vitals"))
    }
}
