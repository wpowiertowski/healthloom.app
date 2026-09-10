// BackfillView.swift
//
// WP-15 (implementation-plan.md) step 3: "UI: progress per type ('Mar 2026
// … done' style), pause/resume controls, and a horizon picker that can
// extend an already-completed backfill (extending re-opens the walk)."
//
// Talks to `AppEnvironment.backfillCoordinator` (SyncKit's `actor
// BackfillCoordinator`, `Packages/SyncKit/Sources/SyncKit/Backfill/
// BackfillCoordinator.swift`) exclusively through its `async` public API --
// every actor call in this file is wrapped in a `Task { ... }` from a
// synchronous SwiftUI action, or awaited directly inside the one `.task`
// modifier below, matching this app target's existing `DashboardView
// .syncNow()` pattern (`Dashboard/DashboardView.swift`) for calling into an
// actor from a plain `Button` action.
//
// Deliberately **polls** `backfillCoordinator.statuses()` on a plain timer
// loop (`.task`'s `while !Task.isCancelled` below) rather than trying to
// observe `SyncState` reactively via `@Query`: `BackfillTypeStatus` also
// folds in `BackfillCoordinator`'s in-actor `horizon`/`isPausedNow` state
// and `BackfillHorizonRecordStore`'s completed-horizon bookkeeping -- neither
// of which is SwiftData-backed (`Backfill/BackfillTypes.swift`'s
// `BackfillHorizonRecordStore` doc comment explains why, a CoreModel-scope
// gap this WP papers over with a small side-store) -- so a `@Query` alone
// could show a fresh `backfillCursor` but a stale "is this actually done for
// the *current* horizon" answer. Polling `coordinator.statuses()` (which
// itself reads `SyncState` fresh every call, `BackfillCoordinator.status(for:)`'s
// doc comment) keeps exactly one source of truth for this whole screen.

import CoreModel
import SwiftUI
import SyncKit

struct BackfillView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @State private var statuses: [BackfillTypeStatus] = []
    @State private var isPaused = false
    @State private var horizon: BackfillHorizon = .defaultHorizon

    // WP-33 follow-on (Shared/ThemedChrome.swift): Yacht club presentation.
    // Always pushed (from the Data dashboard), so it keeps the system
    // navigation bar for back/swipe -- see ThemedChrome.swift.
    var body: some View {
        ThemedScreen(title: "Historical Backfill", chrome: .pushed) {
            ThemedPanel {
                horizonPicker
                ThemedRowDivider()
                pauseResumeButton
            }
            .padding(.top, 18)

            ThemedSectionHeader(title: "Backfill Progress")
            ThemedPanel {
                ForEach(Array(statuses.enumerated()), id: \.element.dataType) { index, status in
                    if index > 0 { ThemedRowDivider() }
                    BackfillTypeRow(status: status)
                }
            }
        }
        .task {
            await appEnvironment.backfillCoordinator.start()
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                await refresh()
            }
        }
    }

    private var horizonPicker: some View {
        // Label on the left, value on the right -- the panel-row shape every
        // other themed row uses. A bare `Picker` renders its menu centered
        // and drops the label entirely inside a plain `VStack` (it only gets
        // the leading-label treatment for free inside a `List`), so the label
        // is drawn explicitly and the picker's own is hidden.
        HStack {
            Text("Import history back to")
                .font(Theme.font(14, .medium, relativeTo: .subheadline))
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 12)
            Picker(
                "Import history back to",
                selection: Binding(get: { horizon }, set: { changeHorizon(to: $0) })
            ) {
                Text("30 days").tag(BackfillHorizon.days30)
                Text("90 days").tag(BackfillHorizon.days90)
                Text("1 year").tag(BackfillHorizon.year1)
                Text("All available history").tag(BackfillHorizon.all)
            }
            .labelsHidden()
            .tint(Theme.accentDeep)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .accessibilityIdentifier("backfill.horizonPicker")
    }

    private var pauseResumeButton: some View {
        Button {
            togglePause()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isPaused ? "play" : "pause")
                    .font(.system(size: 14, weight: .light))
                Text(isPaused ? "Resume Backfill" : "Pause Backfill")
                    .font(Theme.font(14, .medium, relativeTo: .subheadline))
                Spacer()
            }
            .foregroundStyle(Theme.accentDeep)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("backfill.pauseResumeButton")
    }

    private func changeHorizon(to newHorizon: BackfillHorizon) {
        horizon = newHorizon
        Task {
            let coordinator = appEnvironment.backfillCoordinator
            await coordinator.setHorizon(newHorizon)
            // A previously-finished walk's background loop has already
            // exited (`BackfillCoordinator.runLoop()`'s `isFullyDone()`
            // check) -- extending the horizon needs `start()` called again
            // to reopen it; `start()` itself is a no-op if the loop is
            // already running, so this is always safe to call.
            await coordinator.start()
            await refresh()
        }
    }

    private func togglePause() {
        Task {
            let coordinator = appEnvironment.backfillCoordinator
            if isPaused {
                await coordinator.resume()
            } else {
                await coordinator.pause()
            }
            await refresh()
        }
    }

    private func refresh() async {
        let coordinator = appEnvironment.backfillCoordinator
        statuses = await coordinator.statuses()
        isPaused = await coordinator.isPausedNow
        horizon = await coordinator.currentHorizon()
        // Round-7 item 9: restart a loop that exited on no-progress
        // (e.g. the user re-enabled a type) — `start()` no-ops when
        // running or paused, so this is cheap. Idle rounds then run at
        // poll cadence while this view is open only (not process-
        // lifetime like the old spin).
        if !(await coordinator.isFullyDone()), !(await coordinator.isLoopRunning) {
            await coordinator.start()
        }
    }
}

#Preview {
    NavigationStack {
        BackfillView()
    }
    .environment(AppEnvironment())
}
