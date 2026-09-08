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
import UIKit
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

@Suite("SnapshotAssert.matchesPixelwise")
struct PixelMatchTests {
    /// Renders a solid square, optionally recoloring one pixel — a
    /// deterministic stand-in for GPU shimmer (tiny delta) vs real change.
    @MainActor
    private static func png(color: UIColor, size: Int = 20, speck: (UIColor, Int, Int)? = nil) throws -> Data {
        // Explicit scale 1: the default (screen scale) would make pixel
        // counts device-dependent.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)
        let image = renderer.image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            if let (speckColor, x, y) = speck {
                speckColor.setFill()
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return try #require(image.pngData())
    }

    @Test("identical inputs match")
    func identical() throws {
        let data = try Self.png(color: .red)
        #expect(SnapshotAssert.matchesPixelwise(reference: data, candidate: data) == .match)
    }

    @Test("single-LSB shimmer passes")
    func shimmer() throws {
        // One pixel nudged barely (delta 5 < tolerance 16): Metal edge
        // noise on an otherwise identical render.
        let base = try Self.png(color: .red)
        let nudged = try Self.png(
            color: .red,
            speck: (UIColor(red: 1.0, green: 5.0 / 255.0, blue: 0, alpha: 1), 3, 3)
        )
        #expect(SnapshotAssert.matchesPixelwise(reference: base, candidate: nudged) == .match)
    }

    @Test("wholesale change fails with counts")
    func wholesale() throws {
        let red = try Self.png(color: .red)
        let blue = try Self.png(color: .blue)
        let verdict = SnapshotAssert.matchesPixelwise(reference: red, candidate: blue)
        guard case .pixelsDiffer(let count, let worst) = verdict else {
            Issue.record("expected pixelsDiffer, got \(verdict)")
            return
        }
        #expect(count == 400)
        #expect(worst > SnapshotAssert.channelTolerance)
    }

    @Test("undecodable bytes fail loudly")
    func undecodable() throws {
        let good = try Self.png(color: .red)
        #expect(SnapshotAssert.matchesPixelwise(reference: Data("nope".utf8), candidate: good)
            == .decodeFailure(side: "reference"))
    }

    @Test("size change fails as layout regression")
    func sizeChange() throws {
        let small = try Self.png(color: .red, size: 20)
        let big = try Self.png(color: .red, size: 21)
        let verdict = SnapshotAssert.matchesPixelwise(reference: small, candidate: big)
        guard case .sizeMismatch = verdict else {
            Issue.record("expected sizeMismatch, got \(verdict)")
            return
        }
    }
}
