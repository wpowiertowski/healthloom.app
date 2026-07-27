// LocalOnlyTypeRow.swift
//
// WP-14 (implementation-plan.md): "dashboard rows show a 'Not in Apple
// Health' badge" for the four `.localOnly`-writability `GoogleDataType`s
// (architecture.md D2) -- ECG, Active Zone Minutes, Active Minutes,
// Irregular Rhythm Notification -- which persist to `LocalSample` (CoreModel,
// via `SyncEngine.upsertLocalSample`, WP-09) instead of HealthKit, so they
// can't be driven by `SyncState` the way `SyncTypeRow` (WP-10) is.
//
// This is a *separate* row view rather than an extension of `SyncTypeRow`:
// its data source is an array of `LocalSample` rows for one `GoogleDataType`
// (not an optional `SyncState`), and its badge semantics differ enough
// (always "Not in Apple Health," plus a clinical indicator for two of the
// four types) that folding both into one view's `state:` parameter would
// muddy `SyncTypeRow`'s existing contract for its four P0, SyncState-backed
// rows. `DashboardView` renders both row types in separate `List` sections.
//
// Clinical marking (architecture.md D8, this WP's third deliverable): ECG and
// Irregular Rhythm Notification additionally render a "Clinical" indicator,
// derived via SyncKit's `isClinicalType(_:)` (Routing/ClinicalClassification
// .swift) -- never a second hand-written ECG/IRN list here, so this row's
// clinical-vs-not distinction and any future WP-20 `ContextAssembler`
// exclusion logic can never drift apart. This WP does not build
// `ContextAssembler`/AI-context enforcement itself (that's WP-20's job, per
// this WP's brief) -- it only makes the distinction derivable and visible.
//
// Same "identifiers only on leaves" rule WP-10's own progress.md note
// established (a container-level `.accessibilityIdentifier` was observed, via
// a real `xcodebuild test` accessibility snapshot, to clobber its children's
// more specific ones): every sub-value below carries its own
// `dashboard.localRow.<type>.*` identifier -- a distinct namespace from
// `SyncTypeRow`'s `dashboard.row.<type>.*` so the two row kinds' identifiers
// never collide even for a future type that somehow appeared in both lists.
// No identifier is applied to the enclosing `VStack`.

import CoreModel
import SwiftUI
import SyncKit

struct LocalOnlyTypeRow: View {
    let type: GoogleDataType
    let samples: [LocalSample]

    // WP-33 follow-on (Shared/ThemedChrome.swift): Yacht club presentation --
    // `TodayMetricRowView` geometry and `ThemedBadge` pills in place of the
    // orange/purple SF Symbol badges. Badge *strings* are untouched:
    // `DashboardUITests` asserts on their exact labels.
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(displayName)
                    .font(Theme.font(14, .medium, relativeTo: .subheadline))
                    .foregroundStyle(Theme.ink)
                    .accessibilityIdentifier("dashboard.localRow.\(type.rawValue).name")
                Spacer()
                Text(itemCountText)
                    .font(Theme.font(15, .regular, relativeTo: .subheadline))
                    .foregroundStyle(Theme.secondary)
                    .monospacedDigit()
                    .accessibilityIdentifier("dashboard.localRow.\(type.rawValue).itemCount")
            }
            HStack(spacing: 6) {
                // Deliberately `Image` + `Text` (not SwiftUI's `Label`, whose
                // icon and text render as two *separate* accessibility
                // elements): a real `xcodebuild test` run against the
                // simulator showed a single `.accessibilityIdentifier`
                // applied to a `Label` gets reported on *both* underlying
                // elements (the image and the text), so an identifier query
                // resolves to two matches instead of one -- the same
                // "container identifier cascades to children" family of
                // pitfall WP-10's progress.md note already documented for
                // plain `VStack`s, just discovered here for `Label`
                // specifically. `Image` is marked `.accessibilityHidden` so
                // only the `Text` -- carrying the one identifier -- is
                // queryable, and its `.label` is exactly the badge's display
                // string.
                // Each badge is now a single `Text` inside `ThemedBadge`,
                // which resolves the `Label`/icon+text hazard this row
                // previously worked around by hand: with no decorative
                // `Image` in the badge at all, there is exactly one
                // accessibility element per identifier by construction, so
                // an identifier query can no longer resolve to two matches.
                // (The original note is kept below for the general rule.)
                //
                // Deliberately not SwiftUI's `Label`, whose icon and text
                // render as two *separate* accessibility elements: a real
                // `xcodebuild test` run against the simulator showed a
                // single `.accessibilityIdentifier` applied to a `Label`
                // gets reported on *both* underlying elements, so an
                // identifier query resolves to two matches instead of one --
                // the same "container identifier cascades to children"
                // family of pitfall WP-10's progress.md note documented for
                // plain `VStack`s.
                ThemedBadge(
                    text: "Not in Apple Health",
                    accessibilityIdentifier: "dashboard.localRow.\(type.rawValue).badge"
                )
                if isClinicalType(type) {
                    ThemedBadge(
                        text: "Clinical · excluded from AI",
                        style: .accent,
                        accessibilityIdentifier: "dashboard.localRow.\(type.rawValue).clinicalBadge"
                    )
                }
            }
            Text(lastSampleText)
                .font(Theme.font(11, .regular, relativeTo: .caption2))
                .foregroundStyle(Theme.tertiary)
                .accessibilityIdentifier("dashboard.localRow.\(type.rawValue).lastSample")
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    private var displayName: String {
        switch type {
        case .electrocardiogram: return "ECG"
        case .activeZoneMinutes: return "Active Zone Minutes"
        case .activeMinutes: return "Active Minutes"
        case .irregularRhythmNotification: return "Irregular Rhythm Notifications"
        default: return type.rawValue
        }
    }

    private var itemCountText: String {
        String(samples.count)
    }

    private var lastSampleText: String {
        guard let last = samples.map(\.end).max() else { return "No data yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Last sample \(formatter.localizedString(for: last, relativeTo: Date()))"
    }
}

#Preview {
    List {
        LocalOnlyTypeRow(
            type: .electrocardiogram,
            samples: [
                LocalSample(
                    externalID: "preview-ecg-1",
                    dataType: GoogleDataType.electrocardiogram.rawValue,
                    payloadJSON: Data(),
                    start: Date().addingTimeInterval(-3600),
                    end: Date().addingTimeInterval(-3590),
                    source: "Apple Watch"
                ),
            ]
        )
        LocalOnlyTypeRow(type: .activeZoneMinutes, samples: [])
    }
}
