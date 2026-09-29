// ActivitySeriesTests.swift
//
// WP-73: the activity detail's plotted series -- which samples count,
// how devices split into lines, running totals, thinning and the headline
// figures -- plus the summary panel's figures, the route thinning and the
// in-app reader. All plain values or an in-memory store; no HealthKit.

import CoreLocation
import CoreModel
import Foundation
import SwiftData
import SyncKit
import Testing
@testable import HealthLoom

@Suite struct ActivitySeriesTests {
    static let start = Date(timeIntervalSince1970: 1_790_500_000)
    static let end = start.addingTimeInterval(3600)
    static let enGB = Locale(identifier: "en_GB")

    static func sample(
        _ metric: ActivityMetric, at minute: Double, _ value: Double,
        _ origin: SleepOrigin = .appleWatch, lasting seconds: Double = 60
    ) -> ActivitySample {
        let time = start.addingTimeInterval(minute * 60)
        return ActivitySample(metric: metric, start: time, end: time.addingTimeInterval(seconds), value: value, origin: origin)
    }

    // catches: samples from before or after the activity plotted on its
    // chart (the query window and the chart's must agree), and a metric
    // with nothing recorded still getting an empty chart.
    @Test func onlySamplesStartingInsideTheActivityCount() throws {
        let samples = [
            Self.sample(.heartRate, at: -1, 90),
            Self.sample(.heartRate, at: 10, 140),
            Self.sample(.heartRate, at: 60, 100), // starts exactly at the end
        ]
        let series = ActivitySeriesBuilder.series(samples, from: Self.start, to: Self.end)
        #expect(series.map(\.metric) == [.heartRate])
        let line = try #require(series.first?.lines.first)
        #expect(line.points.map(\.value) == [140])
    }

    // catches: two devices' readings merged into one zig-zag line (a
    // Fitbit and a watch disagree by a few bpm every second), or the lines
    // swapping order -- and colour -- between charts.
    @Test func eachDeviceGetsItsOwnLineInAFixedOrder() throws {
        let samples = [
            Self.sample(.heartRate, at: 1, 120, .fitbit),
            Self.sample(.heartRate, at: 2, 125, .appleWatch),
            Self.sample(.heartRate, at: 3, 130, .fitbit),
        ]
        let series = try #require(ActivitySeriesBuilder.series(samples, from: Self.start, to: Self.end).first)
        #expect(series.lines.map(\.origin) == [.appleWatch, .fitbit])
        #expect(series.lines.last?.points.map(\.value) == [120, 130])
    }

    // catches: charts in arrival order (HealthKit's queries finish in any
    // order, so the screen reshuffled on every open).
    @Test func chartsFollowTheCatalogOrder() {
        let samples = [
            Self.sample(.steps, at: 1, 90),
            Self.sample(.activeEnergy, at: 1, 8),
            Self.sample(.heartRate, at: 1, 120),
        ]
        let metrics = ActivitySeriesBuilder.series(samples, from: Self.start, to: Self.end).map(\.metric)
        #expect(metrics == [.heartRate, .activeEnergy, .steps])
    }

    // catches: an amount per interval (energy, steps) plotted per sample --
    // a sawtooth instead of the total climbing -- or the line not starting
    // at zero, or its total not matching the headline.
    @Test func amountsPlotAsARunningTotalFromZero() throws {
        let samples = [
            Self.sample(.activeEnergy, at: 5, 10),
            Self.sample(.activeEnergy, at: 0, 4),
            Self.sample(.activeEnergy, at: 20, 6),
        ]
        let line = try #require(ActivitySeriesBuilder.series(samples, from: Self.start, to: Self.end).first?.lines.first)
        #expect(line.points.map(\.value) == [0, 4, 14, 20])
        #expect(line.points.first?.date == Self.start)
        #expect(line.summary == .cumulative(total: 20))
    }

    // catches: readings summarized from the thinned points (a sprint's
    // peak averaged away from "max"), or the wrong figures.
    @Test func readingsSummarizeEverySample() throws {
        var samples = (0..<600).map { Self.sample(.heartRate, at: Double($0) / 10, 130) }
        samples.append(Self.sample(.heartRate, at: 30.05, 190))
        let line = try #require(ActivitySeriesBuilder.series(samples, from: Self.start, to: Self.end).first?.lines.first)
        guard case .sampled(let average, let minimum, let maximum) = line.summary else {
            Issue.record("Expected a sampled summary")
            return
        }
        #expect(maximum == 190)
        #expect(minimum == 130)
        #expect(abs(average - (130 * 600 + 190) / 601) < 0.0001)
        #expect(line.points.count <= ActivitySeriesBuilder.maxPointsPerLine)
    }

    // catches: a long ride plotting thousands of points (slow to lay out
    // on the main thread), and a thinned running total not ending on the
    // true total.
    @Test func longActivitiesAreThinnedAndTotalsStillEndTrue() throws {
        let samples = (0..<3600).map { Self.sample(.steps, at: Double($0) / 60, 2, lasting: 1) }
        let line = try #require(ActivitySeriesBuilder.series(samples, from: Self.start, to: Self.end).first?.lines.first)
        #expect(line.points.count <= ActivitySeriesBuilder.maxPointsPerLine)
        #expect(line.points.last?.value == 7200)
        #expect(line.points.map(\.value) == line.points.map(\.value).sorted())
    }

    // catches: a heart rate between 120 and 170 drawn against 0-200 (a
    // flat line at the top), or a running total's axis not starting at 0.
    @Test func readingsFitTheirRangeAndTotalsStartAtZero() throws {
        let heart = [Self.sample(.heartRate, at: 1, 120), Self.sample(.heartRate, at: 2, 170)]
        let heartSeries = try #require(ActivitySeriesBuilder.series(heart, from: Self.start, to: Self.end).first)
        #expect(heartSeries.valueDomain == 115...175)
        let energy = [Self.sample(.activeEnergy, at: 1, 30), Self.sample(.activeEnergy, at: 2, 20)]
        let energySeries = try #require(ActivitySeriesBuilder.series(energy, from: Self.start, to: Self.end).first)
        #expect(energySeries.valueDomain == 0...50)
    }

    // catches: a canonical HealthKit value shown raw -- a 3.2 m/s run as
    // "3.2 km/h", blood oxygen as "0.97 %", distance in metres as km.
    @Test func valuesShowInDisplayUnits() {
        #expect(ActivityMetric.runningSpeed.format(ActivityMetric.runningSpeed.displayValue(3.2), locale: Self.enGB) == "11.5 km/h")
        #expect(ActivityMetric.oxygenSaturation.format(ActivityMetric.oxygenSaturation.displayValue(0.97), locale: Self.enGB) == "97 %")
        #expect(ActivityMetric.distance.format(ActivityMetric.distance.displayValue(6210), locale: Self.enGB) == "6.21 km")
        #expect(ActivityMetric.steps.format(8240, locale: Self.enGB) == "8,240")
    }

    // catches: the headline dropping the range or the unit, or a total
    // shown as an average.
    @Test func headlinesReadAsAverageAndRangeOrTotal() {
        let reading = ActivitySeriesSummary.sampled(average: 142.4, minimum: 118, maximum: 171)
        #expect(reading.text(for: .heartRate, locale: Self.enGB) == "Avg 142 bpm \u{00B7} 118\u{2013}171")
        #expect(ActivitySeriesSummary.cumulative(total: 412).text(for: .activeEnergy, locale: Self.enGB) == "412 kcal")
    }

    // catches: a HealthKit-backed metric left without a type (its chart
    // never appears), or the in-app metrics sent to HealthKit.
    @Test func everyMetricHasExactlyOneSource() {
        let inApp = Set(ActivityLocalSampleReader.metrics.map(\.metric))
        for metric in ActivityMetric.allCases {
            let fromHealthKit = ActivityDetailProvider.healthKitType(for: metric) != nil
            #expect(fromHealthKit != inApp.contains(metric), "\(metric)")
        }
    }

    // catches: a GPS route drawn with every one-second fix (tens of
    // thousands of map points), thinning that loses the finish, or a
    // one-point "route" drawn as a line.
    @Test func routesAreThinnedKeepingBothEnds() throws {
        let coordinates = (0..<5_000).map { CLLocationCoordinate2D(latitude: 51.5 + Double($0) * 1e-5, longitude: -0.1) }
        let route = try #require(ActivityRoute(coordinates: coordinates))
        #expect(route.coordinates.count == ActivityRoute.maxPoints)
        #expect(route.coordinates.first?.latitude == coordinates.first?.latitude)
        #expect(route.coordinates.last?.latitude == coordinates.last?.latitude)
        #expect(ActivityRoute(coordinates: Array(coordinates.prefix(1))) == nil)
        #expect(ActivityRoute(coordinates: Array(coordinates.prefix(3)))?.coordinates.count == 3)
    }

    // catches: the detail's summary missing a recorded figure, or the
    // linked Fitbit session's figures passed off as the watch workout's own.
    @Test func figuresLabelTheSupplementByItsDevice() {
        let session = Data(#"{"exerciseType":"RUNNING","metricsSummary":{"distanceMillimeters":6300000.0,"caloriesKcal":410.0}}"#.utf8)
        let supplement = FitbitActivitySupplement(sample: LocalSample(
            externalID: "fitbit-run", dataType: GoogleDataType.exercise.rawValue,
            payloadJSON: Data(#"{"sessionPayload":"\#(session.base64EncodedString())"}"#.utf8),
            start: Self.start, end: Self.end, source: "Fitbit Air", linkedWatchWorkoutUUID: nil
        ))
        let entry = ActivityEntry(
            id: "run", kind: .unlinkedFitbitSession, title: "Run", start: Self.start,
            end: Self.start.addingTimeInterval(37 * 60), sourceLabel: "Apple Watch", supplement: supplement,
            family: .onFoot, distanceMeters: 6200, averageHeartRate: 148.4
        )
        #expect(entry.figures == [
            ActivityFigure(label: "Duration", value: "37 m"),
            ActivityFigure(label: "Distance", value: "6.2 km"),
            ActivityFigure(label: "Avg heart rate", value: "148 bpm"),
            ActivityFigure(label: "Fitbit Air distance", value: "6.3 km"),
            ActivityFigure(label: "Fitbit Air energy", value: "410 kcal"),
        ])
    }

    // catches: the in-app reader leaking other types or rows outside the
    // activity into its charts, or reading the wrong payload key (every
    // zone minute read as nothing).
    @Test func theInAppReaderReadsOnlyTheActivitysMinutes() async throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let context = ModelContext(container)
        func row(_ id: String, _ type: GoogleDataType, minute: Double, minutes: Double) {
            let time = Self.start.addingTimeInterval(minute * 60)
            context.insert(LocalSample(
                externalID: id, dataType: type.rawValue,
                payloadJSON: Data(#"{"values":{"minutes":\#(minutes)}}"#.utf8),
                start: time, end: time.addingTimeInterval(60), source: "Fitbit Air", linkedWatchWorkoutUUID: nil
            ))
        }
        row("azm-in", .activeZoneMinutes, minute: 5, minutes: 2)
        row("azm-before", .activeZoneMinutes, minute: -5, minutes: 2)
        row("am-in", .activeMinutes, minute: 6, minutes: 1)
        row("steps-in", .steps, minute: 7, minutes: 9)
        try context.save()

        let samples = try await ActivityLocalSampleReader(modelContainer: container).samples(from: Self.start, to: Self.end)
        #expect(samples.map(\.metric).sorted { $0.rawValue < $1.rawValue } == [.activeMinutes, .activeZoneMinutes])
        #expect(samples.first { $0.metric == .activeZoneMinutes }?.value == 2)
        #expect(samples.allSatisfy { $0.origin == .fitbit })
    }

    // catches (WP-74): the Activities list's query drifting from
    // `GoogleDataType.exercise` (it held a typed copy of the string) --
    // the list would silently lose every Fitbit session -- or letting
    // per-minute rows back onto the main thread (WP-67).
    @Test func theActivitiesQueryReadsExerciseSessionsOnly() throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let context = ModelContext(container)
        for (id, type) in [("run", GoogleDataType.exercise), ("am", .activeMinutes), ("azm", .activeZoneMinutes)] {
            context.insert(LocalSample(
                externalID: id, dataType: type.rawValue, payloadJSON: Data("{}".utf8),
                start: Self.start, end: Self.end, source: "Fitbit Air", linkedWatchWorkoutUUID: nil
            ))
        }
        try context.save()
        let rows = try ModelContext(container).fetch(ActivitiesView.exerciseSessions)
        #expect(rows.map(\.externalID) == ["run"])
    }
}
