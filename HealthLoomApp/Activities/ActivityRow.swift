// ActivityRow.swift
//
// WP-12b (implementation-plan.md) step 5: one consolidated activity entry
// (ActivitiesModels.swift's `ActivityEntry`). Follows `SyncTypeRow`/
// `SyncLogRow`'s "dumb row, smart container" split and the "identifiers
// only on leaves" accessibility-ID rule those files established.

import SwiftUI

struct ActivityRow: View {
    let entry: ActivityEntry

    // WP-33 follow-on (Shared/ThemedChrome.swift): Yacht club presentation,
    // matching `TodayMetricRowView`'s geometry. Copy, structure and every
    // accessibility identifier are unchanged; the icon moves from the system
    // tint to the palette's single accent.
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(Theme.accent)
                    // Decorative: the title carries the meaning (same
                    // treatment as the tab-bar icons).
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("activities.row.\(entry.id).icon")
                Text(entry.title)
                    .font(Theme.font(14, .medium, relativeTo: .subheadline))
                    .foregroundStyle(Theme.ink)
                    .accessibilityIdentifier("activities.row.\(entry.id).title")
                Spacer()
                Text(entry.start, style: .time)
                    .font(Theme.font(11, .regular, relativeTo: .caption2))
                    .foregroundStyle(Theme.tertiary)
            }
            Text("\(durationText) \u{00B7} \(entry.sourceLabel)")
                .font(Theme.font(12, .regular, relativeTo: .caption))
                .foregroundStyle(Theme.secondary)
                .accessibilityIdentifier("activities.row.\(entry.id).detail")
            // D13.2: the linked Fitbit session's fields, inline as a
            // supplement under the watch workout -- never a second entry.
            if let supplement = entry.supplement {
                Text("+ \(supplementText(supplement))")
                    .font(Theme.font(11, .regular, relativeTo: .caption2))
                    .foregroundStyle(Theme.tertiary)
                    .accessibilityIdentifier("activities.row.\(entry.id).supplement")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    private var iconName: String {
        switch entry.kind {
        case .workout(let workout):
            return workout.isAppleWatch ? "applewatch" : "figure.run"
        case .unlinkedFitbitSession:
            return "figure.run"
        }
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
