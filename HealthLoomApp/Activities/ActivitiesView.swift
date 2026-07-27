// ActivitiesView.swift
//
// WP-12b (implementation-plan.md) step 5 / architecture.md D13.2: the
// consolidated Activities list -- one entry per activity, chronological,
// grouped by day. Watch workout primary (duration, source); the linked
// Fitbit session's supplementary fields inline ("+ 8.0 km · 520 kcal ·
// Fitbit Air"); Fitbit-only activities (no watch) as full entries.
//
// Data flow: `LocalSample` `.exercise` rows via `@Query` (reactive, exactly
// like `DashboardView`'s own `LocalSample` query); HealthKit workouts via
// `ActivitiesProvider` on `.task`/`.refreshable` (workouts aren't SwiftData
// -- there is nothing for `@Query` to observe; same "poll the non-SwiftData
// source" posture `BackfillView`/`SyncLogView` already use for their
// actor-backed state).

import CoreModel
import SwiftData
import SwiftUI

struct ActivitiesView: View {
    /// This screen is reachable both as a tab root (`HomeView`) and pushed
    /// from the Data dashboard's "Activities" row, which need different
    /// navigation chrome -- see ThemedChrome.swift's "Navigation chrome".
    var chrome: ScreenChrome = .tabRoot

    @Query(sort: \LocalSample.start, order: .reverse) private var localSamples: [LocalSample]
    @State private var workouts: [WorkoutSummary] = []
    @State private var hasLoaded = false
    private let provider = ActivitiesProvider()

    private var entries: [ActivityEntry] {
        let supplements = localSamples
            .filter { $0.dataType == GoogleDataType.exercise.rawValue }
            .map(FitbitActivitySupplement.init(sample:))
        return ActivityConsolidator.consolidate(workouts: workouts, supplements: supplements)
    }

    // WP-33 follow-on (Shared/ThemedChrome.swift): Yacht club presentation --
    // day groups become tracked section headers over surface panels. Data
    // flow, copy and accessibility identifiers are unchanged.
    var body: some View {
        ThemedScreen(title: "Activities", chrome: chrome) {
            if entries.isEmpty && hasLoaded {
                Text("No activities yet. Workouts recorded by your Apple Watch and activities synced from your Fitbit will appear here.")
                    .font(Theme.font(13, .regular, relativeTo: .footnote))
                    .foregroundStyle(Theme.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 24)
                    .accessibilityIdentifier("activities.empty")
            } else {
                ForEach(ActivityConsolidator.groupedByDay(entries), id: \.day) { group in
                    ThemedSectionHeader(
                        title: group.day.formatted(date: .abbreviated, time: .omitted)
                    )
                    ThemedPanel {
                        ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { ThemedRowDivider() }
                            ActivityRow(entry: entry)
                        }
                    }
                }
            }
        }
        .task {
            workouts = await provider.recentWorkouts()
            hasLoaded = true
        }
        .refreshable {
            workouts = await provider.recentWorkouts()
        }
    }
}

#Preview {
    NavigationStack {
        ActivitiesView()
    }
    .environment(AppEnvironment())
}
