// FirstSyncView.swift
//
// WP-10 (implementation-plan.md): onboarding step 4 of 4 -- calls
// `SyncEngine.syncAll(types:)` for the four P0 types once, on appearance,
// and reports the per-type outcome before handing off to the dashboard.
//
// Real API discovered here (progress.md's WP-09 entry, `SyncEngine.swift`):
// `syncAll(types:)` runs every type *sequentially* and never throws --
// `sync(type:)` always resolves to a `SyncOutcome` (`.ok`/`.error`), so a
// single failing type (e.g. Google 401/429 -- architecture.md §6) never
// blocks the other three or crashes onboarding; the failure just renders as
// an error line here, and again later as the dashboard's per-type error
// state (architecture.md's "errors render rather than vanish").

import SwiftUI
import SyncKit

struct FirstSyncView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    var onFinished: () -> Void

    @State private var isSyncing = true
    @State private var outcomes: [SyncOutcome] = []

    var body: some View {
        OnboardingScaffold(
            step: .firstSync,
            symbol: isSyncing ? nil : "checkmark.circle",
            title: isSyncing ? "First Sync" : "First Sync Complete",
            message: isSyncing
                ? "Pulling your steps, heart rate, weight, and sleep from Google."
                : "Here's what came across. Any type that failed keeps its place and retries on the next sync."
        ) {
            if isSyncing {
                HStack(spacing: 10) {
                    ProgressView().tint(Theme.accent)
                    Text("Syncing your data from Google...")
                        .font(Theme.font(13, .regular, relativeTo: .footnote))
                        .foregroundStyle(Theme.secondary)
                }
                .padding(.top, 20)
                .accessibilityIdentifier("onboarding.firstSync.progress")
            } else {
                // `InstrumentPanel`'s form (TodayComponents.swift): hairline-
                // separated rows on a 4 pt-radius surface, stroked in border.
                VStack(spacing: 0) {
                    ForEach(Array(outcomes.enumerated()), id: \.element.dataType) { index, outcome in
                        if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                        FirstSyncOutcomeRow(outcome: outcome)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
                .padding(.top, 20)
                .accessibilityIdentifier("onboarding.firstSync.summary")
            }
        } actions: {
            if !isSyncing {
                OnboardingPrimaryButton(
                    title: "Continue to Dashboard",
                    accessibilityIdentifier: "onboarding.firstSync.continue",
                    action: onFinished
                )
            }
        }
        // No container-level identifier -- see WelcomeView.swift's note: it
        // would override the more specific `onboarding.firstSync.progress`/
        // `.summary`/`.continue` identifiers set on the children above.
        .task {
            outcomes = await appEnvironment.syncEngine.syncAll(types: AppEnvironment.p0Types)
            isSyncing = false
        }
    }
}

/// One per-type result row, shaped like `TodayMetricRowView`: name on the
/// left, value on the right, and a failed type marked with that view's own
/// 2 pt rust attention bar rather than a system `.red` icon -- the palette
/// has no red (see OnboardingScaffold.swift's error-panel note).
private struct FirstSyncOutcomeRow: View {
    let outcome: SyncOutcome

    private var succeeded: Bool { outcome.status == .ok }

    var body: some View {
        ZStack(alignment: .leading) {
            if !succeeded {
                Rectangle().fill(Theme.accent).frame(width: 2).frame(maxHeight: .infinity)
            }
            HStack {
                Text(outcome.dataType.rawValue)
                    .font(Theme.font(14, .medium, relativeTo: .subheadline))
                    .foregroundStyle(Theme.ink)
                Spacer()
                // Plain `String` (not an inline string-interpolation
                // literal): `Text(LocalizedStringKey)` applies locale-aware
                // grouping to interpolated numbers by default (see
                // SyncTypeRow.swift's note on the same gotcha, found via a
                // real simulator run).
                Text(succeeded ? String(outcome.itemCount) + " item(s)" : "Failed")
                    .font(Theme.font(13, .regular, relativeTo: .footnote))
                    .foregroundStyle(succeeded ? Theme.secondary : Theme.accentDeep)
                    .monospacedDigit()
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            succeeded
                ? "\(outcome.dataType.rawValue): \(outcome.itemCount) items"
                : "\(outcome.dataType.rawValue): failed"
        )
    }
}
