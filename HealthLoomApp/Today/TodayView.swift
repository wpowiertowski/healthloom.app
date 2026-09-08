// TodayView.swift
//
// WP-33 (implementation-plan.md) / architecture.md D12: the Yacht club
// Today screen, composed from TodayComponents.swift and bound to real data:
//   - sync status <- `SyncState` via `@Query` (newest `lastSyncedAt`
//     across all types; device label from the newest `LocalSample.source`
//     when one exists) with the stale->24 h and never-synced states
//     (TodayHeaderModel.swift);
//   - metric rows <- HealthKit today-values (TodayMetricsProvider.swift),
//     ordered/filtered by `TodayMetricPreferences` (UserDefaults);
//   - readiness hero <- `ReadinessEngine` via `ReadinessInputsProvider`
//     (HealthKit aggregates) + `ReadinessScoreHistory` (delta caption);
//     zero-signal results render `.pending`, never the engine's
//     all-nil fallback;
//   - coach panel <- placeholder until WP-25/34 surface a `DailyInsight`
//     (WP-23's struct + generator exist in CoachKit; no chat surface yet).
//
// **Edit mode (WP-33 step 2, as planned):** in-place editing with iOS 27's
// reorderable-content API (`ForEach.reorderable()` + `reorderContainer`,
// gated on the Edit toggle) -- system drag handles, zero custom drag
// plumbing, bound to the same `TodayMetricPreferences` store. Add/remove
// stays explicit minus/plus buttons (deterministic for the UI test, one
// obvious VoiceOver affordance each); drag-reorder itself is covered by
// unit tests over the pure difference-mapping, not by UI-test gestures.

import CoachKit
import CoreModel
import SwiftData
import SwiftUI

struct TodayView: View {
    @Query private var syncStates: [SyncState]
    @Query(sort: \LocalSample.end, order: .reverse) private var localSamples: [LocalSample]
    // WP-34: the coach panel binds the latest generated morning insight
    // (persisted by `MorningInsightRunner`); nil until the first run.
    // Unfiltered query + in-code prefix match: `#Predicate` supports no
    // `hasPrefix`, and the table is tiny (insights are daily).
    @Query(sort: \DerivedInsight.createdAt, order: .reverse) private var derivedInsights: [DerivedInsight]

    private var latestMorningInsight: DerivedInsight? {
        derivedInsights.first { $0.sourceProvider.hasPrefix(MorningInsightRunner.insightSourceProvider) }
    }
    @State private var preferences = TodayMetricPreferences()
    @State private var readings: [TodayMetricKind: TodayMetricReading] = [:]
    @State private var readiness: ReadinessDisplay = .pending
    @State private var isEditing = false
    private let provider = TodayMetricsProvider()
    private let readinessProvider = ReadinessInputsProvider()
    private let scoreHistory = ReadinessScoreHistory()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TodayHeader(syncStatus: syncStatus)
                    .padding(.top, 12).padding(.bottom, 16)

                Text(TodayGreeting.text(hour: Calendar.current.component(.hour, from: Date())))
                    .font(Theme.font(19, .medium, relativeTo: .title3))
                    .foregroundStyle(Theme.ink)
                Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(Theme.font(12, .regular, relativeTo: .caption))
                    // Secondary, not tertiary: the date is essential text
                    // and tertiary is placeholders-only (L2).
                    .foregroundStyle(Theme.secondary)
                    .padding(.top, 3)

                Rectangle().fill(Theme.gray).frame(height: 1).padding(.top, 16)

                HeroInstrument(readiness: readiness)
                    .padding(.top, 20)

                Rectangle().fill(Theme.border).frame(height: 1).padding(.top, 22)

                HStack(alignment: .firstTextBaseline) {
                    Text("TODAY")
                        .font(Theme.font(11, .medium, relativeTo: .caption2)).tracking(0.8)
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                    Button {
                        isEditing.toggle()
                    } label: {
                        Text(isEditing ? "Done" : "Edit")
                            .font(Theme.font(12, .regular, relativeTo: .caption))
                            .foregroundStyle(isEditing ? Theme.accent : Theme.accentDeep)
                            .overlay(
                                Rectangle()
                                    .fill(isEditing ? Theme.accent : .clear)
                                    .frame(height: 1),
                                alignment: .bottom
                            )
                    }
                    .buttonStyle(.plain)
                    // Generous touch target (and audit-clean): the 12pt
                    // label alone is too small to tap reliably.
                    .frame(minWidth: 48, minHeight: 48)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("today.editButton")
                }
                .padding(.top, 22).padding(.bottom, 12)

                InstrumentPanel(
                    metrics: displayMetrics,
                    editing: isEditing,
                    onRemove: { preferences.hide($0) },
                    onMove: { preferences.reorder($0) }
                )

                if isEditing, !preferences.hiddenKinds.isEmpty {
                    Text("MORE METRICS")
                        .font(Theme.font(11, .medium, relativeTo: .caption2)).tracking(0.8)
                        .foregroundStyle(Theme.secondary)
                        .padding(.top, 16).padding(.bottom, 8)
                    VStack(spacing: 0) {
                        ForEach(preferences.hiddenKinds) { kind in
                            Button {
                                preferences.show(kind)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "plus.circle")
                                        .font(.system(size: 16, weight: .light))
                                        .foregroundStyle(Theme.accent)
                                    Text(kind.displayName)
                                        .font(Theme.font(14, .regular, relativeTo: .subheadline))
                                        .foregroundStyle(Theme.ink)
                                    Spacer()
                                }
                                .padding(.horizontal, 16).padding(.vertical, 12)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Add \(kind.displayName)")
                            .accessibilityIdentifier("today.add.\(kind.rawValue)")
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
                }

                if syncStatus.freshness == .never {
                    // WP-33 step 4's pre-first-sync empty state: the rows
                    // above already render their own "No data yet" form;
                    // this line explains why.
                    Text("Your metrics fill in after the first sync.")
                        .font(Theme.font(11, .regular, relativeTo: .caption2))
                        // Secondary: instructional text is essential (L2).
                        .foregroundStyle(Theme.secondary)
                        .padding(.top, 8)
                        .accessibilityIdentifier("today.emptyHint")
                }

                CoachPanel(insightText: latestMorningInsight?.text)
                    .padding(.top, 14)
            }
            .padding(.horizontal, 22).padding(.bottom, 24)
        }
        .background(Theme.canvas.ignoresSafeArea())
        .task(id: preferences.visibleKinds) {
            await refreshReadings()
            await refreshReadiness()
        }
        .refreshable {
            await refreshReadings()
            await refreshReadiness()
        }
    }

    private var syncStatus: TodaySyncStatus {
        TodaySyncStatus.make(
            lastSyncedAt: syncStates.compactMap(\.lastSyncedAt).max(),
            deviceLabel: localSamples.first?.source,
            now: Date()
        )
    }

    private var displayMetrics: [TodayMetricDisplay] {
        preferences.visibleKinds.map { kind in
            TodayMetricFormatter.display(kind: kind, reading: readings[kind])
        }
    }

    private func refreshReadings() async {
        readings = await provider.readings(for: preferences.visibleKinds)
    }

    /// WP-33 step 1's readiness binding: aggregates -> engine -> history
    /// -> hero. Any HealthKit gap (denied/unavailable/empty) surfaces as
    /// all-nil inputs, which `display` maps to `.pending` — the hero never
    /// renders the engine's all-nil fallback score.
    private func refreshReadiness() async {
        let inputs = ReadinessInputsProvider.assemble(await readinessProvider.aggregates())
        let result = ReadinessEngine.score(inputs: inputs, recentScores: scoreHistory.recentScores())
        if result.signalsUsed > 0 {
            scoreHistory.record(score: result.score)
        }
        readiness = ReadinessInputsProvider.display(result)
    }
}

#Preview {
    TodayView()
        .environment(AppEnvironment())
}
