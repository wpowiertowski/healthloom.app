// ActivityRow.swift
//
// WP-12b (implementation-plan.md) step 5: one consolidated activity entry
// (ActivitiesModels.swift's `ActivityEntry`). Follows `SyncTypeRow`/
// `SyncLogRow`'s "dumb row, smart container" split and the "identifiers
// only on leaves" accessibility-ID rule those files established.
//
// WP-46 / D16.8: laid out as the locked mockup's activity row -- title
// over a mono source caption with the start time on the right rail, then
// the duration as a flat concrete field (its length relative to the
// longest listed session, its colour the activity's family), then badges
// for what the workout actually recorded.

import SwiftUI

struct ActivityRow: View {
    let entry: ActivityEntry
    /// This entry's duration as a fraction of the longest listed one
    /// (`ActivitySummary.durationFraction`), computed by the container that
    /// can see every entry.
    let durationFraction: Double

    // WP-40 / D16: the per-activity symbol is gone. It was already
    // `accessibilityHidden` because the title carries the meaning, which is
    // the whole argument against it -- a mark that adds nothing to a row
    // that already names itself costs scan time and earns none back. No UI
    // test referenced `activities.row.<id>.icon`; `.title` and `.detail`
    // (which they do assert on) are untouched.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title and start time share a line until the title would have
            // to break mid-word (AXXXL "Strengt / h Training"); then the
            // time drops beneath it.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    titleBlock
                    Spacer(minLength: 8)
                    startTime
                }
                VStack(alignment: .leading, spacing: 4) {
                    titleBlock
                    startTime
                }
            }

            DurationField(fraction: durationFraction, field: Self.field(entry.family))
                .padding(.top, 11)

            // One reading row; stacks at large text sizes instead of
            // clipping (the badges must never truncate a number).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { badgeViews }
                VStack(alignment: .leading, spacing: 6) { badgeViews }
            }
            .padding(.top, 10)
            // Duration, readings and source as one spoken detail -- the
            // element `ActivitiesUITests` asserts on ("40 min", source).
            .accessibilityElement(children: .ignore)
            .accessibilityLabel((entry.badges + [entry.sourceLabel]).joined(separator: ", "))
            .accessibilityIdentifier("activities.row.\(entry.id).detail")

            // D13.2: the linked Fitbit session's fields, inline as a
            // supplement under the watch workout -- never a second entry.
            if let supplement = entry.supplement {
                SilkscreenText("+ \(supplementText(supplement))")
                    .font(Theme.mono(Theme.Step.micro, .regular, relativeTo: .caption2))
                    .tracking(0.5)
                    .foregroundStyle(Theme.tertiary)
                    .padding(.top, 8)
                    .accessibilityLabel("Plus \(supplementText(supplement))")
                    .accessibilityIdentifier("activities.row.\(entry.id).supplement")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.title)
                .font(Theme.font(Theme.Step.body, .medium, relativeTo: .subheadline))
                .foregroundStyle(Theme.ink)
                .accessibilityIdentifier("activities.row.\(entry.id).title")
            // Spoken as part of `.detail` below, not twice.
            SilkscreenText(entry.sourceLabel)
                .font(Theme.mono(Theme.Step.micro, .regular, relativeTo: .caption2))
                .tracking(0.5)
                .foregroundStyle(Theme.tertiary)
                .accessibilityHidden(true)
        }
    }

    /// An instrument reading (D16.3) -- mono, and tabular by construction so
    /// times line up down the column.
    private var startTime: some View {
        Text(entry.start, style: .time)
            .font(Theme.mono(Theme.Step.caption, .regular, relativeTo: .caption2))
            .foregroundStyle(Theme.secondary)
    }

    @ViewBuilder
    private var badgeViews: some View {
        ForEach(Array(entry.badges.enumerated()), id: \.offset) { _, badge in
            ThemedBadge(text: badge)
        }
    }

    /// D16.8: each activity family's concrete field. The title names the
    /// activity; the colour only tells kinds apart down the list.
    /// Exhaustive, no `default`.
    static func field(_ family: ActivityFamily) -> Theme.Field {
        switch family {
        case .onFoot: return .rust
        case .water: return .slate
        case .endurance: return .ochre
        case .training: return .sky
        }
    }

    private func supplementText(_ supplement: FitbitActivitySupplement) -> String {
        var parts: [String] = []
        if let distance = supplement.distanceMeters {
            parts.append(ActivityFormat.distance(distance))
        }
        if let energy = supplement.energyKilocalories {
            parts.append("\(Int(energy)) kcal")
        }
        parts.append(supplement.source)
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// The mockup's `.durbar`: a flat field on a `border` track, no radius, no
/// gradient. Decorative for VoiceOver -- the duration badge says the number.
private struct DurationField: View {
    let fraction: Double
    let field: Theme.Field

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.border)
                // Never narrower than 2 pt: a real session always shows.
                Rectangle().fill(field.color)
                    .frame(width: max(2, proxy.size.width * fraction))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
