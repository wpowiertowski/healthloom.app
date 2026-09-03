// TodayComponents.swift
//
// WP-33 (implementation-plan.md) / architecture.md D12: the Yacht club
// panel components, ported from `Design/HealthLoomTodayView-YachtClub.swift`
// (geometry, spacing, and color roles kept verbatim) with the D12-mandated
// production deviations applied at every text site: `Theme.font(_:_:
// relativeTo:)` (Dynamic Type) instead of fixed `helv(size)`, dynamic
// light/dark tokens, and VoiceOver labels on every row and instrument.
// `TodayView.swift` composes these and owns all data flow -- everything
// here is a dumb, value-driven view (the `SyncTypeRow`/`ActivityRow`
// "dumb row, smart container" convention).

import SwiftUI

// MARK: - Header (brand + sync status)

struct TodayHeader: View {
    let syncStatus: TodaySyncStatus

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                Rectangle().fill(Theme.accent).frame(width: 6, height: 6)
                Text("healthloom")
                    .font(Theme.font(16, .medium, relativeTo: .callout))
                    .foregroundStyle(Theme.ink)
            }
            .accessibilityHidden(true) // decorative brand mark
            Spacer()
            HStack(spacing: 7) {
                Circle()
                    .fill(syncStatus.freshness == .fresh ? Theme.accent : Theme.gray)
                    .frame(width: 6, height: 6)
                Text(syncStatus.text)
                    .font(Theme.font(11.5, .regular, relativeTo: .caption))
                    .foregroundStyle(syncStatus.freshness == .never ? Theme.tertiary : Theme.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sync status: \(syncStatus.text)")
            .accessibilityIdentifier("today.syncStatus")
        }
    }
}

// MARK: - Readiness hero instrument

/// What the hero renders. `.pending` is WP-33 step 4's "readiness
/// insufficient signals" family: until WP-33 binds it there is no score at
/// all (WP-23's `ReadinessEngine` has landed in CoachKit), and sparse data
/// renders the same shape with a "based on N of 4 signals" caption --
/// `.scored(score:delta:signalsUsed:)` is already plumbed for it so WP-33
/// binds without reshaping this view.
enum ReadinessDisplay: Equatable {
    case pending
    case scored(score: Int, deltaVsBaseline: Int, signalsUsed: Int)
}

struct HeroInstrument: View {
    let readiness: ReadinessDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Readiness")
                .font(Theme.font(11, .medium, relativeTo: .caption2)).tracking(0.4)
                .foregroundStyle(Theme.secondary)
            HStack(alignment: .bottom, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(scoreText)
                        .font(Theme.font(60, .light, relativeTo: .largeTitle))
                        .foregroundStyle(readinessAvailable ? Theme.ink : Theme.tertiary)
                        .monospacedDigit()
                    Text("/100")
                        .font(Theme.font(18, .regular, relativeTo: .title3))
                        .foregroundStyle(Theme.tertiary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    TickScale(
                        value: scaleValue,
                        accessibilityLabel: "Readiness",
                        accessibilityValue: accessibilityValue
                    )
                    captionText
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("today.readiness")
    }

    private var readinessAvailable: Bool {
        if case .scored = readiness { return true }
        return false
    }

    private var scoreText: String {
        switch readiness {
        case .pending: return "\u{2013}\u{2013}" // en-dash pair, tabular width
        case .scored(let score, _, _): return "\(score)"
        }
    }

    private var scaleValue: Double? {
        switch readiness {
        case .pending: return nil
        case .scored(let score, _, _): return Double(score) / 100
        }
    }

    private var accessibilityValue: String {
        switch readiness {
        case .pending: return "not yet available"
        case .scored(let score, _, _): return "\(score) of 100"
        }
    }

    @ViewBuilder private var captionText: some View {
        switch readiness {
        case .pending:
            Text("Arrives with the coach \u{2014} keep syncing")
                .font(Theme.font(12, .regular, relativeTo: .caption))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.trailing)
        case .scored(_, let delta, let signalsUsed):
            if signalsUsed < 4 {
                // WP-33 step 4's "readiness insufficient signals" caption.
                Text("based on \(signalsUsed) of 4 signals")
                    .font(Theme.font(12, .regular, relativeTo: .caption))
                    .foregroundStyle(Theme.secondary)
            } else {
                // iOS 26 deprecated `Text + Text`; interpolating pre-styled
                // Text values preserves each run's own font/color.
                let deltaText = Text(delta >= 0 ? "+\(delta)" : "\(delta)")
                    .font(Theme.font(12, .semibold, relativeTo: .caption))
                    .foregroundStyle(Theme.ink)
                let averageText = Text(" vs 30-day average")
                    .font(Theme.font(12, .regular, relativeTo: .caption))
                    .foregroundStyle(Theme.secondary)
                Text("\(deltaText)\(averageText)")
            }
        }
    }
}

// MARK: - Instrument panel rows

struct TodayMetricRowView: View {
    let metric: TodayMetricDisplay

    var body: some View {
        ZStack(alignment: .leading) {
            if metric.isPriority {
                Rectangle().fill(Theme.accent).frame(width: 2).frame(maxHeight: .infinity)
            }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(metric.name)
                        .font(Theme.font(14, .medium, relativeTo: .subheadline))
                        .foregroundStyle(Theme.ink)
                    Text(metric.sub)
                        .font(Theme.font(11, .regular, relativeTo: .caption2))
                        .foregroundStyle(Theme.tertiary)
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(metric.value ?? "\u{2014}")
                        .font(Theme.font(21, .regular, relativeTo: .title3))
                        .foregroundStyle(metric.value == nil ? Theme.tertiary : Theme.ink)
                        .monospacedDigit()
                    if let unit = metric.unit {
                        Text(unit)
                            .font(Theme.font(12, .regular, relativeTo: .caption))
                            .foregroundStyle(Theme.tertiary)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
        .overlay(alignment: .bottom) {
            if let progress = metric.progress {
                GeometryReader { geometry in
                    Rectangle().fill(Theme.accent)
                        .frame(width: geometry.size.width * progress, height: 2)
                }
                .frame(height: 2)
                .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.accessibilityText)
        .accessibilityIdentifier("today.metric.\(metric.kind.rawValue)")
    }
}

struct InstrumentPanel: View {
    let metrics: [TodayMetricDisplay]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                TodayMetricRowView(metric: metric)
            }
        }
        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
    }
}

// MARK: - Coach panel

/// The rust-tint coach panel. Until WP-25/34 surface a real `DailyInsight`
/// (WP-23's struct + generator exist in CoachKit) this renders the
/// placeholder state -- same panel, quieter copy, no
/// action chevron -- so the layout is final and P2 only swaps the text
/// binding in.
struct CoachPanel: View {
    /// `nil` = no insight yet (placeholder state).
    let insightText: String?

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("COACH")
                    .font(Theme.font(11, .semibold, relativeTo: .caption2)).tracking(0.6)
                    .foregroundStyle(Theme.accentDeep)
                Text(insightText ?? "Your daily insight will appear here once the on-device coach arrives.")
                    .font(Theme.font(13.5, .regular, relativeTo: .footnote))
                    .foregroundStyle(insightText == nil ? Theme.secondary : Theme.ink)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if insightText != nil {
                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.accentDeep)
                    .accessibilityHidden(true)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.accentTint))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("today.coachPanel")
    }
}
