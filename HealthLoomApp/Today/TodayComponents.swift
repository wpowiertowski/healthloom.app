// TodayComponents.swift
//
// WP-33, reworked by WP-40 (implementation-plan.md) / architecture.md D16
// (supersedes D12): the Today panel components.
//
// Panel geometry, spacing and colour roles still come from the Yacht club
// port (`Design/HealthLoomTodayView-YachtClub.swift`). What D16 changes
// here is the hero and the type: `HeroInstrument` now drives a
// `JunghansDial` with the score seated inside it and a `SignalIndex`
// beside it, and every text site sits on `Theme.Step`'s 1.25 ladder in
// Archivo/IBM Plex Mono rather than ad-hoc Helvetica sizes. D12's two
// production deviations still bind at every text site: `Theme.font`/
// `Theme.mono` with `relativeTo:` (Dynamic Type) and dynamic light/dark
// tokens, plus VoiceOver labels on every row and instrument.
// `TodayView.swift` composes these and owns all data flow -- everything
// here is a dumb, value-driven view (the `SyncTypeRow`/`ActivityRow`
// "dumb row, smart container" convention).

import CoachKit
import SwiftUI

// MARK: - Header (brand + sync status)

struct TodayHeader: View {
    let syncStatus: TodaySyncStatus

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                Rectangle().fill(Theme.accent).frame(width: 6, height: 6)
                Text("healthloom")
                    .font(Theme.font(Theme.Step.body, .medium, relativeTo: .callout))
                    .foregroundStyle(Theme.ink)
            }
            .accessibilityHidden(true) // decorative brand mark
            Spacer()
            HStack(spacing: 7) {
                Circle()
                    .fill(syncStatus.freshness == .fresh ? Theme.accent : Theme.gray)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                // Native Text (not a combined custom element): the audit's
                // hit-region check flags small *custom* accessibility
                // elements but exempts native small static texts (the
                // TODAY label, greeting, and subs all pass at 11-14pt).
                // VoiceOver still announces one line via the label below.
                Text(syncStatus.text)
                    .font(Theme.font(Theme.Step.caption, .regular, relativeTo: .caption))
                    // Always secondary: even "Not synced yet" is a status
                    // the user must read, and tertiary is placeholders-only
                    // (L2).
                    .foregroundStyle(Theme.secondary)
                    .accessibilityLabel("Sync status: \(syncStatus.text)")
                    .accessibilityIdentifier("today.syncStatus")
            }
        }
    }
}

// MARK: - Readiness hero instrument

/// What the hero renders. `.pending` is WP-33 step 4's "readiness
/// insufficient signals" family: no HealthKit data (or zero usable
/// signals) renders the pending instrument, and sparse data renders the
/// same shape with a "based on N of 4 signals" caption.
/// `deltaVsBaseline` is nil until score history exists: a day-one user
/// with full HealthKit baselines gets 4 real signals but no prior average
/// to compare against, and the caption must say so (H1) instead of
/// asserting a "+0 vs 30-day average" that was never computed.
enum ReadinessDisplay: Equatable {
    case pending
    /// `signals` is the engine's own `contributingSignals` set, not a count:
    /// the hero names which of the four reported, so it cannot settle for
    /// "3 of 4" without knowing *which* three (WP-42).
    case scored(score: Int, deltaVsBaseline: Int?, signals: Set<ReadinessSignal>)
}

struct HeroInstrument: View {
    let readiness: ReadinessDisplay

    /// The dial keeps its width while the caption beside it does not, so
    /// at accessibility sizes the text column collapses to a few
    /// characters and "30-day average" wraps mid-word. Stack instead:
    /// the dial over full-width text, which is the arrangement Apple's
    /// own layouts fall back to. Below those sizes the side-by-side
    /// instrument is the design.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Readiness")
                .font(Theme.mono(Theme.Step.micro, .medium, relativeTo: .caption2))
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(Theme.secondary)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 14) {
                    dial
                    readout
                }
            } else {
                HStack(alignment: .center, spacing: 18) {
                    dial
                    readout
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("today.readiness")
    }

    private var dial: some View {
        JunghansDial(
            value: scaleValue,
            accessibilityLabel: "Readiness",
            accessibilityValue: accessibilityValue,
            center: { AnyView(dialCenter) }
        )
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 10) {
            SignalIndex(signals: signals)
            captionText
        }
    }

    /// The score, seated inside the dial's track. `minimumScaleFactor`
    /// rather than a scaling dial: the instrument face is a fixed object
    /// (a watch does not grow), so at the largest Dynamic Type sizes the
    /// number shrinks to fit its face instead of bursting it.
    @ViewBuilder private var dialCenter: some View {
        VStack(spacing: 1) {
            switch readiness {
            case .scored(let score, _, _):
                Text("\(score)")
                    .font(Theme.font(Theme.Step.display, .ultraLight, relativeTo: .largeTitle))
                    .foregroundStyle(Theme.ink)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
            case .pending:
                // En-dash pair, tabular width. Rendered alone: dash-only
                // text has no ascenders, so pairing it with a unit floats
                // them apart (the WP-37 audit flagged exactly this).
                Text("\u{2013}\u{2013}")
                    .font(Theme.font(Theme.Step.display, .ultraLight, relativeTo: .largeTitle))
                    .foregroundStyle(Theme.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
            }
            // The dial's own caption is the SCALE, not the name: the hero
            // already says "Readiness" directly above it, and printing it
            // twice is noise. "/100" is what the number was missing --
            // the Yacht club hero set it beside the score, and a score
            // without its scale is a number without units.
            if case .scored = readiness {
                Text("/100")
                    .font(Theme.mono(Theme.Step.micro, .regular, relativeTo: .caption2))
                    .tracking(0.8)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .padding(.horizontal, 10)
        .accessibilityHidden(true) // the dial carries the label and value
    }

    private var scaleValue: Double? {
        switch readiness {
        case .pending: return nil
        case .scored(let score, _, _): return Double(score) / 100
        }
    }

    private var signals: Set<ReadinessSignal> {
        switch readiness {
        case .pending: return []
        case .scored(_, _, let signals): return signals
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
            Text("Sync your health data to see readiness")
                .font(Theme.font(Theme.Step.caption, .regular, relativeTo: .caption))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .scored(_, let delta, let signals):
            let signalsUsed = signals.count
            // The rows above now name every signal and show which reported,
            // so repeating "based on N of 4 signals" here says nothing new.
            // This line's job is the *comparison* — and when there isn't
            // one, saying why (H1: never assert a "+0 vs average" that was
            // never computed, but do explain the silence).
            if let delta, signalsUsed >= 4 {
                // iOS 26 deprecated `Text + Text`; interpolating pre-styled
                // Text values preserves each run's own font/color.
                let deltaText = Text(delta >= 0 ? "+\(delta)" : "\(delta)")
                    .font(Theme.mono(Theme.Step.caption, .semibold, relativeTo: .caption))
                    .foregroundStyle(Theme.ink)
                let averageText = Text(" vs 30-day average")
                    .font(Theme.font(Theme.Step.caption, .regular, relativeTo: .caption))
                    .foregroundStyle(Theme.secondary)
                Text("\(deltaText)\(averageText)")
                    .fixedSize(horizontal: false, vertical: true)
            } else if delta == nil {
                Text("No 30-day average yet")
                    .font(Theme.font(Theme.Step.caption, .regular, relativeTo: .caption))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // A delta exists but the day is short a signal: comparing a
                // partial score against a full-signal average would flatter
                // or punish it for the wrong reason.
                Text("Comparison needs all four signals")
                    .font(Theme.font(Theme.Step.caption, .regular, relativeTo: .caption))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Which of the four readiness signals reported this morning — named, one
/// row each, filled when that signal contributed and hollow when it did not.
///
/// Naming them is the point. "based on 3 of 4 signals" told the user a
/// number and left them to guess the nouns; a hollow row labelled *Sleep*
/// says which reading is missing and, by implication, what to do about it.
///
/// The set comes from `ReadinessEngine.contributingSignals` — the same
/// predicate the engine scores with — so a lit row and a weighted signal can
/// never disagree. Order is `ReadinessSignal.allCases`, i.e. the engine's
/// weighting order, so the column reads the same every morning.
struct SignalIndex: View {
    let signals: Set<ReadinessSignal>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(ReadinessSignal.allCases, id: \.self) { signal in
                let isReporting = signals.contains(signal)
                HStack(spacing: 8) {
                    Text(Self.name(signal))
                        .font(Theme.mono(Theme.Step.micro, .regular, relativeTo: .caption2))
                        .foregroundStyle(isReporting ? Theme.secondary : Theme.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        // Sized for the longest label ("Resting HR") at XL,
                        // not for the shortest: a fixed column is what keeps
                        // the four bars on one axis, and 60pt clipped two of
                        // the four names to "Resting…" / "Prior lo…".
                        .frame(width: 80, alignment: .leading)
                    Rectangle()
                        .fill(isReporting ? Theme.accent : Theme.border)
                        .frame(height: 6)
                }
            }
        }
        .frame(maxWidth: 190, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signals")
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("today.readiness.signals")
    }

    /// UI copy lives here, not on the enum: `ReadinessSignal` is a CoachKit
    /// domain type and has no business carrying display strings. The switch
    /// is exhaustive with no `default`, so a fifth signal fails the build
    /// here rather than rendering an unnamed row.
    private static func name(_ signal: ReadinessSignal) -> String {
        switch signal {
        case .hrv: return "HRV"
        case .restingHR: return "Resting HR"
        case .sleep: return "Sleep"
        case .strain: return "Prior load"
        }
    }

    /// VoiceOver gets the nouns too, and the missing ones by name — the
    /// fill state is invisible to it.
    private var accessibilityValue: String {
        let reporting = ReadinessSignal.allCases.filter { signals.contains($0) }.map(Self.name)
        let missing = ReadinessSignal.allCases.filter { !signals.contains($0) }.map(Self.name)
        guard !reporting.isEmpty else { return "No signals reporting" }
        let lead = "\(reporting.count) of \(ReadinessSignal.allCases.count) reporting: "
            + reporting.joined(separator: ", ")
        guard !missing.isEmpty else { return lead }
        return lead + ". Missing: " + missing.joined(separator: ", ")
    }
}

// MARK: - Instrument panel rows

struct TodayMetricRowView: View {
    let metric: TodayMetricDisplay
    var editing = false
    var onRemove: (() -> Void)?

    var body: some View {
        ZStack(alignment: .leading) {
            if metric.isPriority {
                Rectangle().fill(Theme.accent).frame(width: 2).frame(maxHeight: .infinity)
            }
            HStack(alignment: .top) {
                if editing, let onRemove {
                    // Explicit remove affordance: deterministic for the UI
                    // test, one obvious VoiceOver action. Drag-reorder
                    // handles come from the panel's reorderable-content.
                    Button(action: onRemove) {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 16, weight: .light))
                            .foregroundStyle(Theme.accent)
                            // 44pt touch target: the glyph alone is too
                            // small to tap (and to audit cleanly).
                            .padding(14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(metric.name)")
                    .accessibilityIdentifier("today.remove.\(metric.kind.rawValue)")
                }
                // WP-37 Dynamic-Type audit: name+value share the top line
                // while the sub spans full width below. At AX sizes the
                // old side-by-side columns squeezed subs into "…"
                // (information loss); full-width subs wrap instead — rows
                // grow taller, text never clips.
                VStack(alignment: .leading, spacing: 3) {
                    // Center-aligned (not firstTextBaseline): baseline
                    // stacks truncate overlong text instead of wrapping it.
                    HStack(alignment: .center) {
                        Text(metric.name)
                            .font(Theme.font(Theme.Step.body, .medium, relativeTo: .subheadline))
                            .foregroundStyle(Theme.ink)
                            // Ideal height (all lines): HStack compression
                            // truncates instead of wrapping without it.
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        // Numbers never compress or wrap (a clipped value
                        // is data loss); the name wraps instead — readable
                        // at any size.
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(metric.value ?? "\u{2014}")
                                .font(Theme.font(Theme.Step.value, .regular, relativeTo: .title3))
                                .foregroundStyle(metric.value == nil ? Theme.tertiary : Theme.ink)
                                .monospacedDigit()
                            if let unit = metric.unit {
                                // D16.3: a unit is read off an instrument,
                                // not spoken — mono, like the sub below.
                                Text(unit)
                                    .font(Theme.mono(Theme.Step.micro, .regular, relativeTo: .caption))
                                    .foregroundStyle(Theme.tertiary)
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    // Metadata, not prose ("Latest · 10:26", "33% of
                    // 10,000 goal") — mono. Not uppercased: the content is
                    // dynamic and some subs are long enough to shout.
                    Text(metric.sub)
                        .font(Theme.mono(Theme.Step.caption, .regular, relativeTo: .caption2))
                        .foregroundStyle(Theme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
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
        // Contained children + explicit spoken label (WP-37 audit
        // finding): `.ignore` removes the native text runs the contrast
        // audit resolves backgrounds against, failing the whole row —
        // `.contain` keeps them auditable while the label still drives
        // the announcement (plan's "beats per minute" wording kept).
        .accessibilityElement(children: .contain)
        .accessibilityLabel(metric.accessibilityText)
        .accessibilityIdentifier("today.metric.\(metric.kind.rawValue)")
    }
}

struct InstrumentPanel: View {
    let metrics: [TodayMetricDisplay]
    var editing = false
    var onRemove: ((TodayMetricKind) -> Void)?
    var onMove: ((ReorderDifference<TodayMetricDisplay.ID, ReorderableSingleCollectionIdentifier>) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // WP-33 step 2's reorderable-content path: the ForEach is the
            // reorderable content; the container below gates on the Edit
            // toggle. Both callbacks are optional so previews stay dumb;
            // `TodayView` always sets them.
            ForEach(metrics) { metric in
                VStack(spacing: 0) {
                    if metric.id != metrics.first?.id {
                        Rectangle().fill(Theme.border).frame(height: 1)
                    }
                    TodayMetricRowView(metric: metric, editing: editing) {
                        onRemove?(metric.kind)
                    }
                }
            }
            .reorderable()
        }
        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(editing ? Theme.accent : Theme.border))
        .reorderContainer(for: TodayMetricDisplay.self, isEnabled: editing) { difference in
            onMove?(difference)
        }
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
    /// Opens the Coach tab (plan WP-33 step 1: tap → Coach). Nil while
    /// there is nothing to discuss — a dead chevron navigates nowhere
    /// (round-1 F2), so actionability rides with content, not layout.
    var onOpenCoach: (() -> Void)?

    var body: some View {
        Group {
            if let onOpenCoach, insightText != nil {
                panelContent
                    .onTapGesture(perform: onOpenCoach)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Opens the Coach tab")
            } else {
                panelContent
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.accentTint))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("today.coachPanel")
    }

    private var panelContent: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("COACH")
                    .font(Theme.mono(Theme.Step.micro, .semibold, relativeTo: .caption2)).tracking(0.6)
                    .foregroundStyle(Theme.accentDeep)
                Text(insightText ?? "Your daily insight will appear here once the on-device coach arrives.")
                    .font(Theme.font(Theme.Step.caption, .regular, relativeTo: .footnote))
                    // Always ink: the placeholder sits on the rust tint,
                    // where secondary fails contrast (WP-37 audit) — the
                    // quieter wording (not a quieter color) marks the
                    // placeholder state.
                    .foregroundStyle(Theme.ink)
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
    }
}
