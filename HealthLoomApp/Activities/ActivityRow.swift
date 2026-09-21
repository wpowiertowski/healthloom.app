// ActivityRow.swift
//
// WP-12b (implementation-plan.md) step 5: one consolidated activity entry
// (ActivitiesModels.swift's `ActivityEntry`). Follows `SyncTypeRow`/
// `SyncLogRow`'s "dumb row, smart container" split and the "identifiers
// only on leaves" accessibility-ID rule those files established.

import SwiftUI

struct ActivityRow: View {
    let entry: ActivityEntry

    // WP-40 / D16: the per-activity symbol is gone. It was already
    // `accessibilityHidden` because the title carries the meaning, which is
    // the whole argument against it -- a mark that adds nothing to a row
    // that already names itself costs scan time and earns none back. No UI
    // test referenced `activities.row.<id>.icon`; `.title` and `.detail`
    // (which they do assert on) are untouched.
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(entry.title)
                    .font(Theme.font(Theme.Step.body, .medium, relativeTo: .subheadline))
                    .foregroundStyle(Theme.ink)
                    .accessibilityIdentifier("activities.row.\(entry.id).title")
                Spacer()
                // Timestamp, duration and source are instrument
                // readings (D16.3) — mono, and tabular by construction so
                // times line up down the column.
                Text(entry.start, style: .time)
                    .font(Theme.mono(Theme.Step.caption, .regular, relativeTo: .caption2))
                    .foregroundStyle(Theme.tertiary)
            }
            Text("\(durationText) \u{00B7} \(entry.sourceLabel)")
                .font(Theme.mono(Theme.Step.caption, .regular, relativeTo: .caption))
                .foregroundStyle(Theme.secondary)
                .accessibilityIdentifier("activities.row.\(entry.id).detail")
            // D13.2: the linked Fitbit session's fields, inline as a
            // supplement under the watch workout -- never a second entry.
            if let supplement = entry.supplement {
                Text("+ \(supplementText(supplement))")
                    .font(Theme.mono(Theme.Step.caption, .regular, relativeTo: .caption2))
                    .foregroundStyle(Theme.tertiary)
                    .accessibilityIdentifier("activities.row.\(entry.id).supplement")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    private var durationText: String {
        let minutes = max(1, Int(entry.duration / 60))
        return "\(minutes) min"
    }

    private func supplementText(_ supplement: FitbitActivitySupplement) -> String {
        var parts: [String] = []
        if let distance = supplement.distanceMeters {
            parts.append(String(format: "%.1f km", distance / 1000))
        }
        if let energy = supplement.energyKilocalories {
            parts.append("\(Int(energy)) kcal")
        }
        parts.append(supplement.source)
        return parts.joined(separator: " \u{00B7} ")
    }
}
