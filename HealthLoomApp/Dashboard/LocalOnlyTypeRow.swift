// LocalOnlyTypeRow.swift
//
// WP-14 (implementation-plan.md): "dashboard rows show a 'Not in Apple
// Health' badge" -- since WP-56 said once, by the section heading these
// rows sit under, rather than on every row -- for the four
// `.localOnly`-writability `GoogleDataType`s
// (architecture.md D2) -- ECG, Active Zone Minutes, Active Minutes,
// Irregular Rhythm Notification -- which persist to `LocalSample` (CoreModel,
// via `SyncEngine.upsertLocalSample`, WP-09) instead of HealthKit, so they
// can't be driven by `SyncState` the way `SyncTypeRow` (WP-10) is.
//
// This is a *separate* row view rather than an extension of `SyncTypeRow`:
// its data source is an array of `LocalSample` rows for one `GoogleDataType`
// (not an optional `SyncState`), and its semantics differ enough (never in
// Apple Health, plus a clinical indicator for two of the four types) that
// folding both into one view's `state:` parameter would
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

import CoachKit
import CoreModel
import SwiftUI
import SyncKit

struct LocalOnlyTypeRow: View {
    let type: GoogleDataType
    let samples: [LocalSample]
    @Environment(\.locale) private var locale

    // WP-33 follow-on (Shared/ThemedChrome.swift): Yacht club presentation --
    // `TodayMetricRowView` geometry and a `ThemedBadge` pill in place of the
    // orange/purple SF Symbol badges. The badge string is untouched:
    // `DashboardUITests` asserts on its exact label.
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            DataRowTitleLine(trend: trend, identifierPrefix: "dashboard.localRow.\(type.rawValue)") {
                Text(displayName)
                    .font(Theme.font(Theme.Step.body, .medium, relativeTo: .subheadline))
                    .foregroundStyle(Theme.ink)
                    .accessibilityIdentifier("dashboard.localRow.\(type.rawValue).name")
            }
            // WP-56: one quiet badge, only where it adds something. The
            // section heading already says "Not in Apple Health", so the
            // per-row copy of it is gone; the clinical note is a neutral
            // hairline badge -- the filled accent version outweighed the
            // row it annotated. One `Text` per identifier inside
            // `ThemedBadge` (never `Label`, whose icon and text report one
            // identifier twice).
            if isClinicalType(type) {
                ThemedBadge(
                    text: "Clinical · excluded from AI",
                    accessibilityIdentifier: "dashboard.localRow.\(type.rawValue).clinicalBadge"
                )
            }
            // D16.3: a timestamp is an instrument reading, not prose.
            Text(lastSampleText)
                .font(Theme.mono(Theme.Step.caption, .regular, relativeTo: .caption2))
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

    /// WP-56: minutes per day (7-day average vs 30-day) or a 30-day event
    /// count -- not `samples.count`, the number of stored records.
    private var trend: DataTrendText {
        DataTrendText.local(
            type: type,
            samples: samples,
            now: Date(),
            calendar: .current,
            locale: locale,
            unitSystem: ContextAssembler.defaultUnitSystem(for: locale)
        )
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
