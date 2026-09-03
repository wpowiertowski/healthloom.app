// KnowledgeStoreTests.swift
//
// WP-19 "Tests" line: correction pinning wins; staleness (`asOf`) propagation;
// plus integration coverage for `refresh()`'s persistence round-trip and the
// tool-facing summary API (step 4).

@testable import CoachKit
import CoreModel
import Foundation
import SwiftData
import SyncKit
import Testing

@MainActor
private func makeStore(readStore: MockHealthReadStore = MockHealthReadStore()) throws -> (KnowledgeStore, ModelContainer) {
    let container = try CoreModel.makeContainer(inMemory: true)
    let store = KnowledgeStore(
        modelContainer: container,
        healthReadStore: readStore,
        healthKitAuth: HealthKitAuth()
    )
    return (store, container)
}

@Suite("KnowledgeStore.refresh persistence")
@MainActor
struct KnowledgeStoreRefreshTests {
    @Test("derived fields persist to the single KnowledgeProfile row")
    func persistsDerivedFields() async throws {
        let readStore = MockHealthReadStore()
        readStore.steps = [DailyQuantityValue(day: .now, value: 8000)]
        let (store, container) = try makeStore(readStore: readStore)

        let now = Date()
        let profile = try await store.refresh(now: now)
        #expect(profile.sections.contains { $0.key == KnowledgeDerivation.stepsFieldKey })
        #expect(profile.updatedAt == now)

        // Re-fetch from a fresh context to confirm it actually persisted, not
        // just mutated the in-memory object `refresh()` handed back.
        let context = ModelContext(container)
        let reloaded = try context.fetch(FetchDescriptor<KnowledgeProfile>())
        #expect(reloaded.count == 1)
        #expect(reloaded[0].sections.contains { $0.key == KnowledgeDerivation.stepsFieldKey })
    }

    @Test("staleness: every field from one refresh cycle shares that cycle's asOf")
    func stalenessPropagation() async throws {
        let readStore = MockHealthReadStore()
        readStore.steps = [DailyQuantityValue(day: .now, value: 8000)]
        readStore.workouts = [
            WorkoutRecord(id: UUID(), start: .now, end: .now.addingTimeInterval(1800), activityName: "Running", totalEnergyKilocalories: nil, totalDistanceMeters: nil),
        ]
        let (store, _) = try makeStore(readStore: readStore)

        let firstRun = Date(timeIntervalSince1970: 1_700_000_000)
        let profile = try await store.refresh(now: firstRun)
        #expect(profile.sections.allSatisfy { $0.asOf == firstRun })

        let secondRun = firstRun.addingTimeInterval(3600)
        let updated = try await store.refresh(now: secondRun)
        #expect(updated.sections.allSatisfy { $0.asOf == secondRun })
    }

    @Test("a correction field survives re-derivation for the same key")
    func correctionPinningWins() async throws {
        let readStore = MockHealthReadStore()
        readStore.steps = [DailyQuantityValue(day: .now, value: 8000)]
        let (store, container) = try makeStore(readStore: readStore)

        // Seed a pre-existing profile with a user correction at the same key
        // `stepsField` would otherwise derive.
        let context = ModelContext(container)
        let correction = ProfileField(
            key: KnowledgeDerivation.stepsFieldKey,
            displayText: "Actually more like 9,500/day, my watch undercounts",
            source: KnowledgeStore.correctionSourceLabel,
            asOf: Date(timeIntervalSince1970: 0)
        )
        let seeded = KnowledgeProfile(sections: [correction])
        context.insert(seeded)
        try context.save()

        let profile = try await store.refresh(now: .now)
        let stepsField = profile.sections.first { $0.key == KnowledgeDerivation.stepsFieldKey }
        #expect(stepsField?.displayText == correction.displayText)
        #expect(stepsField?.source == KnowledgeStore.correctionSourceLabel)
        #expect(stepsField?.asOf == correction.asOf, "the correction's own asOf must not be overwritten")
    }

    @Test("duplicate correction-sourced keys degrade instead of crashing")
    func duplicateCorrectionKeysDoNotTrap() async throws {
        // Code review (2026-08-28) finding #1: nothing enforces at most one
        // correction field per key -- a hand-seeded profile (or a future
        // correction-UI bug) can produce two. `refresh()` must not trap.
        let (store, container) = try makeStore()
        let context = ModelContext(container)
        let first = ProfileField(
            key: KnowledgeDerivation.stepsFieldKey, displayText: "First correction",
            source: KnowledgeStore.correctionSourceLabel, asOf: .now
        )
        let second = ProfileField(
            key: KnowledgeDerivation.stepsFieldKey, displayText: "Second correction",
            source: KnowledgeStore.correctionSourceLabel, asOf: .now
        )
        context.insert(KnowledgeProfile(sections: [first, second]))
        try context.save()

        let profile = try await store.refresh(now: .now)
        let stepsField = profile.sections.first { $0.key == KnowledgeDerivation.stepsFieldKey }
        #expect(stepsField != nil, "must degrade to keeping one of the duplicates, never crash")
    }

    @Test("a correction for a key this cycle didn't derive anything for is still kept")
    func untouchedCorrectionSurvives() async throws {
        let (store, container) = try makeStore()
        let context = ModelContext(container)
        let goalField = ProfileField(
            key: "goal.dailySteps",
            displayText: "Goal: 12,000 steps/day",
            source: KnowledgeStore.correctionSourceLabel,
            asOf: .now
        )
        context.insert(KnowledgeProfile(sections: [goalField]))
        try context.save()

        let profile = try await store.refresh(now: .now)
        #expect(profile.sections.contains { $0.key == "goal.dailySteps" && $0.displayText == goalField.displayText })
    }

    @Test("duplicate untouched-correction keys (no derived counterpart) collapse to one, not both")
    func duplicateUntouchedCorrectionKeysDoNotDuplicate() async throws {
        // Code review (2026-09-01): `untouchedCorrections` used to re-filter
        // `profile.sections` directly with no dedup of its own, unlike the
        // `corrections` dictionary a few lines above it. Two correction-sourced
        // fields sharing a key this cycle never derives anything for (e.g. a
        // user goal) would both survive into `profile.sections` every cycle,
        // forever.
        let (store, container) = try makeStore()
        let context = ModelContext(container)
        let first = ProfileField(
            key: "goal.dailySteps", displayText: "First goal",
            source: KnowledgeStore.correctionSourceLabel, asOf: .now
        )
        let second = ProfileField(
            key: "goal.dailySteps", displayText: "Second goal",
            source: KnowledgeStore.correctionSourceLabel, asOf: .now
        )
        context.insert(KnowledgeProfile(sections: [first, second]))
        try context.save()

        let profile = try await store.refresh(now: .now)
        let matches = profile.sections.filter { $0.key == "goal.dailySteps" }
        #expect(matches.count == 1, "must degrade to keeping one of the duplicates, never both")
    }

    @Test("clinical LocalSample types default-excluded from AI context in the persisted profile")
    func clinicalExclusionDefault() async throws {
        let (store, container) = try makeStore()
        let context = ModelContext(container)
        let payload = try! JSONSerialization.data(withJSONObject: ["values": [String: Double]()])
        context.insert(LocalSample(
            externalID: "ecg-1", dataType: GoogleDataType.electrocardiogram.rawValue,
            payloadJSON: payload, start: .now, end: .now, source: "Apple Watch"
        ))
        try context.save()

        let profile = try await store.refresh(now: .now)
        let ecgField = profile.sections.first { $0.key.hasPrefix("clinical.") }
        #expect(ecgField?.isClinical == true)
        #expect(ecgField?.excludedFromAI == true)
    }

    @Test("an unlinked exercise sample far outside the 30-day workouts window is never counted")
    func oldUnlinkedExerciseSampleExcluded() async throws {
        // Code review (2026-08-28) findings #4/#10: `refresh()` used to fetch
        // every `LocalSample` ever stored, unfiltered, so an old orphaned
        // exercise session inflated the "last 30 days" workouts count
        // forever. The fetch is now bounded to the widest window any
        // derivation needs.
        let now = Date()
        let (store, container) = try makeStore()
        let context = ModelContext(container)
        let payload = try! JSONSerialization.data(withJSONObject: ["values": [String: Double]()])
        context.insert(LocalSample(
            externalID: "old-exercise-1", dataType: GoogleDataType.exercise.rawValue,
            payloadJSON: payload,
            start: now.addingTimeInterval(-400 * 86400), end: now.addingTimeInterval(-400 * 86400 + 1800),
            source: "Fitbit Air"
        ))
        try context.save()

        let profile = try await store.refresh(now: now)
        #expect(!profile.sections.contains { $0.key == KnowledgeDerivation.workoutsFieldKey })
        #expect(store.workoutsSummary(days: 30) == "No workouts recorded in the last 30 days.")
    }
}

/// `KnowledgeProfile` (a `@Model` reference type) has its `Sendable`
/// conformance explicitly unavailable, so it can never be an `async let`/
/// `Task` result type (confirmed by direct compilation, same as
/// `KnowledgeStore.refresh(now:)`'s own internal locking couldn't be
/// `Task<KnowledgeProfile, Error>`-based for the same reason). This helper
/// discards the profile so the reentrancy test below can run two calls
/// concurrently via `async let` and check the *persisted* result afterward
/// instead.
@MainActor
private func refreshDiscardingResult(_ store: KnowledgeStore, now: Date) async throws {
    _ = try await store.refresh(now: now)
}

@Suite("KnowledgeStore.refresh reentrancy")
@MainActor
struct KnowledgeStoreReentrancyTests {
    @Test("overlapping calls always persist the later call's now last, never the earlier one")
    func laterCallWinsRegardlessOfCompletionOrder() async throws {
        // Code review (2026-08-28) finding #3. Delays only the *first*
        // `dailySteps` call (`nextDailyStepsDelayNanoseconds` self-resets) --
        // without the fix, the slow call started with `earlier` would still
        // be mid-flight when the fast call started with `later` finishes and
        // saves, and then finish afterward and overwrite it. With the fix,
        // the later call cannot even start its own read until the earlier
        // one has fully finished and released the lock.
        let readStore = MockHealthReadStore()
        readStore.steps = [DailyQuantityValue(day: .now, value: 8000)]
        readStore.nextDailyStepsDelayNanoseconds = 150_000_000
        let (store, container) = try makeStore(readStore: readStore)

        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        let later = earlier.addingTimeInterval(3600)

        async let first: Void = refreshDiscardingResult(store, now: earlier)
        try await Task.sleep(nanoseconds: 20_000_000) // let the first call acquire the lock and start its slow read
        async let second: Void = refreshDiscardingResult(store, now: later)
        _ = try await (first, second)

        let context = ModelContext(container)
        let reloaded = try context.fetch(FetchDescriptor<KnowledgeProfile>())
        #expect(reloaded.first?.updatedAt == later)
    }
}

@Suite("KnowledgeStore tool-facing summaries")
@MainActor
struct KnowledgeStoreSummaryTests {
    @Test("stepsSummary reflects the most recent refresh, re-sliced to the requested window")
    func stepsSummary() async throws {
        let readStore = MockHealthReadStore()
        let now = Date()
        readStore.steps = [
            DailyQuantityValue(day: now, value: 10000),
            DailyQuantityValue(day: now.addingTimeInterval(-86400), value: 6000),
        ]
        let (store, _) = try makeStore(readStore: readStore)
        _ = try await store.refresh(now: now)
        #expect(store.stepsSummary(days: 30, locale: Locale(identifier: "en_US")).contains("8,000"))
    }

    @Test("summaries degrade to a plain sentence, never a crash, with no data")
    func noDataSentences() async throws {
        let (store, _) = try makeStore()
        _ = try await store.refresh(now: .now)
        #expect(store.stepsSummary(days: 7) == "No step data available for the last 7 days.")
        #expect(store.sleepSummary(nights: 7) == "No sleep data available for the last 7 nights.")
        #expect(store.workoutsSummary(days: 7) == "No workouts recorded in the last 7 days.")
        #expect(store.vitalsSummary() == "No recent vitals available.")
    }

    @Test("a window wider than what refresh() cached never overstates the summary's label")
    func summariesClampToCachedWindow() async throws {
        // Code review (2026-09-01): `cachedSteps`/`cachedSleepSegments`/
        // `cachedWorkouts` only ever hold `stepsWindowDays`/`sleepWindowNights`/
        // `workoutsWindowDays` of data -- a caller-requested window wider than
        // that used to be a no-op over the cache yet still rendered a
        // wider-sounding label (e.g. "(90-day avg)") than the data underneath it.
        let readStore = MockHealthReadStore()
        let now = Date()
        readStore.steps = [DailyQuantityValue(day: now, value: 8000)]
        readStore.sleepSegments = [SleepStageSegment(start: now.addingTimeInterval(-3600), end: now, stage: .core)]
        readStore.workouts = [
            WorkoutRecord(id: UUID(), start: now, end: now.addingTimeInterval(1800), activityName: "Running", totalEnergyKilocalories: nil, totalDistanceMeters: nil),
        ]
        let (store, _) = try makeStore(readStore: readStore)
        _ = try await store.refresh(now: now)

        #expect(store.stepsSummary(days: 90).contains("(30-day avg)"))
        #expect(store.sleepSummary(nights: 90).contains("14-night avg"))
        #expect(store.workoutsSummary(days: 90).contains("in the last 30 days"))
    }

    @Test("vitalsSummary combines resting HR and HRV text")
    func vitalsSummary() async throws {
        let readStore = MockHealthReadStore()
        let now = Date()
        readStore.restingHeartRate = [QuantityReading(date: now, value: 55)]
        readStore.heartRateVariability = [QuantityReading(date: now, value: 45)]
        let (store, _) = try makeStore(readStore: readStore)
        _ = try await store.refresh(now: now)
        let summary = store.vitalsSummary()
        #expect(summary.contains("Resting HR"))
        #expect(summary.contains("HRV"))
    }
}

@Suite("KnowledgeStore.readDataTypes")
struct ReadDataTypesTests {
    @Test("names exactly the five HealthKit-backed types WP-19 step 1 specifies")
    func exactReadSet() {
        #expect(Set(KnowledgeStore.readDataTypes) == [
            .steps, .dailyRestingHeartRate, .heartRateVariability, .sleep, .exercise,
        ])
    }

    @Test("never includes a .localOnly type -- those need no HK authorization")
    func excludesLocalOnly() {
        for type in KnowledgeStore.readDataTypes {
            if case .healthKit = type.writability {
                continue
            }
            Issue.record("\(type) is not HealthKit-writable but is in the HK read set")
        }
    }
}

@Suite("KnowledgeStore correction ordering")
@MainActor
struct KnowledgeStoreCorrectionOrderTests {
    @Test("standalone corrections persist in key-sorted order")
    func untouchedCorrectionsAreKeySorted() async throws {
        // `Dictionary.values` order is per-process random; these fields now
        // trim highest-priority with array-index tie-breaks, so hash order
        // would make the surviving correction vary across launches.
        let (store, container) = try makeStore()
        let context = ModelContext(container)
        let zebra = ProfileField(
            key: "user.zebra", displayText: "Zebra goal",
            source: KnowledgeStore.correctionSourceLabel, asOf: .now
        )
        let apple = ProfileField(
            key: "user.apple", displayText: "Apple goal",
            source: KnowledgeStore.correctionSourceLabel, asOf: .now
        )
        context.insert(KnowledgeProfile(sections: [zebra, apple]))
        try context.save()

        let profile = try await store.refresh(now: .now)
        #expect(profile.sections.map(\.key) == ["user.apple", "user.zebra"])
    }
}
