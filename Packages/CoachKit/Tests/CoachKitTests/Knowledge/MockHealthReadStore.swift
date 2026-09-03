// MockHealthReadStore.swift
//
// Test-target-only `HealthReadStore` conformer -- an in-memory script, no
// HealthKit entitlement needed. Same precedent as SyncKit's
// `MockHealthStore`/`MockWorkoutBuilder` (HealthStoreProtocol.swift's
// header): the real adapter and this mock share one protocol, so
// `KnowledgeStore`'s own logic never needs to know which one it's talking to.

@testable import CoachKit
import Foundation

// `nonisolated` (code review 2026-09-01): without it, CoachKitTests' own
// `.defaultIsolation(MainActor.self)` (Package.swift) silently makes every
// method below MainActor-isolated, unlike the production `HealthKitReadStore`
// (HealthReadStore.swift, `nonisolated` for the identical reason). That
// mismatch meant the five `async let` reads in `KnowledgeStore.performRefresh()`
// never actually ran concurrently off-MainActor under test, so a regression
// that accidentally removed `nonisolated` from `HealthKitReadStore` (silently
// reintroducing the MainActor-serialization bug finding #15 fixed) would go
// uncaught by every test here.
nonisolated final class MockHealthReadStore: HealthReadStore, @unchecked Sendable {
    var steps: [DailyQuantityValue] = []
    var restingHeartRate: [QuantityReading] = []
    var heartRateVariability: [QuantityReading] = []
    var sleepSegments: [SleepStageSegment] = []
    var workouts: [WorkoutRecord] = []

    /// Consumed (reset to 0) by the *next* call to `dailySteps` -- lets a
    /// test delay exactly one specific `refresh()` call's HealthKit read
    /// without also delaying whichever call runs after it. Used by
    /// `KnowledgeStoreReentrancyTests` (code review 2026-08-28 finding #3).
    var nextDailyStepsDelayNanoseconds: UInt64 = 0

    func dailySteps(from start: Date, to end: Date) async -> [DailyQuantityValue] {
        let delay = nextDailyStepsDelayNanoseconds
        nextDailyStepsDelayNanoseconds = 0
        if delay > 0 {
            try? await Task.sleep(nanoseconds: delay)
        }
        return steps.filter { $0.day >= start && $0.day <= end }
    }

    func dailyRestingHeartRate(from start: Date, to end: Date) async -> [QuantityReading] {
        restingHeartRate.filter { $0.date >= start && $0.date <= end }
    }

    func dailyHeartRateVariability(from start: Date, to end: Date) async -> [QuantityReading] {
        heartRateVariability.filter { $0.date >= start && $0.date <= end }
    }

    func sleepStageSegments(from start: Date, to end: Date) async -> [SleepStageSegment] {
        sleepSegments.filter { $0.start >= start && $0.start <= end }
    }

    func workouts(from start: Date, to end: Date) async -> [WorkoutRecord] {
        workouts.filter { $0.start >= start && $0.start <= end }
    }
}
