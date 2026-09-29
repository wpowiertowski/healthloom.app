// CoachWorkoutReader.swift
//
// WP-77: the app side of the coach's workout tools (`CoachWorkoutQueries`,
// CoachKit). Thin adapter: it reads the same consolidated entries the
// Activities tab lists and the same series its detail screen plots, then
// hands them to `CoachWorkoutText`, where the answers are built and tested.
// Never asks for HealthKit access mid-chat -- it says when opening an
// activity would grant more -- and never reads routes.

import CoachKit
import CoreModel
import Foundation
import HealthKit
import SwiftData
import SyncKit

@MainActor
final class CoachWorkoutReader {
    private let workouts: ActivitiesProvider
    private let details: ActivityDetailProvider
    private let modelContainer: ModelContainer
    private let healthStore: HKHealthStore
    /// Read at each call, so answers follow a units change mid-chat (WP-79).
    private let units: @MainActor () -> UnitPreferences

    init(
        healthKitAuth: HealthKitAuth,
        modelContainer: ModelContainer,
        units: @escaping @MainActor () -> UnitPreferences,
        healthStore: HKHealthStore = HKHealthStore()
    ) {
        self.workouts = ActivitiesProvider(healthStore: healthStore)
        self.details = ActivityDetailProvider(
            healthKitAuth: healthKitAuth,
            modelContainer: modelContainer,
            requestsAuthorization: false,
            healthStore: healthStore
        )
        self.modelContainer = modelContainer
        self.healthStore = healthStore
        self.units = units
    }

    /// The tools' reads. The closures hold the reader (nothing else does),
    /// and the reader holds no closure, so there's no cycle.
    var queries: CoachWorkoutQueries {
        CoachWorkoutQueries(
            list: { days in await self.list(days: days) },
            detail: { number, measurement in await self.detail(number: number, measurement: measurement) }
        )
    }

    func list(days: Int, now: Date = Date()) async -> String {
        CoachWorkoutText.list(
            await entries(now: now), days: days, now: now, units: units(), calendar: .autoupdatingCurrent, locale: .current
        )
    }

    func detail(number: Int, measurement: String?, now: Date = Date()) async -> String {
        let entries = await entries(now: now)
        guard let entry = CoachWorkoutText.entry(number: number, in: entries) else {
            return CoachWorkoutText.noWorkout(number: number, count: entries.count, days: GetWorkoutsTool.windowDays)
        }
        let samples = await details.detail(for: entry, includingRoute: false).samples
        let units = units()
        let series = ActivitySeriesBuilder.series(samples, from: entry.start, to: entry.end, units: units)
        return CoachWorkoutText.detail(
            entry, number: number, series: series, units: units, measurement: measurement,
            needsReadAccess: await needsReadAccess(), calendar: .autoupdatingCurrent, locale: .current
        )
    }

    /// The Activities tab's list for the coach's window: HealthKit workouts
    /// with their Google sessions folded in, newest first.
    private func entries(now: Date) async -> [ActivityEntry] {
        let since = now.addingTimeInterval(-Double(GetWorkoutsTool.windowDays) * 86_400)
        let workouts = await workouts.recentWorkouts(daysBack: GetWorkoutsTool.windowDays, now: now)
        let sessions = (try? ModelContext(modelContainer).fetch(ActivitiesView.exerciseSessions)) ?? []
        let supplements = sessions.filter { $0.start >= since }.map(FitbitActivitySupplement.init(sample:))
        return ActivityConsolidator.consolidate(workouts: workouts, supplements: supplements)
    }

    /// Whether the detail screen's extra read types were never asked for,
    /// so running power, stride and the rest can't be read yet.
    private func needsReadAccess() async -> Bool {
        let status = try? await healthStore.statusForAuthorizationRequest(toShare: [], read: ActivityDetailProvider.readTypes)
        return status == .shouldRequest
    }
}
