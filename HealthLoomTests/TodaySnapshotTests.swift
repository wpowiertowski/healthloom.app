// TodaySnapshotTests.swift
//
// WP-33 (implementation-plan.md) "Tests:" line's snapshot requirement
// (light/dark x Dynamic Type XS/XL) via the local `SnapshotAssert` helper
// (byte-compared `ImageRenderer` PNGs — no remote snapshot dependency, per
// the strict warnings-as-errors directive).
//
// What is snapshotted: the Yacht-club panels with fixed inputs (scored +
// first-score + pending heroes, the four-row instrument panel incl.
// priority bar, progress bar and an empty row, coach insight +
// placeholder) — NOT the full `TodayView`, whose greeting date line
// renders the live date and would fail the day after recording. Panel
// geometry, tokens, and Dynamic Type scaling are exactly what these
// snapshots pin; the full screen stays covered by `TodayUITests`' render
// assertions.

import SwiftUI
import Testing
@testable import HealthLoom

private enum TodaySnapshotSubject {
    static var scoredHero: some View {
        HeroInstrument(readiness: .scored(score: 82, deltaVsBaseline: 6, signalsUsed: 4))
    }

    static var firstScoreHero: some View {
        HeroInstrument(readiness: .scored(score: 78, deltaVsBaseline: nil, signalsUsed: 4))
    }

    static var pendingHero: some View {
        HeroInstrument(readiness: .pending)
    }

    static var panel: some View {
        InstrumentPanel(metrics: [
            TodayMetricDisplay(kind: .heart, sub: "Resting · steady", value: "62", unit: "bpm", progress: nil, unitSystem: .imperial),
            TodayMetricDisplay(kind: .steps, sub: "68% of 10,000 goal", value: "8,240", unit: nil, progress: 0.68, unitSystem: .imperial),
            TodayMetricDisplay(kind: .sleep, sub: "No data yet", value: nil, unit: nil, progress: nil, unitSystem: .imperial),
            TodayMetricDisplay(
                kind: .bloodOxygen, sub: "Average overnight", value: "97", unit: "%", progress: nil, unitSystem: .imperial
            ),
        ])
    }

    static var coachInsight: some View {
        CoachPanel(insightText: "Resting heart rate is down 4 bpm this week.")
    }

    static var coachPlaceholder: some View {
        CoachPanel(insightText: nil)
    }
}

@Suite("Today snapshots")
struct TodaySnapshotTests {
    @Test("panels across appearance and content size")
    func panels() {
        let subjects: [(String, AnyView)] = [
            ("scoredHero", AnyView(TodaySnapshotSubject.scoredHero)),
            ("firstScoreHero", AnyView(TodaySnapshotSubject.firstScoreHero)),
            ("pendingHero", AnyView(TodaySnapshotSubject.pendingHero)),
            ("panel", AnyView(TodaySnapshotSubject.panel)),
            ("coachInsight", AnyView(TodaySnapshotSubject.coachInsight)),
            ("coachPlaceholder", AnyView(TodaySnapshotSubject.coachPlaceholder)),
        ]
        // WP-37: largest-size configs (Dynamic Type audit at the top of
        // the scale — layouts must not clip or overlap there).
        let configs: [(String, ColorScheme, ContentSizeCategory)] = [
            ("light-XS", .light, .extraSmall),
            ("light-XL", .light, .extraLarge),
            ("light-AXXXL", .light, .accessibilityExtraExtraExtraLarge),
            ("dark-XS", .dark, .extraSmall),
            ("dark-XL", .dark, .extraLarge),
            ("dark-AXXXL", .dark, .accessibilityExtraExtraExtraLarge),
        ]
        for (subjectName, subject) in subjects {
            for (configName, scheme, size) in configs {
                SnapshotAssert.assert(
                    subject.padding().background(Theme.canvas),
                    named: "\(subjectName)-\(configName)",
                    colorScheme: scheme,
                    sizeCategory: size
                )
            }
        }
    }
}
