// ActivityDetailView.swift
//
// WP-73: one activity in full, pushed from its Activities row -- when and
// where it was recorded, its summary figures, the route on a map when
// Apple Health has one, and a time plot of every measurement recorded
// during it, one line per device (ActivitySeries.swift). The data comes
// from `ActivityDetailProvider`; `ActivityDetailContent` is the pure
// rendering the snapshot tests pin.

import Charts
import MapKit
import SwiftUI
import SyncKit

struct ActivityDetailView: View {
    let entry: ActivityEntry

    @Environment(AppEnvironment.self) private var appEnvironment
    @State private var detail: ActivityDetail?

    var body: some View {
        ThemedScreen(title: entry.title, chrome: .pushed) {
            ActivityDetailContent(entry: entry, detail: detail)
        }
        .task {
            let provider = ActivityDetailProvider(
                healthKitAuth: appEnvironment.healthKitAuth,
                modelContainer: appEnvironment.modelContainer,
                requestsAuthorization: !appEnvironment.launchConfiguration.isUITest
            )
            detail = await provider.detail(for: entry, includingRoute: true)
        }
    }
}

/// Everything below the title. `detail == nil` while it loads.
struct ActivityDetailContent: View {
    let entry: ActivityEntry
    let detail: ActivityDetail?

    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @Environment(\.unitPreferences) private var units

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            kicker
            ThemedPanel {
                ForEach(Array(entry.figures(units: units).enumerated()), id: \.offset) { index, figure in
                    if index > 0 { ThemedRowDivider() }
                    FigureRow(figure: figure)
                }
            }
            .accessibilityIdentifier("activity.detail.figures")

            if let detail {
                // Built here, in the units chosen now, so changing one in
                // Settings redraws an open detail (WP-79).
                let series = ActivitySeriesBuilder.series(detail.samples, from: entry.start, to: entry.end, units: units)
                if let route = detail.route {
                    ThemedSectionHeader(title: "Route")
                    ActivityRouteMap(route: route)
                }
                if series.isEmpty {
                    Text("Nothing else was recorded during this activity.")
                        .font(Theme.font(Theme.Step.caption, .regular, relativeTo: .footnote))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 22)
                        .accessibilityIdentifier("activity.detail.empty")
                } else {
                    ThemedSectionHeader(title: "Recorded during this activity")
                    VStack(spacing: 12) {
                        ForEach(series) { series in
                            ActivitySeriesChart(series: series, start: entry.start, end: entry.end)
                        }
                    }
                }
            } else {
                ProgressView()
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 28)
            }
        }
    }

    /// "SUN 27 SEP · 07:02–07:48" over the source, like the list's rules.
    private var kicker: some View {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone)
        let day = entry.start.formatted(style.weekday(.abbreviated).day().month(.abbreviated))
        let times = "\(entry.start.formatted(style.hour().minute()))\u{2013}\(entry.end.formatted(style.hour().minute()))"
        return VStack(alignment: .leading, spacing: 4) {
            SilkscreenText("\(day) \u{00B7} \(times)")
                .font(Theme.mono(Theme.Step.micro, .medium, relativeTo: .caption2))
                .tracking(1.2)
                .foregroundStyle(Theme.secondary)
            SilkscreenText(entry.sourceLabel)
                .font(Theme.mono(Theme.Step.micro, .regular, relativeTo: .caption2))
                .tracking(0.5)
                .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("activity.detail.summary")
    }
}

/// A label and its reading; stacks at large text sizes rather than clip.
private struct FigureRow: View {
    let figure: ActivityFigure

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                label
                Spacer(minLength: 12)
                value
            }
            VStack(alignment: .leading, spacing: 4) {
                label
                value
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private var label: some View {
        Text(figure.label)
            .font(Theme.font(Theme.Step.body, .medium, relativeTo: .subheadline))
            .foregroundStyle(Theme.ink)
    }

    private var value: some View {
        Text(figure.value)
            .font(Theme.mono(Theme.Step.caption, .regular, relativeTo: .body))
            .foregroundStyle(Theme.secondary)
            .fixedSize()
    }
}

/// The workout's route, framed to fit, with its start and finish marked.
private struct ActivityRouteMap: View {
    let route: ActivityRoute

    var body: some View {
        Map(initialPosition: .automatic, interactionModes: [.pan, .zoom]) {
            MapPolyline(coordinates: route.coordinates)
                .stroke(Theme.accent, lineWidth: 3)
            if let first = route.coordinates.first {
                Annotation("Start", coordinate: first) { marker(Theme.Field.slate.color) }
            }
            if let last = route.coordinates.last {
                Annotation("Finish", coordinate: last) { marker(Theme.accent) }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .frame(height: 240)
        .overlay(Rectangle().stroke(Theme.border))
        .accessibilityLabel("Route map")
        .accessibilityIdentifier("activity.detail.map")
    }

    private func marker(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 10, height: 10)
            .overlay(Circle().stroke(Theme.surface, lineWidth: 2))
    }
}

/// One metric's time plot: a line per device, its headline figures above.
struct ActivitySeriesChart: View {
    let series: ActivityMetricSeries
    let start: Date
    let end: Date

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    /// The legend swatch's height above the baseline, scaled with the text.
    @ScaledMetric(relativeTo: .caption2) private var swatchLift: CGFloat = 3

    /// Each device's colour, fixed so a device reads the same on every chart.
    static func color(_ origin: SleepOrigin) -> Color {
        switch origin {
        case .appleWatch: return Theme.accent
        case .fitbit: return Theme.Field.slate.color
        case .otherApp: return Theme.Field.ochre.color
        }
    }

    var body: some View {
        ThemedPanel {
            VStack(alignment: .leading, spacing: 10) {
                Text(series.metric.title)
                    .font(Theme.font(Theme.Step.body, .medium, relativeTo: .subheadline))
                    .foregroundStyle(Theme.ink)
                // Read here: the alignment closure is Sendable and can't
                // touch the view's main-actor state.
                let lift = swatchLift
                ForEach(series.lines, id: \.origin) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        // Sits beside the first line of the label, however
                        // it wraps.
                        Rectangle().fill(Self.color(line.origin)).frame(width: 10, height: 3)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + lift }
                            .accessibilityHidden(true)
                        SilkscreenText("\(ActivitySource(line.origin).label) \u{00B7} \(series.summaryText(line, locale: locale))")
                            .font(Theme.mono(Theme.Step.micro, .regular, relativeTo: .caption2))
                            .tracking(0.5)
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                chart
                    .frame(height: 140)
                    // Axis labels stop growing at the largest standard size:
                    // past it the times run into each other in a chart
                    // this wide. The figures above carry the numbers.
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("activity.detail.chart.\(series.metric.rawValue)")
    }

    private var chart: some View {
        Chart {
            ForEach(series.lines, id: \.origin) { line in
                ForEach(Array(line.points.enumerated()), id: \.offset) { _, point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value(series.metric.title, point.value),
                        series: .value("Device", ActivitySource(line.origin).label)
                    )
                    .foregroundStyle(Self.color(line.origin))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
        }
        .chartXScale(domain: start...max(end, start.addingTimeInterval(60)))
        .chartYScale(domain: series.valueDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel(format: Date.FormatStyle(locale: locale, timeZone: timeZone).hour().minute())
                    .font(Theme.mono(Theme.Step.micro, .regular, relativeTo: .caption2))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel()
                    .font(Theme.mono(Theme.Step.micro, .regular, relativeTo: .caption2))
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }
}
