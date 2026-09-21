// JunghansDial.swift
//
// WP-40 (implementation-plan.md) / architecture.md D16: the readiness
// instrument, ported from `Design/healthloom-bill-glass.html`.
//
// Replaces WP-33's linear `TickScale`. Both are Ulm-school tick
// instruments; this one is the shape Max Bill actually drew -- the minute
// track from his 1961 Junghans watch face: sixty ticks around a circle,
// every fifth one long (the hour index), and a single mark for position.
// The cursor is his signature rotated square.
//
// The linear scale's two production requirements carry over verbatim:
//   - **VoiceOver** (test-plan.md §6: "readiness announces 'Readiness 82
//     of 100'"): the whole dial is one accessibility element whose
//     label/value the *caller* supplies -- the dial is a generic 0...1
//     instrument and shouldn't hardcode "Readiness".
//   - **Value clamping**: renders sensibly at exactly 0, 0.5 and 1.0
//     (test-plan.md §4's explicit render points) and clamps out-of-range
//     input rather than crashing the index math.
//
// Drawn in a `Canvas` rather than sixty rotated `Rectangle`s: one draw
// pass instead of sixty view identities, and the tick geometry reads as
// the arithmetic it is.

import SwiftUI

struct JunghansDial: View {
    /// 0...1 (clamped). `nil` renders the empty/pending instrument -- all
    /// ticks palette-gray, no cursor (the insufficient-signals state).
    var value: Double?
    var count: Int = 60
    /// VoiceOver label for the whole instrument, e.g. "Readiness".
    var accessibilityLabel: String
    /// VoiceOver value, e.g. "82 of 100" -- supplied by the caller so it
    /// can match the on-screen number exactly.
    var accessibilityValue: String
    /// Content drawn inside the track (the score).
    @ViewBuilder var center: () -> AnyView

    /// The dial is an instrument face, so it does not scale one-for-one
    /// with Dynamic Type -- but it must grow enough that the score inside
    /// it stays legible. Scaled, then capped: past `maxDiameter` the score
    /// shrinks to fit instead (see `HeroInstrument`), which keeps the
    /// hero's height bounded at AXXXL.
    @ScaledMetric(relativeTo: .largeTitle) private var scaledDiameter: CGFloat = 148
    private let maxDiameter: CGFloat = 212

    private var diameter: CGFloat { min(scaledDiameter, maxDiameter) }

    var body: some View {
        ZStack {
            Canvas { context, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let outer = size.width / 2
                let cursor = cursorIndex

                for i in 0..<count {
                    let isIndex = i % 5 == 0
                    let inner = outer - (isIndex ? outer * 0.155 : outer * 0.093)
                    let angle = (Double(i) / Double(count)) * 2 * .pi - .pi / 2
                    var path = Path()
                    path.move(to: CGPoint(
                        x: c.x + cos(angle) * inner, y: c.y + sin(angle) * inner
                    ))
                    path.addLine(to: CGPoint(
                        x: c.x + cos(angle) * outer, y: c.y + sin(angle) * outer
                    ))
                    context.stroke(
                        path,
                        with: .color(tickColor(index: i, cursor: cursor)),
                        lineWidth: isIndex ? 2 : 1.2
                    )
                }

                // The dial's edge -- structure, not ornament.
                let ringInset = outer * 0.24
                context.stroke(
                    Path(ellipseIn: CGRect(
                        x: ringInset, y: ringInset,
                        width: size.width - ringInset * 2,
                        height: size.height - ringInset * 2
                    )),
                    with: .color(Theme.border),
                    lineWidth: 1
                )

                // Cursor: Bill's rotated square, seated on the track.
                if let cursor {
                    let angle = (Double(cursor) / Double(count)) * 2 * .pi - .pi / 2
                    let r = outer - outer * 0.062
                    let side = outer * 0.072
                    let p = CGPoint(x: c.x + cos(angle) * r, y: c.y + sin(angle) * r)
                    context.drawLayer { layer in
                        layer.translateBy(x: p.x, y: p.y)
                        layer.rotate(by: .degrees(45))
                        layer.fill(
                            Path(CGRect(x: -side, y: -side, width: side * 2, height: side * 2)),
                            with: .color(Theme.ink)
                        )
                    }
                }
            }
            center()
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }

    /// Clamped so an out-of-range value renders the end of the track
    /// rather than indexing past it.
    private var cursorIndex: Int? {
        value.map { unclamped in
            let clamped = min(max(unclamped, 0), 1)
            return Int((Double(count - 1) * clamped).rounded())
        }
    }

    private func tickColor(index: Int, cursor: Int?) -> Color {
        guard let cursor else { return Theme.gray }
        if index == cursor { return Theme.ink }
        return index < cursor ? Theme.accent : Theme.gray
    }
}

extension JunghansDial {
    /// Convenience for the bare instrument (previews, pending states).
    init(
        value: Double?,
        count: Int = 60,
        accessibilityLabel: String,
        accessibilityValue: String
    ) {
        self.init(
            value: value,
            count: count,
            accessibilityLabel: accessibilityLabel,
            accessibilityValue: accessibilityValue,
            center: { AnyView(EmptyView()) }
        )
    }
}

#Preview {
    VStack(spacing: 20) {
        HStack(spacing: 20) {
            JunghansDial(value: 0, accessibilityLabel: "Readiness", accessibilityValue: "0 of 100")
            JunghansDial(value: 0.5, accessibilityLabel: "Readiness", accessibilityValue: "50 of 100")
        }
        HStack(spacing: 20) {
            JunghansDial(value: 0.82, accessibilityLabel: "Readiness", accessibilityValue: "82 of 100")
            JunghansDial(value: nil, accessibilityLabel: "Readiness", accessibilityValue: "not yet available")
        }
    }
    .padding()
    .background(Theme.canvas)
}
