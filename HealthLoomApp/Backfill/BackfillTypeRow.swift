// BackfillTypeRow.swift
//
// WP-15 (implementation-plan.md) step 3: "progress per type ('Mar 2026 …
// done' style)." One row per type `BackfillView` walks, driven entirely by
// a `BackfillTypeStatus` snapshot (SyncKit, `Backfill/BackfillTypes.swift`)
// -- this view never talks to `BackfillCoordinator` directly, matching
// `SyncTypeRow`/`LocalOnlyTypeRow`'s own "dumb row, smart container" split
// (`Dashboard/SyncTypeRow.swift`, `Dashboard/LocalOnlyTypeRow.swift`).
//
// Same "identifiers only on leaves" rule those two files' own progress.md
// notes established (a container-level `.accessibilityIdentifier` was
// observed, via a real `xcodebuild test` accessibility snapshot, to
// clobber its children's more specific ones) -- every sub-value below
// carries its own `backfill.row.<type>.*` identifier, a namespace distinct
// from both `dashboard.row.*` and `dashboard.localRow.*`.

import CoreModel
import SwiftUI
import SyncKit

struct BackfillTypeRow: View {
    let status: BackfillTypeStatus

    // WP-33 follow-on (Shared/ThemedChrome.swift): Yacht club presentation --
    // rust/gray status dot instead of the green/red SF Symbol, plus the 2 pt
    // rust attention bar on errored rows. Copy and identifiers unchanged.
    var body: some View {
        ZStack(alignment: .leading) {
            if status.lastError != nil { ThemedAttentionBar() }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 6, height: 6)
                        .accessibilityIdentifier("backfill.row.\(status.dataType.rawValue).statusIcon")
                    Text(displayName)
                        .font(Theme.font(14, .medium, relativeTo: .subheadline))
                        .foregroundStyle(Theme.ink)
                        .accessibilityIdentifier("backfill.row.\(status.dataType.rawValue).name")
                    Spacer()
                }
                Text(progressText)
                    .font(Theme.font(12, .regular, relativeTo: .caption))
                    .foregroundStyle(Theme.secondary)
                    .accessibilityIdentifier("backfill.row.\(status.dataType.rawValue).progress")
                if let lastError = status.lastError {
                    ThemedErrorText(
                        message: lastError,
                        accessibilityIdentifier: "backfill.row.\(status.dataType.rawValue).error"
                    )
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
        }
    }

    private var displayName: String {
        switch status.dataType {
        case .steps: return "Steps"
        case .heartRate: return "Heart Rate"
        case .weight: return "Weight"
        case .sleep: return "Sleep"
        case .distance: return "Distance"
        case .floors: return "Floors"
        case .activeEnergyBurned: return "Active Energy"
        case .dailyRestingHeartRate: return "Resting Heart Rate"
        case .exercise: return "Exercise"
        case .nutritionLog: return "Nutrition"
        // Every other syncable type falls through to here, and this list has
        // grown well past the hand-written cases above -- rendering the raw
        // `active_minutes`/`blood_glucose` identifiers next to properly
        // titled rows looked like a bug. Title-cases the identifier the same
        // way `SettingsView.displayName(_:)` and `SyncLogRow.displayName`
        // already do for the same enum.
        default:
            return status.dataType.rawValue
                .split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    /// Rust once the walk is complete, gray while it is still running or
    /// errored -- an errored row is additionally marked by the 2 pt bar and
    /// `Theme.accentDeep` error text, never by dot color alone. See
    /// ThemedChrome.swift's "Status colors".
    private var statusDotColor: Color {
        status.lastError == nil && status.isComplete ? Theme.accent : Theme.gray
    }

    /// WP-15 step 3's own illustrative style: "Mar 2026 … done" once the
    /// horizon is reached; "Reached Mar 2026" mid-walk; "Not started yet"
    /// before the very first chunk.
    private var progressText: String {
        guard let reached = status.reachedDate else { return "Not started yet" }
        let label = Self.monthYearFormatter.string(from: reached)
        return status.isComplete ? "\(label) … done" : "Reached \(label)"
    }

    private static let monthYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM yyyy")
        return formatter
    }()
}

#Preview {
    List {
        BackfillTypeRow(status: BackfillTypeStatus(
            dataType: .steps,
            reachedDate: Date().addingTimeInterval(-200 * 24 * 3600),
            horizonDate: Date().addingTimeInterval(-365 * 24 * 3600),
            isComplete: false,
            lastError: nil
        ))
        BackfillTypeRow(status: BackfillTypeStatus(
            dataType: .weight,
            reachedDate: Date().addingTimeInterval(-90 * 24 * 3600),
            horizonDate: Date().addingTimeInterval(-90 * 24 * 3600),
            isComplete: true,
            lastError: nil
        ))
        BackfillTypeRow(status: BackfillTypeStatus(
            dataType: .sleep,
            reachedDate: nil,
            horizonDate: Date().addingTimeInterval(-90 * 24 * 3600),
            isComplete: false,
            lastError: nil
        ))
        BackfillTypeRow(status: BackfillTypeStatus(
            dataType: .heartRate,
            reachedDate: Date().addingTimeInterval(-30 * 24 * 3600),
            horizonDate: Date().addingTimeInterval(-365 * 24 * 3600),
            isComplete: false,
            lastError: "Google 429: rate limited - will retry automatically"
        ))
    }
}
