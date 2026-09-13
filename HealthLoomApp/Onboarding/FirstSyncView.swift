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
    /// Onboarding-skip-Google: when true the view renders the Google-less state
    /// (honest copy, per-type rows replaced by the not-connected state) and NEVER
    /// calls `syncAll` — without credentials it would only mint per-type error rows
    /// and lie with "Pulling ... from Google" copy. Carried by `OnboardingStep.
    /// firstSync(googleSkipped:)`; no other value is representable.
    var googleSkipped: Bool = false
    var onFinished: () -> Void

    @State private var isSyncing = true
    @State private var outcomes: [SyncOutcome] = []

    var body: some View {
        OnboardingScaffold(
            step: .firstSync,
            symbol: googleSkipped ? "checkmark.circle" : (isSyncing ? nil : "checkmark.circle"),
            title: googleSkipped ? "You're Set Up" : (isSyncing ? "First Sync" : "First Sync Complete"),
            message: googleSkipped
                ? "Google isn't connected, so there's nothing to pull yet. Health data you record on this iPhone still appears on your dashboard, and you can connect Google any time from Settings."
                : (isSyncing
                    ? "Pulling your steps, heart rate, weight, and sleep from Google."
                    : "Here's what came across. Any type that failed keeps its place and retries on the next sync.")
        ) {
            if googleSkipped {
                // No spinner, no per-type rows: nothing was pulled and nothing
                // failed. The title/message above carry the state; the skip-path
                // UI test pins this screen by its "You're Set Up" title.
                EmptyView()
            } else if isSyncing {
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
            if googleSkipped || !isSyncing {
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
            // Skipped leg: no credentials, no sync — the task is a no-op so the
            // screen cannot flash "Pulling ... from Google" or mint error rows.
            guard !googleSkipped else { return }
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
