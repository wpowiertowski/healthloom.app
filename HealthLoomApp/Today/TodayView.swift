// TodayView.swift
//
// WP-33 (implementation-plan.md) / architecture.md D12, retyped by WP-40 /
// D16: the Today screen, composed from TodayComponents.swift and bound to
// real data. Data flow below is unchanged by D16 -- what changed is the
// hero it composes (`JunghansDial` + `SignalIndex`) and the type scale:
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
    /// Opens the Coach tab from the coach panel (plan WP-33 step 1).
    /// Nil in previews and anywhere without tab control.
    var onOpenCoach: (() -> Void)?

    @Query private var syncStates: [SyncState]
    @Query(sort: \LocalSample.end, order: .reverse) private var localSamples: [LocalSample]
    // WP-34: the coach panel binds the latest generated morning insight
    // (persisted by `MorningInsightRunner`); nil until the first run.
    // Unfiltered query + in-code prefix match: `#Predicate` supports no
    // `hasPrefix`, and the table is tiny (insights are daily).
    @Query(sort: \DerivedInsight.createdAt, order: .reverse) private var derivedInsights: [DerivedInsight]

    private var latestMorningInsight: DerivedInsight? {
        let today = Calendar.current
        return derivedInsights.first { Self.isCurrentMorningInsight($0, now: Date(), calendar: today) }
    }

    /// A persisted insight counts for the panel only when it is both ours
    /// and from today (F3): a days-old row renders dateless, so without
    /// this a week-old insight would present as this morning's. Pure for
    /// tests; the view supplies `now`.
    static func isCurrentMorningInsight(_ insight: DerivedInsight, now: Date, calendar: Calendar) -> Bool {
        insight.sourceProvider.hasPrefix(MorningInsightRunner.insightSourceProvider)
            && calendar.isDate(insight.createdAt, inSameDayAs: now)
    }
    @State private var preferences = TodayMetricPreferences()
    @State private var readings: [TodayMetricKind: TodayMetricReading] = [:]
    /// Kinds established to have no data at all in the availability window,
    /// so their row is dropped rather than shown empty. Starts empty: a row
    /// appears until absence is *proven*, never while it is unknown.
    @State private var unavailableKinds: Set<TodayMetricKind> = []
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
                    .font(Theme.font(Theme.Step.lead, .medium, relativeTo: .title3))
                    .foregroundStyle(Theme.ink)
                Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(Theme.font(Theme.Step.caption, .regular, relativeTo: .caption))
                    // Secondary, not tertiary: the date is essential text
                    // and tertiary is placeholders-only (L2).
                    .foregroundStyle(Theme.secondary)
                    .padding(.top, 3)

                Rectangle().fill(Theme.gray).frame(height: 1).padding(.top, 16)

                HeroInstrument(readiness: readiness)
                    .padding(.top, 20)

                Rectangle().fill(Theme.border).frame(height: 1).padding(.top, 22)

                HStack(alignment: .firstTextBaseline) {
                    SilkscreenText("Today")
                        .font(Theme.mono(Theme.Step.micro, .medium, relativeTo: .caption2)).tracking(0.8)
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                    Button {
                        isEditing.toggle()
                    } label: {
                        Text(isEditing ? "Done" : "Edit")
                            .font(Theme.font(Theme.Step.caption, .regular, relativeTo: .caption))
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
                    SilkscreenText("More metrics")
                        .font(Theme.mono(Theme.Step.micro, .medium, relativeTo: .caption2)).tracking(0.8)
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
                                        .font(Theme.font(Theme.Step.body, .regular, relativeTo: .subheadline))
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
                    .background(Rectangle().fill(Theme.surface))
                    .overlay(Rectangle().stroke(Theme.border))
                }

                if syncStatus.freshness == .never {
                    // WP-33 step 4's pre-first-sync empty state: the rows
                    // above already render their own "No data yet" form;
                    // this line explains why.
                    Text("Your metrics fill in after the first sync.")
                        .font(Theme.font(Theme.Step.caption, .regular, relativeTo: .caption2))
                        // Secondary: instructional text is essential (L2).
                        .foregroundStyle(Theme.secondary)
                        .padding(.top, 8)
                        .accessibilityIdentifier("today.emptyHint")
                }

                CoachPanel(insightText: latestMorningInsight?.text, onOpenCoach: onOpenCoach)
                    .padding(.top, 14)
            }
            .padding(.horizontal, 22).padding(.bottom, 24)
        }
        // Not a `ThemedScreen`, so it reserves the floating bar's height
        // itself (HomeView).
        .clearsTabBar()
        .background(Theme.canvas.ignoresSafeArea())
        // Today draws its own header and has never had a navigation bar.
        // It now sits in the shell's `NavigationStack` (HomeView), so the
        // bar is hidden here the way `ThemedScreen` hides it for the other
        // tab roots -- otherwise an empty bar would push the header down.
        .toolbar(.hidden, for: .navigationBar)
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
        // WP-37: display units follow the locale (single-sourced from
        // CoachKit's mapping — HealthKit keeps canonical units).
        let unitSystem = ContextAssembler.defaultUnitSystem(for: .current)
        let kinds = TodayMetricKind.rows(
            visible: preferences.visibleKinds,
            unavailable: unavailableKinds
        )
        return kinds.map { kind in
            TodayMetricFormatter.display(kind: kind, reading: readings[kind], unitSystem: unitSystem)
        }
    }

    private func refreshReadings() async {
        readings = await provider.readings(for: preferences.visibleKinds)
        unavailableKinds = await provider.unavailableKinds(among: preferences.visibleKinds)
    }

    /// WP-33 step 1's readiness binding: aggregates -> engine -> history
    /// -> hero. Any HealthKit gap (denied/unavailable/empty) surfaces as
    /// all-nil inputs, which `display` maps to `.pending` — the hero never
    /// renders the engine's all-nil fallback score.
    private func refreshReadiness() async {
        let inputs = ReadinessInputsProvider.assemble(await readinessProvider.aggregates())
        let result = ReadinessEngine.score(inputs: inputs, recentScores: scoreHistory.recentScores())
        // Round-10 item 5: this record is the TOGGLE-INDEPENDENT path
        // — daily Today opens accumulate history (and the delta)
        // whether or not morning insights is enabled; the runner is a
        // second writer, not the only one.
        if result.signalsUsed > 0 {
            scoreHistory.record(score: result.score)
        }
        readiness = ReadinessInputsProvider.display(result, inputs: inputs)
    }
}

#Preview {
    TodayView()
        .environment(AppEnvironment())
}
