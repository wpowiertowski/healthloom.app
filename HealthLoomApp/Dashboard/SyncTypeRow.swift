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
// WP-56: the right-hand column is the 7-day average and its change against
// the 30-day average (`DataTrendText`, computed by the caller from Apple
// Health), not `SyncState.itemCount` -- a running total of readings ever
// synced read as a heart rate ("373285") and meant nothing at a glance.

import CoreModel
import SwiftUI

struct SyncTypeRow: View {
    let type: GoogleDataType
    let state: SyncState?
    let trend: DataTrendText

    // WP-33 follow-on (Shared/ThemedChrome.swift): Yacht club presentation --
    // `TodayMetricRowView`'s geometry, a rust/gray status dot instead of the
    // green/red SF Symbol, and the 2 pt rust attention bar on errored rows.
    // Copy, structure and every accessibility identifier are unchanged.
    var body: some View {
        ZStack(alignment: .leading) {
            if isErrored { ThemedAttentionBar() }
            VStack(alignment: .leading, spacing: 5) {
                DataRowTitleLine(trend: trend, identifierPrefix: "dashboard.row.\(type.rawValue)") {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(statusDotColor)
                            .frame(width: 6, height: 6)
                            // Decorative status dot (WP-37): an exposed 6pt
                            // element fails the hit-region audit; the row's
                            // freshness text carries the same meaning.
                            .accessibilityHidden(true)
                            .accessibilityIdentifier("dashboard.row.\(type.rawValue).statusIcon")
                        Text(displayName)
                            .font(Theme.font(Theme.Step.body, .medium, relativeTo: .subheadline))
                            .foregroundStyle(Theme.ink)
                            .accessibilityIdentifier("dashboard.row.\(type.rawValue).name")
                    }
                }
                // D16.3: a timestamp is an instrument reading, not prose.
                Text(lastSyncedText)
                    .font(Theme.mono(Theme.Step.caption, .regular, relativeTo: .caption2))
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

/// The right-hand column of a Data-tab row (WP-56): the 7-day average over
/// its comparison with the 30-day average. Shared by `SyncTypeRow` and
/// `LocalOnlyTypeRow`, so both row kinds present a trend the same way.
struct DataTrendColumn: View {
    let trend: DataTrendText
    /// `dashboard.row.<type>` / `dashboard.localRow.<type>`; the column adds
    /// `.trend` and `.trendComparison`.
    let identifierPrefix: String
    var alignment: HorizontalAlignment = .trailing

    var body: some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(verbatim: trend.value)
                .font(Theme.font(Theme.Step.body, .regular, relativeTo: .subheadline))
                .foregroundStyle(trend.comparison == nil ? Theme.tertiary : Theme.secondary)
                .monospacedDigit()
                .accessibilityIdentifier("\(identifierPrefix).trend")
            if let comparison = trend.comparison {
                // D16.3: a reading's qualifier is instrument text.
                Text(verbatim: comparison)
                    .font(Theme.mono(Theme.Step.caption, .regular, relativeTo: .caption2))
                    .foregroundStyle(Theme.tertiary)
                    .accessibilityIdentifier("\(identifierPrefix).trendComparison")
            }
        }
        .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
    }
}

/// A Data-tab row's first line: its title on the left, its trend on the
/// right -- or, when the two can't share a line (large Dynamic Type, long
/// names), the trend moved under the title at full width, instead of
/// wrapping word by word in a narrow column.
struct DataRowTitleLine<Title: View>: View {
    let trend: DataTrendText
    let identifierPrefix: String
    @ViewBuilder let title: Title

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                title
                Spacer(minLength: 12)
                DataTrendColumn(trend: trend, identifierPrefix: identifierPrefix)
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) {
                title
                DataTrendColumn(trend: trend, identifierPrefix: identifierPrefix, alignment: .leading)
            }
        }
    }
}

#Preview {
    ThemedPanel {
        SyncTypeRow(
            type: .steps,
            state: SyncState(dataType: "steps", lastSyncedAt: Date(), lastStatus: "ok", itemCount: 4213),
            trend: DataTrendText(value: "8,240", comparison: "7d avg · +310 vs 30d")
        )
        ThemedRowDivider()
        SyncTypeRow(type: .weight, state: nil, trend: .empty)
        ThemedRowDivider()
        SyncTypeRow(
            type: .sleep,
            state: SyncState(dataType: "sleep", lastStatus: "error", lastError: "Google 429: rate limited"),
            trend: .empty
        )
    }
    .padding(22)
    .background(Theme.canvas)
}
