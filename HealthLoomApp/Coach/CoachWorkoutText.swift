// CoachWorkoutText.swift
//
// WP-77: what the coach's workout tools answer -- the text the model reads
// (and the trace UI shows, D7). Pure: the consolidated Activities entries
// and the detail screen's series in, text out; `CoachWorkoutReader` does
// the reading. Everything the detail screen reads is reachable: the
// overview names every measurement with its per-device summary, and any
// one of them breaks down by distance and by minute. Routes never appear.
//
// Each answer is bounded (splits and buckets are capped), so it fits the
// on-device model's context; a larger model asks for more by calling again.

import Foundation

enum CoachWorkoutText {
    /// Rows in a distance split table or an overview's time table.
    static let maxSplits = 20
    /// Rows in a measurement's per-minute breakdown.
    static let maxBuckets = 60
    /// Rows in the overview's time table, when there's no distance to split by.
    static let maxOverviewBuckets = 12

    static let readAccessNote = "Some measurements (running power, stride length, ground contact time, vertical "
        + "oscillation and others) aren't readable yet: opening any activity in HealthLoom's Activities tab once "
        + "asks for access."

    // MARK: - List

    /// One line per workout started in the last `days` days, numbered by
    /// position in `entries` (newest first) -- the numbers
    /// `getWorkoutDetail` takes, whatever window is listed.
    static func list(
        _ entries: [ActivityEntry], days: Int, now: Date, units: UnitPreferences, calendar: Calendar, locale: Locale
    ) -> String {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        let lines = entries.enumerated()
            .filter { $0.element.start >= since }
            .map { index, entry in
                ([heading(entry, number: index + 1, calendar: calendar, locale: locale, withEnd: false)]
                    + entry.figures(units: units).map(figureText)).joined(separator: " \u{00B7} ")
            }
        guard !lines.isEmpty else { return "No workouts in the last \(days) days." }
        return (["Workouts in the last \(days) days, newest first. Pass a number to getWorkoutDetail for everything recorded during it."]
            + lines).joined(separator: "\n")
    }

    /// The workout a `getWorkouts` number names, if there is one.
    static func entry(number: Int, in entries: [ActivityEntry]) -> ActivityEntry? {
        entries.indices.contains(number - 1) ? entries[number - 1] : nil
    }

    static func noWorkout(number: Int, count: Int, days: Int) -> String {
        count == 0
            ? "No workouts in the last \(days) days."
            : "There's no workout \(number): getWorkouts numbers \(count) workouts in the last \(days) days, 1 being the most recent."
    }

    // MARK: - Detail

    /// One workout: its overview, or -- when `measurement` names one it
    /// recorded -- that measurement's breakdown. `series` are in the units
    /// the figures show in.
    static func detail(
        _ entry: ActivityEntry,
        number: Int,
        series: [ActivityMetricSeries],
        units: UnitPreferences,
        measurement: String?,
        needsReadAccess: Bool,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        var lines = [
            heading(entry, number: number, calendar: calendar, locale: locale, withEnd: true),
            entry.figures(units: units).map(figureText).joined(separator: " \u{00B7} "),
        ]
        if let measurement {
            if let match = Self.series(named: measurement, in: series) {
                lines += breakdown(match, of: entry, series: series, locale: locale)
            } else {
                let recorded = series.map(\.metric.title).joined(separator: ", ")
                lines.append("No measurement called \"\(measurement)\" was recorded during it."
                    + (recorded.isEmpty ? "" : " Recorded: \(recorded)."))
            }
        } else {
            lines += overview(of: entry, series: series, locale: locale)
        }
        if needsReadAccess { lines.append(readAccessNote) }
        return lines.joined(separator: "\n")
    }

    private static func overview(of entry: ActivityEntry, series: [ActivityMetricSeries], locale: Locale) -> [String] {
        guard !series.isEmpty else { return ["No measurements were recorded during it beyond these figures."] }
        var lines = ["Measurements (pass one as measurement for its breakdown by distance and by minute):"]
        lines += series.map { "- \($0.metric.title) \u{2014} " + summaries($0, locale: locale) }
        let heartSeries = series.first { $0.metric == .heartRate }
        let heartRate = heartSeries?.lines.first
        if let splits = DistanceSplits(series: series) {
            lines.append("Splits (\(ActivitySource(splits.line.origin).label) \(splits.metric.title.lowercased())):")
            lines += splits.rows.map { row in
                var parts = [splits.pace(row, locale: locale)]
                if let heartSeries, let heartRate, let bpm = value(of: heartRate, metric: .heartRate, from: row.start, to: row.end) {
                    parts.append("heart rate \(heartSeries.format(bpm, locale: locale))")
                }
                return "- \(splits.label(row, locale: locale)): " + parts.joined(separator: " \u{00B7} ")
            }
        } else if let heartSeries, let heartRate {
            let buckets = TimeBuckets(start: entry.start, end: entry.end, maxRows: maxOverviewBuckets)
            lines.append("Heart rate every \(buckets.minutes) min (\(ActivitySource(heartRate.origin).label)):")
            lines += buckets.rows.compactMap { row in
                value(of: heartRate, metric: .heartRate, from: row.start, to: row.end).map {
                    "- \(buckets.label(row)): \(heartSeries.format($0, locale: locale))"
                }
            }
        }
        return lines
    }

    private static func breakdown(
        _ measured: ActivityMetricSeries, of entry: ActivityEntry, series: [ActivityMetricSeries], locale: Locale
    ) -> [String] {
        let metric = measured.metric
        var lines = ["\(metric.title) \u{2014} " + summaries(measured, locale: locale)]
        func row(_ label: String, from start: Date, to end: Date) -> String? {
            let values = measured.lines.compactMap { line in
                value(of: line, metric: metric, from: start, to: end).map { (line.origin, $0) }
            }
            guard !values.isEmpty else { return nil }
            let text = measured.lines.count == 1
                ? values.map { measured.format($0.1, locale: locale) }
                : values.map { "\(ActivitySource($0.0).label) \(measured.format($0.1, locale: locale))" }
            return "- \(label): " + text.joined(separator: ", ")
        }
        if let splits = DistanceSplits(series: series) {
            lines.append("By distance (\(ActivitySource(splits.line.origin).label) \(splits.metric.title.lowercased())):")
            lines += splits.rows.compactMap { row(splits.label($0, locale: locale), from: $0.start, to: $0.end) }
        }
        let buckets = TimeBuckets(start: entry.start, end: entry.end, maxRows: maxBuckets)
        lines.append(buckets.minutes == 1 ? "By minute:" : "Every \(buckets.minutes) min:")
        lines += buckets.rows.compactMap { row(buckets.label($0), from: $0.start, to: $0.end) }
        return lines
    }

    // MARK: - Pieces

    private static func heading(
        _ entry: ActivityEntry, number: Int, calendar: Calendar, locale: Locale, withEnd: Bool
    ) -> String {
        var day = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute().locale(locale)
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        var when = entry.start.formatted(day)
        if withEnd {
            var time = Date.FormatStyle.dateTime.hour().minute().locale(locale)
            time.calendar = calendar
            time.timeZone = calendar.timeZone
            when += "\u{2013}" + entry.end.formatted(time)
        }
        // "1. Run" in the list; "Workout 1: Run" heading one workout's detail.
        let name = withEnd ? "Workout \(number): \(entry.title)" : "\(number). \(entry.title)"
        return "\(name) \u{2014} \(when) \u{00B7} \(entry.sourceLabel)"
    }

    private static func figureText(_ figure: ActivityFigure) -> String {
        "\(figure.label) \(figure.value)"
    }

    private static func summaries(_ series: ActivityMetricSeries, locale: Locale) -> String {
        series.lines
            .map { "\(ActivitySource($0.origin).label): \(series.summaryText($0, locale: locale))" }
            .joined(separator: "; ")
    }

    /// The recorded series a model's measurement name means: the title or
    /// case name exactly (ignoring case, spaces and punctuation), else the
    /// first title containing it, or contained in it ("power" on a run).
    static func series(named name: String, in series: [ActivityMetricSeries]) -> ActivityMetricSeries? {
        func key(_ text: String) -> String { text.lowercased().filter(\.isLetter) }
        let wanted = key(name)
        guard !wanted.isEmpty else { return nil }
        return series.first { key($0.metric.title) == wanted || key($0.metric.rawValue) == wanted }
            ?? series.first { key($0.metric.title).contains(wanted) || wanted.contains(key($0.metric.title)) }
    }

    /// A line's value over `[start, end)`: the mean reading for a sampled
    /// metric (nil with none inside), the amount added for a cumulative one.
    static func value(of line: ActivitySeriesLine, metric: ActivityMetric, from start: Date, to end: Date) -> Double? {
        switch metric.style {
        case .sampled:
            let inside = line.points.filter { $0.date >= start && $0.date < end }.map(\.value)
            return inside.isEmpty ? nil : inside.reduce(0, +) / Double(inside.count)
        case .cumulative:
            return runningTotal(line.points, at: end) - runningTotal(line.points, at: start)
        }
    }

    /// A running total's value at `date`, interpolated between its points.
    static func runningTotal(_ points: [ActivitySeriesPoint], at date: Date) -> Double {
        guard let first = points.first, date > first.date else { return 0 }
        guard let after = points.firstIndex(where: { $0.date >= date }) else { return points.last?.value ?? 0 }
        let (a, b) = (points[after - 1], points[after])
        let span = b.date.timeIntervalSince(a.date)
        guard span > 0 else { return b.value }
        return a.value + (b.value - a.value) * date.timeIntervalSince(a.date) / span
    }

    /// When a running total first reaches `target`, interpolated; nil if it never does.
    static func time(_ points: [ActivitySeriesPoint], reaching target: Double) -> Date? {
        guard let after = points.firstIndex(where: { $0.value >= target }) else { return nil }
        guard after > 0 else { return points[after].date }
        let (a, b) = (points[after - 1], points[after])
        let rise = b.value - a.value
        guard rise > 0 else { return b.date }
        return a.date.addingTimeInterval(b.date.timeIntervalSince(a.date) * (target - a.value) / rise)
    }
}

/// Splits by distance, from the longest distance a device recorded: per
/// kilometre or mile (per 100 m or yd in the pool), in the series' own
/// units, widened to keep at most `CoachWorkoutText.maxSplits` rows. A
/// remainder under a tenth of a split joins the last one.
struct DistanceSplits {
    struct Row {
        let from: Double
        let to: Double
        let start: Date
        let end: Date
    }

    let series: ActivityMetricSeries
    let line: ActivitySeriesLine
    /// Split length, in the series' display unit.
    let length: Double
    let rows: [Row]

    var metric: ActivityMetric { series.metric }

    init?(series all: [ActivityMetricSeries]) {
        let candidates = all.filter { [.distance, .cyclingDistance, .swimmingDistance].contains($0.metric) }
        guard let best = candidates.compactMap({ candidate in candidate.lines.first.map { (candidate, $0) } })
            .max(by: { Self.meters($0.0, $0.1) < Self.meters($1.0, $1.1) }) else { return nil }
        let total = Self.total(best.1)
        let base = best.0.metric == .swimmingDistance ? 100.0 : 1.0
        guard total >= base else { return nil }
        let length = base * max(1, (total / base / Double(CoachWorkoutText.maxSplits)).rounded(.up))
        var rows: [Row] = []
        var from = 0.0
        var start = best.1.points.first?.date ?? .distantPast
        while from < total {
            var to = min(from + length, total)
            if total - to < length / 10 { to = total }
            let end = CoachWorkoutText.time(best.1.points, reaching: to) ?? best.1.points.last?.date ?? start
            rows.append(Row(from: from, to: to, start: start, end: end))
            (from, start) = (to, end)
        }
        self.series = best.0
        self.line = best.1
        self.length = length
        self.rows = rows
    }

    private static func total(_ line: ActivitySeriesLine) -> Double {
        if case .cumulative(let total) = line.summary { return total }
        return 0
    }

    /// A line's distance in metres, so a swim in yards and a run in miles
    /// compare by what was covered.
    private static func meters(_ series: ActivityMetricSeries, _ line: ActivitySeriesLine) -> Double {
        let perUnit = series.metric == .swimmingDistance ? series.units.pool.meters : series.units.distance.meters
        return total(line) * perUnit
    }

    /// "0–1 km", "0–1 mi", "200–300 yd".
    func label(_ row: Row, locale: Locale) -> String {
        "\(number(row.from, locale: locale))\u{2013}\(number(row.to, locale: locale)) \(series.unit)"
    }

    /// Pace per km or mile (per 100 m or yd swimming), or speed on a ride.
    func pace(_ row: Row, locale: Locale) -> String {
        let seconds = row.end.timeIntervalSince(row.start)
        let covered = row.to - row.from
        guard seconds > 0, covered > 0 else { return "no time recorded" }
        if metric == .cyclingDistance {
            return ActivityMetric.cyclingSpeed.format(covered / (seconds / 3600), units: series.units, locale: locale)
        }
        let per = metric == .swimmingDistance ? 100.0 : 1.0
        let pace = Int((seconds / covered * per).rounded())
        let unit = metric == .swimmingDistance ? "100 \(series.unit)" : series.unit
        return String(format: "%d:%02d", pace / 60, pace % 60) + " /\(unit)"
    }

    /// Whole lengths in the pool, up to two places otherwise; no unit.
    private func number(_ value: Double, locale: Locale) -> String {
        if metric == .swimmingDistance {
            return "\(Int(value.rounded()))"
        }
        return value.formatted(.number.precision(.fractionLength(0...2)).locale(locale))
    }
}

/// Equal time slices from the start, whole minutes long, at most `maxRows`.
struct TimeBuckets {
    struct Row {
        let index: Int
        let start: Date
        let end: Date
    }

    let minutes: Int
    let rows: [Row]

    init(start: Date, end: Date, maxRows: Int) {
        let duration = max(end.timeIntervalSince(start), 60)
        let minutes = max(1, Int((duration / 60 / Double(maxRows)).rounded(.up)))
        let count = Int((duration / Double(minutes * 60)).rounded(.up))
        self.minutes = minutes
        self.rows = (0..<count).map { index in
            Row(
                index: index,
                start: start.addingTimeInterval(Double(index * minutes * 60)),
                end: min(start.addingTimeInterval(Double((index + 1) * minutes * 60)), end)
            )
        }
    }

    func label(_ row: Row) -> String {
        "\(row.index * minutes)\u{2013}\((row.index + 1) * minutes) min"
    }
}
