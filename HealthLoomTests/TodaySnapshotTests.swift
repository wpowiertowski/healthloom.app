// TodaySnapshotTests.swift
//
// WP-33 (implementation-plan.md) "Tests:" line's snapshot requirement
// (light/dark x Dynamic Type XS/XL) via swift-snapshot-testing.
//
// What is snapshotted: the Yacht-club panels with fixed inputs (scored +
// pending hero, the four-row instrument panel incl. priority bar, progress
// bar and an empty row, coach insight + placeholder) — NOT the full
// `TodayView`, whose greeting date line renders the live date and would
// fail the day after recording. Panel geometry, tokens, and Dynamic Type
// scaling are exactly what these snapshots pin; the full screen stays
// covered by `TodayUITests`' render assertions.

import SnapshotTesting
import SwiftUI
import Testing
@testable import HealthLoom

private enum TodaySnapshotSubject {
    static var scoredHero: some View {
        HeroInstrument(readiness: .scored(score: 82, deltaVsBaseline: 6, signalsUsed: 4))
    }

    static var pendingHero: some View {
        HeroInstrument(readiness: .pending)
    }

    static var panel: some View {
        InstrumentPanel(metrics: [
            TodayMetricDisplay(kind: .heart, sub: "Resting · steady", value: "62", unit: "bpm", progress: nil),
            TodayMetricDisplay(kind: .steps, sub: "68% of 10,000 goal", value: "8,240", unit: nil, progress: 0.68),
            TodayMetricDisplay(kind: .sleep, sub: "No data yet", value: nil, unit: nil, progress: nil),
            TodayMetricDisplay(
                kind: .bloodOxygen, sub: "Average overnight", value: "97", unit: "%", progress: nil
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
            ("pendingHero", AnyView(TodaySnapshotSubject.pendingHero)),
            ("panel", AnyView(TodaySnapshotSubject.panel)),
            ("coachInsight", AnyView(TodaySnapshotSubject.coachInsight)),
            ("coachPlaceholder", AnyView(TodaySnapshotSubject.coachPlaceholder)),
        ]
        func traits(_ style: UIUserInterfaceStyle, _ size: UIContentSizeCategory) -> UITraitCollection {
            UITraitCollection(mutations: { mutations in
                mutations.userInterfaceStyle = style
                mutations.preferredContentSizeCategory = size
            })
        }
        let configs: [(String, UITraitCollection)] = [
            ("light-XS", traits(.light, .extraSmall)),
            ("light-XL", traits(.light, .extraLarge)),
            ("dark-XS", traits(.dark, .extraSmall)),
            ("dark-XL", traits(.dark, .extraLarge)),
        ]
        for (subjectName, subject) in subjects {
            for (configName, traits) in configs {
                assertSnapshot(
                    of: subject.padding().background(Theme.canvas),
                    as: .image(precision: 0.99, layout: .fixed(width: 390, height: 300), traits: traits),
                    named: "\(subjectName)-\(configName)"
                )
            }
        }
    }
}
