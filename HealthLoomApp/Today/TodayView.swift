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
//   - readiness hero <- `.pending` until WP-33 binds it (WP-23's
//     `ReadinessEngine` has landed in CoachKit; `ReadinessDisplay` is
//     already shaped for `.scored`, including the insufficient-signals
//     caption, so WP-33 binds without reshaping);
//   - coach panel <- placeholder until WP-25/34 surface a `DailyInsight`
//     (WP-23's struct + generator exist in CoachKit; no chat surface yet).
//
// **Edit mode (WP-33 step 2) -- documented deviation:** the plan names
// "SwiftUI's iOS 27 reorderable-content API (no custom Edit-mode drag
// plumbing)". This session cannot verify that API against a real SDK (no
// toolchain in the authoring environment -- see progress.md's WP-33
// entry), so Edit presents a themed sheet (`TodayMetricsEditor` below)
// built on the long-standing `List` + `.onMove`/`.onDelete` + active
// `EditMode` machinery -- standard system reorder handles, zero custom
// drag plumbing, and the same `TodayMetricPreferences` persistence the
// final API would bind to. Swapping the sheet for in-place
// reorderable-content once buildable on the Mac is a contained,
// view-only change, flagged in progress.md.

import CoreModel
import SwiftData
import SwiftUI

struct TodayView: View {
    @Query private var syncStates: [SyncState]
    @Query(sort: \LocalSample.end, order: .reverse) private var localSamples: [LocalSample]
    @State private var preferences = TodayMetricPreferences()
    @State private var readings: [TodayMetricKind: TodayMetricReading] = [:]
    @State private var isEditorPresented = false
    private let provider = TodayMetricsProvider()

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
                    .foregroundStyle(Theme.tertiary)
                    .padding(.top, 3)

                Rectangle().fill(Theme.gray).frame(height: 1).padding(.top, 16)

                HeroInstrument(readiness: .pending)
                    .padding(.top, 20)

                Rectangle().fill(Theme.border).frame(height: 1).padding(.top, 22)

                HStack(alignment: .firstTextBaseline) {
                    Text("TODAY")
                        .font(Theme.font(11, .medium, relativeTo: .caption2)).tracking(0.8)
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                    Button {
                        isEditorPresented = true
                    } label: {
                        Text("Edit")
                            .font(Theme.font(12, .regular, relativeTo: .caption))
                            .foregroundStyle(Theme.accentDeep)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("today.editButton")
                }
                .padding(.top, 22).padding(.bottom, 12)

                InstrumentPanel(metrics: displayMetrics)

                if syncStatus.freshness == .never {
                    // WP-33 step 4's pre-first-sync empty state: the rows
                    // above already render their own "No data yet" form;
                    // this line explains why.
                    Text("Your metrics fill in after the first sync.")
                        .font(Theme.font(11, .regular, relativeTo: .caption2))
                        .foregroundStyle(Theme.tertiary)
                        .padding(.top, 8)
                        .accessibilityIdentifier("today.emptyHint")
                }

                CoachPanel(insightText: nil)
                    .padding(.top, 14)
            }
            .padding(.horizontal, 22).padding(.bottom, 24)
        }
        .background(Theme.canvas.ignoresSafeArea())
        .task(id: preferences.visibleKinds) {
            await refreshReadings()
        }
        .refreshable {
            await refreshReadings()
        }
        .sheet(isPresented: $isEditorPresented) {
            TodayMetricsEditor(preferences: preferences)
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
}

// MARK: - Edit sheet (WP-33 step 2)

struct TodayMetricsEditor: View {
    @Environment(\.dismiss) private var dismiss
    let preferences: TodayMetricPreferences

    // WP-33 follow-on (Shared/ThemedChrome.swift): the one modal in the app,
    // brought onto the same palette as the screens behind it. It keeps `List`
    // + `EditMode` -- the system reorder handles are the whole point of this
    // sheet, and reimplementing drag-and-drop to avoid a `List` would trade
    // real functionality for cosmetics -- but the system background is
    // replaced with `Theme.canvas`, rows sit on `Theme.surface`, and the
    // remove affordance moves from `.red` to the palette's accent.
    var body: some View {
        VStack(spacing: 0) {
            // Done lives in the header, not a `ToolbarItem`. On iOS 27 a
            // `ToolbarItem` reports its content's `accessibilityIdentifier`
            // on *both* the toolbar's wrapper element and the inner button,
            // so `TodayUITests`' identifier-only
            // `.descendants(matching: .any)` query matched two elements and
            // the tap failed with "Multiple matching elements found"
            // (element dump: Other[today.editor.done] > Other >
            // Button[today.editor.done]). Neither
            // `.accessibilityElement(children: .ignore)` on the button nor
            // moving the identifier onto the label suppressed the wrapper's
            // copy -- both tried against a real simulator run. A plain
            // in-content button has exactly one element, which is why
            // `dashboard.syncNow` (a `ThemedIconButton`) resolves cleanly
            // under the same query. Dropping the toolbar also removes the
            // last stock navigation bar in the app.
            ThemedHeader(title: "Edit Today") {
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .font(Theme.font(15, .medium, relativeTo: .callout))
                        .foregroundStyle(Theme.accentDeep)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("today.editor.done")
            }
            .padding(.horizontal, 22)

            List {
                Section {
                    ForEach(preferences.visibleKinds) { kind in
                        HStack(spacing: 12) {
                            // Explicit remove button rather than the system
                            // EditMode delete flow -- deterministic for the
                            // WP-33 edit-mode UI test and a single obvious
                            // affordance for VoiceOver.
                            Button {
                                preferences.hide(kind)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .font(.system(size: 16, weight: .light))
                                    .foregroundStyle(Theme.accent)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(kind.displayName)")
                            .accessibilityIdentifier("today.editor.remove.\(kind.rawValue)")
                            Text(kind.displayName)
                                .font(Theme.font(14, .medium, relativeTo: .subheadline))
                                .foregroundStyle(Theme.ink)
                                .accessibilityIdentifier("today.editor.row.\(kind.rawValue)")
                        }
                        .listRowBackground(Theme.surface)
                    }
                    .onMove { source, destination in
                        preferences.move(fromOffsets: source, toOffset: destination)
                    }
                } header: {
                    Text("SHOWN")
                        .font(Theme.font(11, .medium, relativeTo: .caption2)).tracking(0.8)
                        .foregroundStyle(Theme.secondary)
                } footer: {
                    Text("Drag to reorder. Removed metrics keep syncing \u{2014} they just leave this panel.")
                        .font(Theme.font(11.5, .regular, relativeTo: .caption))
                        .foregroundStyle(Theme.tertiary)
                }

                if !preferences.hiddenKinds.isEmpty {
                    Section {
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
                                }
                            }
                            // Deliberately NO `.buttonStyle(.plain)` here,
                            // unlike the remove button above. This button IS
                            // the whole row, and with `EditMode` active a
                            // `List` row only delivers taps to a full-row
                            // button under the default style -- `.plain`
                            // made this silently dead: a diagnostic run
                            // showed `today.editor.add.weight` still present
                            // and no `today.editor.row.weight` after tapping
                            // it, while the (inset, non-full-row) remove
                            // button kept working. The label sets its own
                            // colors, so the default style changes nothing
                            // visually.
                            .listRowBackground(Theme.surface)
                            .accessibilityIdentifier("today.editor.add.\(kind.rawValue)")
                        }
                    } header: {
                        Text("MORE METRICS")
                            .font(Theme.font(11, .medium, relativeTo: .caption2)).tracking(0.8)
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
        }
        .background(Theme.canvas.ignoresSafeArea())
        .tint(Theme.accent)
    }
}

#Preview {
    TodayView()
        .environment(AppEnvironment())
}
