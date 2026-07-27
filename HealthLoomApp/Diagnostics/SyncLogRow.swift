// SyncLogRow.swift
//
// WP-18 (implementation-plan.md): one row of the Sync Log viewer --
// timestamp, type, status icon, item count, and (only when present) the
// already-redacted error text. `SyncLogView` never talks to `SyncLogStore`
// directly from this view, matching `SyncTypeRow`/`BackfillTypeRow`'s own
// "dumb row, smart container" split (`Dashboard/SyncTypeRow.swift`,
// `Backfill/BackfillTypeRow.swift`).
//
// Same "identifiers only on leaves" rule those files' own progress.md notes
// established (a container-level `.accessibilityIdentifier` was observed to
// clobber its children's more specific ones) -- every sub-value below
// carries its own `synclog.row.<id>.*` identifier, a namespace distinct from
// `dashboard.row.*`/`backfill.row.*`.

import CoreModel
import SwiftUI
import SyncKit

struct SyncLogRow: View {
    let entry: SyncLogEntry

    // WP-33 follow-on (Shared/ThemedChrome.swift): Yacht club presentation --
    // rust/gray status dot instead of the green/red SF Symbol, plus the 2 pt
    // rust attention bar on errored rows. Copy and identifiers unchanged.
    var body: some View {
        ZStack(alignment: .leading) {
            if entry.status == .error { ThemedAttentionBar() }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(entry.status == .ok ? Theme.accent : Theme.gray)
                        .frame(width: 6, height: 6)
                        .accessibilityIdentifier("synclog.row.\(entry.id).statusIcon")
                    Text(displayName)
                        .font(Theme.font(14, .medium, relativeTo: .subheadline))
                        .foregroundStyle(Theme.ink)
                        .accessibilityIdentifier("synclog.row.\(entry.id).name")
                    Spacer()
                    Text(entry.timestamp, style: .relative)
                        .font(Theme.font(11, .regular, relativeTo: .caption2))
                        .foregroundStyle(Theme.tertiary)
                        .accessibilityIdentifier("synclog.row.\(entry.id).timestamp")
                }
                Text("\(entry.itemCount) item\(entry.itemCount == 1 ? "" : "s")")
                    .font(Theme.font(12, .regular, relativeTo: .caption))
                    .foregroundStyle(Theme.secondary)
                    .accessibilityIdentifier("synclog.row.\(entry.id).count")
                // WP-12b: watch-priority suppression bookkeeping (architecture
                // .md D13.3 / test-plan.md §2.3 -- "deferred to Apple Watch").
                // Only rendered when the run actually deferred something.
                // Deliberately not `Label`: see LocalOnlyTypeRow.swift's note
                // on `Label` reporting one identifier on two elements.
                if let suppressedCount = entry.suppressedCount, suppressedCount > 0 {
                    Text("\(suppressedCount) deferred to Apple Watch")
                        .font(Theme.font(11, .regular, relativeTo: .caption2))
                        .foregroundStyle(Theme.tertiary)
                        .accessibilityIdentifier("synclog.row.\(entry.id).suppressed")
                }
                if let errorMessage = entry.errorMessage {
                    ThemedErrorText(
                        message: errorMessage,
                        accessibilityIdentifier: "synclog.row.\(entry.id).error"
                    )
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
        }
    }

    private var displayName: String {
        entry.dataType.rawValue
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

}

#Preview {
    List {
        SyncLogRow(entry: SyncLogEntry(timestamp: Date().addingTimeInterval(-120), dataType: .steps, status: .ok, itemCount: 214))
        SyncLogRow(entry: SyncLogEntry(
            timestamp: Date().addingTimeInterval(-3600),
            dataType: .heartRate,
            status: .error,
            itemCount: 0,
            errorMessage: "The request timed out."
        ))
    }
}
