// ActivitySeries.swift
//
// WP-73: what the activity detail screen plots -- every measurement
// recorded during an activity, one time series per metric and device.
// HealthKit-free on purpose, like ActivitiesModels.swift: the provider
// (ActivityDetailProvider.swift) reduces HealthKit and in-app samples to
// `ActivitySample`s, and everything from there to the plotted points --
// window clipping, device lines, running totals, thinning, the headline
// figures -- is plain-value logic the unit tests drive directly.

import CoreLocation
import Foundation
import SyncKit

/// One kind of measurement the detail screen can plot, in display order.
/// The HealthKit side of each case (type and unit) lives in the provider;
/// this catalog owns only how a metric reads.
nonisolated enum ActivityMetric: String, CaseIterable, Hashable, Sendable {
    case heartRate
    case activeEnergy
    case distance
    case cyclingDistance
    case swimmingDistance
    case steps
    case runningSpeed
    case runningPower
    case runningStrideLength
    case runningVerticalOscillation
    case runningGroundContactTime
    case cyclingSpeed
    case cyclingPower
    case cyclingCadence
    case swimmingStrokes
    case flightsClimbed
    case respiratoryRate
    case oxygenSaturation
    /// Fitbit's per-minute counts, kept in-app (never written to Health).
    case activeZoneMinutes
    case activeMinutes

    /// How samples combine over the activity.
    nonisolated enum Style: Equatable, Sendable {
        /// A reading at a moment (heart rate, speed): plotted as read,
        /// summarized as average and range.
        case sampled
        /// An amount per interval (energy, steps): plotted as the running
        /// total, summarized as the total.
        case cumulative
    }

    var style: Style {
        switch self {
        case .heartRate, .runningSpeed, .runningPower, .runningStrideLength,
             .runningVerticalOscillation, .runningGroundContactTime, .cyclingSpeed,
             .cyclingPower, .cyclingCadence, .respiratoryRate, .oxygenSaturation:
            return .sampled
        case .activeEnergy, .distance, .cyclingDistance, .swimmingDistance, .steps,
             .swimmingStrokes, .flightsClimbed, .activeZoneMinutes, .activeMinutes:
            return .cumulative
        }
    }

    var title: String {
        switch self {
        case .heartRate: return "Heart rate"
        case .activeEnergy: return "Active energy"
        case .distance: return "Distance"
        case .cyclingDistance: return "Cycling distance"
        case .swimmingDistance: return "Swimming distance"
        case .steps: return "Steps"
        case .runningSpeed: return "Running speed"
        case .runningPower: return "Running power"
        case .runningStrideLength: return "Stride length"
        case .runningVerticalOscillation: return "Vertical oscillation"
        case .runningGroundContactTime: return "Ground contact time"
        case .cyclingSpeed: return "Cycling speed"
        case .cyclingPower: return "Cycling power"
        case .cyclingCadence: return "Cadence"
        case .swimmingStrokes: return "Strokes"
        case .flightsClimbed: return "Flights climbed"
        case .respiratoryRate: return "Breathing rate"
        case .oxygenSaturation: return "Blood oxygen"
        case .activeZoneMinutes: return "Zone minutes"
        case .activeMinutes: return "Active minutes"
        }
    }

    /// The display unit; empty for plain counts.
    var unit: String {
        switch self {
        case .heartRate: return "bpm"
        case .activeEnergy: return "kcal"
        case .distance, .cyclingDistance, .swimmingDistance: return "km"
        case .steps, .swimmingStrokes, .flightsClimbed: return ""
        case .runningSpeed, .cyclingSpeed: return "km/h"
        case .runningPower, .cyclingPower: return "W"
        case .runningStrideLength: return "m"
        case .runningVerticalOscillation: return "cm"
        case .runningGroundContactTime: return "ms"
        case .cyclingCadence: return "rpm"
        case .respiratoryRate: return "br/min"
        case .oxygenSaturation: return "%"
        case .activeZoneMinutes, .activeMinutes: return "min"
        }
    }

    /// A sample's canonical value (the unit the provider reads it in:
    /// metres, metres per second, a 0...1 fraction) in display units.
    func displayValue(_ canonical: Double) -> Double {
        switch self {
        case .distance, .cyclingDistance, .swimmingDistance: return canonical / 1000
        case .runningSpeed, .cyclingSpeed: return canonical * 3.6
        case .oxygenSaturation: return canonical * 100
        default: return canonical
        }
    }

    /// Decimal places a display value is shown with.
    var fractionDigits: Int {
        switch self {
        case .distance, .cyclingDistance, .swimmingDistance, .runningStrideLength: return 2
        case .runningSpeed, .cyclingSpeed, .runningVerticalOscillation, .respiratoryRate: return 1
        default: return 0
        }
    }

    /// The number alone, at this metric's precision: "142", "6.21", "8,240".
    func formatNumber(_ displayValue: Double, locale: Locale = .current) -> String {
        displayValue.formatted(.number.precision(.fractionLength(fractionDigits)).locale(locale))
    }

    /// With its unit: "142 bpm", "6.21 km", "8,240".
    func format(_ displayValue: Double, locale: Locale = .current) -> String {
        let number = formatNumber(displayValue, locale: locale)
        return unit.isEmpty ? number : "\(number) \(unit)"
    }
}

/// One measurement, reduced from HealthKit or an in-app row. `value` is in
/// the metric's canonical unit (see `ActivityMetric.displayValue`).
nonisolated struct ActivitySample: Equatable, Sendable {
    let metric: ActivityMetric
    let start: Date
    let end: Date
    let value: Double
    let origin: SleepOrigin
}

/// One plotted point, in display units.
nonisolated struct ActivitySeriesPoint: Equatable, Sendable {
    let date: Date
    let value: Double
}

/// A line's headline figures, from every sample (not the thinned points,
/// so a spike the plot smooths still shows as the maximum).
nonisolated enum ActivitySeriesSummary: Equatable, Sendable {
    case sampled(average: Double, minimum: Double, maximum: Double)
    case cumulative(total: Double)
}

extension ActivitySeriesSummary {
    /// The headline under a chart's device name: "Avg 142 bpm · 118–171"
    /// for readings, "412 kcal" for a total.
    func text(for metric: ActivityMetric, locale: Locale = .current) -> String {
        switch self {
        case .sampled(let average, let minimum, let maximum):
            let range = "\(metric.formatNumber(minimum, locale: locale))\u{2013}\(metric.formatNumber(maximum, locale: locale))"
            return "Avg \(metric.format(average, locale: locale)) \u{00B7} \(range)"
        case .cumulative(let total):
            return metric.format(total, locale: locale)
        }
    }
}

/// One device's line on a metric's chart.
nonisolated struct ActivitySeriesLine: Equatable, Sendable {
    let origin: SleepOrigin
    let points: [ActivitySeriesPoint]
    let summary: ActivitySeriesSummary
}

/// One chart: a metric and a line per device that recorded it.
nonisolated struct ActivityMetricSeries: Identifiable, Equatable, Sendable {
    let metric: ActivityMetric
    let lines: [ActivitySeriesLine]

    var id: ActivityMetric { metric }

    /// The chart's value axis. A running total starts at zero; readings
    /// fit their own range with a little room, so a heart rate between
    /// 120 and 170 fills the chart instead of hugging the top of 0-200.
    var valueDomain: ClosedRange<Double> {
        let values = lines.flatMap { $0.points.map(\.value) }
        let low = values.min() ?? 0
        let high = values.max() ?? 0
        switch metric.style {
        case .cumulative:
            return 0...max(high, 1)
        case .sampled:
            let pad = max((high - low) * 0.1, 1)
            return (low - pad)...(high + pad)
        }
    }
}

nonisolated enum ActivitySeriesBuilder {
    /// Most points one line plots. A watch reads heart rate every few
    /// seconds; a two-hour ride is thousands of samples, more than a chart
    /// a few hundred points wide can show and slow to lay out.
    static let maxPointsPerLine = 240

    /// Device lines in a fixed order, so colours stay put between screens.
    static let originOrder: [SleepOrigin] = [.appleWatch, .fitbit, .otherApp]

    /// Every metric with at least one sample starting inside
    /// `start ..< end`, in catalog order, one line per device.
    static func series(_ samples: [ActivitySample], from start: Date, to end: Date) -> [ActivityMetricSeries] {
        let inWindow = samples.filter { $0.start >= start && $0.start < end }
        let byMetric = Dictionary(grouping: inWindow, by: \.metric)
        return ActivityMetric.allCases.compactMap { metric in
            guard let metricSamples = byMetric[metric] else { return nil }
            let byOrigin = Dictionary(grouping: metricSamples, by: \.origin)
            let lines = originOrder.compactMap { origin in
                byOrigin[origin].map { line(metric: metric, origin: origin, samples: $0, start: start, end: end) }
            }
            return ActivityMetricSeries(metric: metric, lines: lines)
        }
    }

    private static func line(
        metric: ActivityMetric, origin: SleepOrigin, samples: [ActivitySample], start: Date, end: Date
    ) -> ActivitySeriesLine {
        let sorted = samples.sorted { $0.start < $1.start }
        switch metric.style {
        case .sampled:
            let points = sorted.map { ActivitySeriesPoint(date: $0.start, value: metric.displayValue($0.value)) }
            let values = points.map(\.value)
            let summary = ActivitySeriesSummary.sampled(
                average: values.reduce(0, +) / Double(values.count),
                minimum: values.min() ?? 0,
                maximum: values.max() ?? 0
            )
            return ActivitySeriesLine(
                origin: origin,
                points: thinned(points, from: start, to: end, keepLast: false),
                summary: summary
            )
        case .cumulative:
            // The running total at each sample's end, from zero at the start.
            var total = 0.0
            var points = [ActivitySeriesPoint(date: start, value: 0)]
            for sample in sorted {
                total += metric.displayValue(sample.value)
                points.append(ActivitySeriesPoint(date: min(sample.end, end), value: total))
            }
            return ActivitySeriesLine(
                origin: origin,
                points: thinned(points, from: start, to: end, keepLast: true),
                summary: .cumulative(total: total)
            )
        }
    }

    /// At most `maxPointsPerLine` points: the window splits into that many
    /// equal slices and each slice with points becomes one -- the mean for
    /// readings, the slice's last point for a running total (which must
    /// still end on the true total).
    static func thinned(
        _ points: [ActivitySeriesPoint], from start: Date, to end: Date, keepLast: Bool
    ) -> [ActivitySeriesPoint] {
        guard points.count > maxPointsPerLine, end > start else { return points }
        let span = end.timeIntervalSince(start)
        let slices = Dictionary(grouping: points) { point in
            min(maxPointsPerLine - 1, max(0, Int(point.date.timeIntervalSince(start) / span * Double(maxPointsPerLine))))
        }
        return slices.keys.sorted().compactMap { key in
            guard let slice = slices[key], let last = slice.last else { return nil }
            if keepLast { return last }
            let time = slice.reduce(0) { $0 + $1.date.timeIntervalSince1970 } / Double(slice.count)
            let value = slice.reduce(0) { $0 + $1.value } / Double(slice.count)
            return ActivitySeriesPoint(date: Date(timeIntervalSince1970: time), value: value)
        }
    }
}

/// A workout's recorded route, thinned for drawing.
nonisolated struct ActivityRoute: Equatable, Sendable {
    let coordinates: [CLLocationCoordinate2D]

    /// Most points drawn: a GPS route logs one a second, and a map line
    /// needs far fewer to look the same.
    static let maxPoints = 1_000

    /// Evenly spaced points, always keeping the first and last; nil with
    /// fewer than two (no line to draw).
    init?(coordinates: [CLLocationCoordinate2D]) {
        guard coordinates.count >= 2 else { return nil }
        guard coordinates.count > Self.maxPoints else {
            self.coordinates = coordinates
            return
        }
        let step = Double(coordinates.count - 1) / Double(Self.maxPoints - 1)
        self.coordinates = (0..<Self.maxPoints).map { coordinates[Int((Double($0) * step).rounded())] }
    }

    static func == (lhs: ActivityRoute, rhs: ActivityRoute) -> Bool {
        lhs.coordinates.count == rhs.coordinates.count
            && zip(lhs.coordinates, rhs.coordinates).allSatisfy { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
    }
}

/// Device names for the chart legends.
nonisolated extension SleepOrigin {
    var deviceLabel: String {
        switch self {
        case .appleWatch: return "Apple Watch"
        case .fitbit: return "Fitbit"
        case .otherApp: return "Other app"
        }
    }
}
