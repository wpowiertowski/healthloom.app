// SyncTypeRow.swift
//
// WP-10 (implementation-plan.md step 2): one row per P0 type -- status icon,
// last-sync time ("synced 9m ago" framing, architecture.md §1), item count,
// and error text. `state` is `nil` only if `SyncEngine` has literally never
// created a `SyncState` row for this type yet (fresh install, before any
// sync attempt); `SyncState.lastStatus` itself defaults to `"idle"`
// (CoreModel's `SyncState.init`), so both cases render identically here.
//
// Every sub-value carries its own accessibility identifier
// (`dashboard.row.<GoogleDataType.rawValue>.*`) rather than relying on
// `.accessibilityElement(children: .combine)`, specifically so the WP-10 UI
// test can assert on each piece independently (implementation-plan.md
// WP-10's "Tests" line: "verified via view/accessibility identifiers"). No
// row-level container identifier is set: applying `.accessibilityIdentifier`
// to the enclosing `VStack` was observed (via a real `xcodebuild test` run
// against the simulator's accessibility snapshot) to cascade that one
// identifier onto every descendant accessibility element, clobbering the
// per-field identifiers below rather than coexisting with them -- so
// `.name` on the display-name `Text` doubles as "does this row exist" for
// callers that just need row-level presence.
//
// `itemCountText`/`Text(itemCountText)`: deliberately a `String` *variable*,
// not `Text("\(state?.itemCount ?? 0)")` -- that literal-interpolation form
// resolves to `Text(LocalizedStringKey)`, whose interpolation applies
// locale-aware grouping separators to interpolated numbers by default
// (observed producing "4,213" instead of "4213" against the real simulator
// run), which is both undesirable here and non-deterministic for the UI
// test asserting on this label's exact text.

import CoreModel
import SwiftUI

struct SyncTypeRow: View {
    let type: GoogleDataType
    let state: SyncState?

    // WP-33 follow-on (Shared/ThemedChrome.swift): Yacht club presentation --
    // `TodayMetricRowView`'s geometry, a rust/gray status dot instead of the
    // green/red SF Symbol, and the 2 pt rust attention bar on errored rows.
    // Copy, structure and every accessibility identifier are unchanged.
    var body: some View {
        ZStack(alignment: .leading) {
            if isErrored { ThemedAttentionBar() }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 6, height: 6)
                        .accessibilityIdentifier("dashboard.row.\(type.rawValue).statusIcon")
                    Text(displayName)
                        .font(Theme.font(14, .medium, relativeTo: .subheadline))
                        .foregroundStyle(Theme.ink)
                        .accessibilityIdentifier("dashboard.row.\(type.rawValue).name")
                    Spacer()
                    Text(itemCountText)
                        .font(Theme.font(15, .regular, relativeTo: .subheadline))
                        .foregroundStyle(Theme.secondary)
                        .monospacedDigit()
                        .accessibilityIdentifier("dashboard.row.\(type.rawValue).itemCount")
                }
                Text(lastSyncedText)
                    .font(Theme.font(11, .regular, relativeTo: .caption2))
                    .foregroundStyle(Theme.tertiary)
                    .accessibilityIdentifier("dashboard.row.\(type.rawValue).lastSynced")
                if let error = state?.lastError, isErrored {
                    ThemedErrorText(
                        message: error,
                        accessibilityIdentifier: "dashboard.row.\(type.rawValue).error"
                    )
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
        }
    }

    private var isErrored: Bool { state?.lastStatus == "error" }

    private var displayName: String {
        switch type {
        case .steps: return "Steps"
        case .heartRate: return "Heart Rate"
        case .weight: return "Weight"
        case .sleep: return "Sleep"
        default: return type.rawValue
        }
    }

    private var itemCountText: String {
        String(state?.itemCount ?? 0)
    }

    /// Rust for a healthy row, gray otherwise -- `TodayHeader`'s own
    /// freshness-dot vocabulary. An errored row is additionally marked by the
    /// 2 pt bar and `Theme.accentDeep` error text, so the state is never
    /// carried by dot color alone. See ThemedChrome.swift's "Status colors".
    private var statusDotColor: Color {
        state?.lastStatus == "ok" ? Theme.accent : Theme.gray
    }

    private var lastSyncedText: String {
        guard let last = state?.lastSyncedAt else { return "Never synced" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Synced \(formatter.localizedString(for: last, relativeTo: Date()))"
    }
}

#Preview {
    ThemedPanel {
        SyncTypeRow(type: .steps, state: SyncState(dataType: "steps", lastSyncedAt: Date(), lastStatus: "ok", itemCount: 4213))
        ThemedRowDivider()
        SyncTypeRow(type: .weight, state: nil)
        ThemedRowDivider()
        SyncTypeRow(type: .sleep, state: SyncState(dataType: "sleep", lastStatus: "error", lastError: "Google 429: rate limited"))
    }
    .padding(22)
    .background(Theme.canvas)
}
