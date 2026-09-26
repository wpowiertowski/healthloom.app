// ActivitiesSnapshotTests.swift
//
// WP-46 / D16.8: pins the Activities detailing from the locked mockup --
// summary line, date rules, duration fields in each family's colour, and
// badges -- across the same appearance × Dynamic Type matrix as Today
// (WP-37: layouts must not clip at AXXXL, where the badges stack).
//
// Locale, time zone and "now" are fixed, so start times, day labels and
// the day span render identically on every machine.

import CoreModel
import Foundation
import SwiftUI
import Testing
@testable import HealthLoom

@MainActor
private enum ActivitiesSnapshotSubject {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London") ?? .gmt
        return calendar
    }()

    static func at(day: Int, hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    static func entry(
        _ id: String, _ title: String, _ family: ActivityFamily, day: Int, hour: Int, minute: Int, minutes: Double,
        source: String = "Apple Watch", distance: Double? = nil, heartRate: Double? = nil,
        swim: SwimLocation? = nil, supplement: FitbitActivitySupplement? = nil
    ) -> ActivityEntry {
        let start = at(day: day, hour: hour, minute: minute)
        return ActivityEntry(
            id: id, kind: .unlinkedFitbitSession, title: title, start: start,
            end: start.addingTimeInterval(minutes * 60), sourceLabel: source, supplement: supplement,
            family: family, distanceMeters: distance, averageHeartRate: heartRate, swimLocation: swim
        )
    }

    /// A Fitbit session linked to the watch run: its fields render as the
    /// D13.2 supplement line, never as the run's own badges.
    static var runSupplement: FitbitActivitySupplement {
        let session = Data(#"{"exercise.activity_type":"run","exercise.distance":6300.0,"exercise.energy":410.0}"#.utf8)
        let start = at(day: 18, hour: 11, minute: 48)
        return FitbitActivitySupplement(sample: LocalSample(
            externalID: "fitbit-run",
            dataType: GoogleDataType.exercise.rawValue,
            payloadJSON: Data(#"{"sessionPayload":"\#(session.base64EncodedString())"}"#.utf8),
            start: start, end: start.addingTimeInterval(37 * 60),
            source: "Fitbit Air", linkedWatchWorkoutUUID: nil
        ))
    }

    /// The mockup's week, plus one entry per remaining family and a linked
    /// Fitbit supplement, so every field colour and the supplement line show.
    static var entries: [ActivityEntry] { [
        entry("swim-pool", "Swim", .water, day: 20, hour: 9, minute: 31, minutes: 20, swim: .pool),
        entry("run", "Run", .onFoot, day: 18, hour: 11, minute: 48, minutes: 37, distance: 6200, heartRate: 148,
              supplement: runSupplement),
        entry("swim-open", "Swim", .water, day: 18, hour: 7, minute: 7, minutes: 71, swim: .openWater),
        entry("strength", "Strength Training", .training, day: 15, hour: 18, minute: 2, minutes: 45),
        entry("rowing", "Rowing", .endurance, day: 12, hour: 22, minute: 46, minutes: 20, source: "Hydrow", distance: 4180),
    ] }

    static var list: some View {
        let summary = ActivitySummary(entries: entries, now: at(day: 21, hour: 10, minute: 58), calendar: calendar)
        return VStack(alignment: .leading, spacing: 0) {
            ActivitySummaryLine(summary: summary)
            ForEach(ActivityConsolidator.groupedByDay(entries, calendar: calendar), id: \.day) { group in
                ActivityDayRule(day: group.day, count: group.entries.count)
                ThemedPanel {
                    ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { ThemedRowDivider() }
                        ActivityRow(
                            entry: entry,
                            durationFraction: ActivitySummary.durationFraction(of: entry, in: entries)
                        )
                    }
                }
            }
        }
        .environment(\.locale, Locale(identifier: "en_GB"))
        .environment(\.timeZone, calendar.timeZone)
        .environment(\.calendar, calendar)
    }
}

@Suite("Activities snapshots")
struct ActivitiesSnapshotTests {
    @Test("activity list across appearance and content size")
    @MainActor
    func list() {
        let configs: [(String, ColorScheme, ContentSizeCategory)] = [
            ("light-XS", .light, .extraSmall),
            ("light-XL", .light, .extraLarge),
            ("light-AXXXL", .light, .accessibilityExtraExtraExtraLarge),
            ("dark-XS", .dark, .extraSmall),
            ("dark-XL", .dark, .extraLarge),
            ("dark-AXXXL", .dark, .accessibilityExtraExtraExtraLarge),
        ]
        for (configName, scheme, size) in configs {
            SnapshotAssert.assert(
                ActivitiesSnapshotSubject.list.padding().background(Theme.canvas),
                named: "list-\(configName)",
                colorScheme: scheme,
                sizeCategory: size
            )
        }
    }
}
