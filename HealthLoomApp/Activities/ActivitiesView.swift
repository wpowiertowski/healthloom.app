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

    // WP-33 follow-on (Shared/ThemedChrome.swift): Yacht club presentation.
    // WP-46 / D16.8: the locked mockup's detailing -- a summary line under
    // the title, date rules with a count, and rows with a duration field.
    // Data flow and accessibility identifiers are unchanged.
    var body: some View {
        // Consolidated once per render; the summary, the grouping and every
        // row's duration fraction all read this one array.
        let entries = self.entries
        ThemedScreen(title: "Activities", chrome: chrome) {
            if entries.isEmpty && hasLoaded {
                Text("No activities yet. Workouts recorded by your Apple Watch and activities synced from your Fitbit will appear here.")
                    .font(Theme.font(Theme.Step.caption, .regular, relativeTo: .footnote))
                    .foregroundStyle(Theme.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 24)
                    .accessibilityIdentifier("activities.empty")
            } else if !entries.isEmpty {
                ActivitySummaryLine(summary: ActivitySummary(entries: entries))
                ForEach(ActivityConsolidator.groupedByDay(entries), id: \.day) { group in
                    ActivityDayRule(day: group.day, count: group.entries.count)
                    ThemedPanel {
                        ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { ThemedRowDivider() }
                            ActivityRow(
                                entry: entry,
                                durationFraction: ActivitySummary.durationFraction(of: entry, in: entries)
                            )
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

/// "7 SESSIONS   3 H 49 M   10 DAYS" over a hairline: the mockup's
/// kicker, read off the list itself (`ActivitySummary`).
struct ActivitySummaryLine: View {
    let summary: ActivitySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // One line while it fits; stacked at large text sizes rather
            // than breaking a word ("SESSIO / NS" at AXXXL).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { partViews }
                VStack(alignment: .leading, spacing: 4) { partViews }
            }
            .font(Theme.mono(Theme.Step.micro, .medium, relativeTo: .caption2))
            .tracking(1.2)
            .foregroundStyle(Theme.secondary)
            .padding(.top, 14)
            .padding(.bottom, 12)
            Rectangle().fill(Theme.border).frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.parts.joined(separator: ", "))
        .accessibilityIdentifier("activities.summary")
    }

    private var partViews: some View {
        ForEach(summary.parts, id: \.self) { part in
            SilkscreenText(part)
        }
    }
}

/// The mockup's date rule: "SUN 20 SEP ———— 2".
struct ActivityDayRule: View {
    let day: Date
    let count: Int

    // `Date.formatted` alone uses the process locale and time zone, not the
    // view's: a rule could then name a different day than the calendar that
    // grouped it (caught in the WP-46 snapshots -- a Sunday swim labelled
    // "Sat, Sep 19"). Formatting through the environment keeps both in step.
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone

    private var style: Date.FormatStyle {
        Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone)
    }

    var body: some View {
        HStack(spacing: 10) {
            SilkscreenText(day.formatted(style.weekday(.abbreviated).day().month(.abbreviated)))
                .font(Theme.mono(Theme.Step.micro, .medium, relativeTo: .caption2))
                .tracking(1.2)
                .foregroundStyle(Theme.secondary)
            Rectangle().fill(Theme.border).frame(height: 1)
            Text("\(count)")
                .font(Theme.mono(Theme.Step.micro, .regular, relativeTo: .caption2))
                .foregroundStyle(Theme.tertiary)
        }
        .padding(.top, 20)
        .padding(.bottom, 9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(day.formatted(style.weekday(.wide).day().month(.wide))), \(count == 1 ? "1 activity" : "\(count) activities")"
        )
        .accessibilityAddTraits(.isHeader)
    }
}

#Preview {
    NavigationStack {
        ActivitiesView()
    }
    .environment(AppEnvironment())
}
