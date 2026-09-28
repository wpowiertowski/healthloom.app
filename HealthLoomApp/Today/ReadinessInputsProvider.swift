// ReadinessInputsProvider.swift
//
// WP-33 (implementation-plan.md) step 1's remainder: "readiness hero <-
// `ReadinessEngine`". The engine is deterministic and pure
// (`ReadinessEngine.score(inputs:recentScores:)`); this provider is the one
// HealthKit-touching piece that assembles its inputs, mirroring
// `TodayMetricsProvider`'s conventions (continuation-bridged queries,
// failure→nil posture so the hero degrades to its pending/insufficient
// states instead of erroring):
//   - HRV ratio: latest SDNN sample vs its 30-day average baseline;
//   - resting-HR delta: latest resting HR vs its 30-day average baseline;
//   - sleep hours + efficiency: `LastNightSleep` -- the same window and
//     summary the Today sleep row uses (6 pm yesterday to noon, overlaps
//     counted once, efficiency = asleep ÷ in-bed span);
//   - prior-day strain: yesterday's workout energy, mapped to 0...1 at
//     800 kcal = maximal (a documented heuristic, not physiology — the
//     engine treats it as recovery demand, and the mapping is the one
//     place to wire a real load model in). A day without workouts is
//     strain 0 (full rest) for someone who logged any in the past 30
//     days; with none in 30 days there's no signal (`priorDayKcal`).
//
// `assemble(_:)` is pure so `TodayReadinessTests` pins the math without
// HealthKit; `ReadinessScoreHistory` (UserDefaults, last-30 ring) feeds
// `recentScores`, giving the "+N vs 30-day average" caption after days of
// use and `nil` (no delta clause) before that. Zero usable signals maps
// to `.pending` — the engine's all-nil fallback (score 50, 0 signals) must
// never render as a real score.

import CoachKit
import Foundation
import HealthKit

/// Fetched aggregates; every field optional, assembled purely below.
struct ReadinessAggregates: Equatable {
    var hrvLatestMs: Double?
    var hrvBaselineMs: Double?
    var restingHRLatestBpm: Double?
    var restingHRBaselineBpm: Double?
    var sleepSeconds: Double?
    var sleepEfficiency: Double?
    var priorDayWorkoutKcal: Double?
}

@MainActor
final class ReadinessInputsProvider {
    private let healthStore: HKHealthStore
    private let calendar: Calendar

    init(healthStore: HKHealthStore = HKHealthStore(), calendar: Calendar = .current) {
        self.healthStore = healthStore
        self.calendar = calendar
    }

    /// Assembles engine inputs from fetched aggregates. Pure.
    static func assemble(_ aggregates: ReadinessAggregates) -> ReadinessInputs {
        var inputs = ReadinessInputs()
        if let latest = aggregates.hrvLatestMs,
           let baseline = aggregates.hrvBaselineMs, baseline > 0
        {
            inputs.hrvRatio = latest / baseline
        }
        if let latest = aggregates.restingHRLatestBpm,
           let baseline = aggregates.restingHRBaselineBpm
        {
            inputs.restingHRDeltaBeatsPerMinute = latest - baseline
        }
        if let seconds = aggregates.sleepSeconds {
            inputs.sleepHours = seconds / 3600
        }
        inputs.sleepEfficiency = aggregates.sleepEfficiency
        if let kcal = aggregates.priorDayWorkoutKcal {
            inputs.priorDayStrain = min(max(kcal / 800, 0), 1)
        }
        return inputs
    }

    /// Maps an engine result onto the hero's display states. Pure: zero
    /// usable signals is `.pending` (never the engine's all-nil 50), and
    /// a missing delta passes through as nil (H1) — the hero explains the
    /// absent comparison, never an uncomputed "+0 average".
    ///
    /// Takes the `inputs` the score was computed from, not just the score:
    /// the hero names which signals contributed (WP-42) and draws each at
    /// its own subscore (WP-43), and only the inputs know either.
    static func display(_ readiness: Readiness, inputs: ReadinessInputs) -> ReadinessDisplay {
        // One source for both "which signals reported" and "how much each
        // contributed": the engine's own subscore table, which is exactly
        // what `score` took the weighted mean of. Gating on it rather than
        // consulting `signalsUsed` too keeps the pending rule (zero usable
        // signals never renders as a real score) reading off a single fact.
        let signalScores = ReadinessEngine.signalScores(inputs: inputs)
        guard !signalScores.isEmpty else { return .pending }
        return .scored(
            score: readiness.score,
            deltaVsBaseline: readiness.deltaVsAverage,
            signalScores: signalScores
        )
    }

    func aggregates(now: Date = Date()) async -> ReadinessAggregates {
        guard HKHealthStore.isHealthDataAvailable() else { return ReadinessAggregates() }
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        async let hrvLatest = latestQuantity(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), now: now)
        async let hrvBaseline = averageQuantity(
            .heartRateVariabilitySDNN, unit: .secondUnit(with: .milli),
            from: thirtyDaysAgo, to: now
        )
        async let rhrLatest = latestQuantity(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), now: now)
        async let rhrBaseline = averageQuantity(
            .restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()),
            from: thirtyDaysAgo, to: now
        )
        async let sleep = lastNightSleep(now: now)
        async let strain = yesterdayWorkoutKcal(now: now)
        let slept = await sleep
        return ReadinessAggregates(
            hrvLatestMs: await hrvLatest,
            hrvBaselineMs: await hrvBaseline,
            restingHRLatestBpm: await rhrLatest,
            restingHRBaselineBpm: await rhrBaseline,
            sleepSeconds: slept?.asleep,
            sleepEfficiency: slept?.efficiency,
            priorDayWorkoutKcal: await strain
        )
    }

    // MARK: - Query shapes (same bridging as TodayMetricsProvider)

    /// Latest sample within the past 7 days (L3): a watch unworn for
    /// months still holds ancient HRV/RHR samples, and scoring those as
    /// current would render a stale-data score as fresh. Older than 7 days
    /// reads as no data — the hero degrades to pending/insufficient.
    private func latestQuantity(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, now: Date) async -> Double? {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return nil }
        let cutoff = calendar.date(byAdding: .day, value: -7, to: now)
        let predicate = cutoff.map { HKQuery.predicateForSamples(withStart: $0, end: nil, options: []) }
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: 1,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            ) { _, samples, _ in
                guard let sample = samples?.first as? HKQuantitySample else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: sample.quantity.doubleValue(for: unit))
            }
            healthStore.execute(query)
        }
    }

    private func averageQuantity(
        _ identifier: HKQuantityTypeIdentifier, unit: HKUnit, from start: Date, to end: Date
    ) async -> Double? {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .discreteAverage
            ) { _, statistics, _ in
                guard let average = statistics?.averageQuantity() else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: average.doubleValue(for: unit))
            }
            healthStore.execute(query)
        }
    }

    private func lastNightSleep(now: Date) async -> LastNightSleep.Summary? {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
              let window = LastNightSleep.window(now: now, calendar: calendar)
        else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: window.start, end: window.end, options: [])
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, _ in
                continuation.resume(returning: LastNightSleep.summary(of: SleepStageSample.from(samples), in: window))
            }
            healthStore.execute(query)
        }
    }

    /// Reads 30 days of workouts, not just yesterday's, to tell a rest day
    /// from no signal (`priorDayKcal`). A failed query is no signal.
    private func yesterdayWorkoutKcal(now: Date) async -> Double? {
        let startOfDay = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfDay),
              let monthAgo = calendar.date(byAdding: .day, value: -30, to: startOfDay)
        else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: monthAgo, end: startOfDay, options: [])
        let priorDay = DateInterval(start: yesterday, end: startOfDay)
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                guard error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                let energyType = HKQuantityType(.activeEnergyBurned)
                let workouts = (samples ?? []).compactMap { $0 as? HKWorkout }.map { workout in
                    (start: workout.startDate,
                     kcal: workout.statistics(for: energyType)?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0)
                }
                continuation.resume(returning: Self.priorDayKcal(workouts: workouts, priorDay: priorDay))
            }
            healthStore.execute(query)
        }
    }

    /// Yesterday's workout energy from the past 30 days' workouts. No
    /// workouts yesterday is a rest day, 0 kcal (strain 0, the engine's
    /// full-rest subscore) -- it used to read as a missing signal, so a
    /// rest day could score below a light workout day. No workouts in 30
    /// days is nil: HealthKit hides a denied read as an empty result, and
    /// scoring that as rest every day would invent a signal.
    nonisolated static func priorDayKcal(workouts: [(start: Date, kcal: Double)], priorDay: DateInterval) -> Double? {
        guard !workouts.isEmpty else { return nil }
        return workouts
            .filter { $0.start >= priorDay.start && $0.start < priorDay.end }
            .reduce(0) { $0 + $1.kcal }
    }
}

// MARK: - Score history (UserDefaults ring for the delta caption)

/// The last-30 scored mornings, day-stamped so a same-day refresh replaces
/// instead of duplicating. Mirrors `TodayMetricPreferences`' conventions
/// (DI'd defaults, pure load/record logic testable without them).
@MainActor
struct ReadinessScoreHistory {
    /// `.v2` (WP-59): scores recorded before WP-57 counted a night two
    /// devices recorded twice, so their sleep subscore -- and the score --
    /// differs from today's math. Comparing against them inflated the
    /// "vs 30-day average" caption for a month; the history restarts.
    private static let defaultsKey = "com.healthloom.settings.readinessScores.v2"
    static let retiredDefaultsKey = "com.healthloom.settings.readinessScores"
    // Round-4-sync item 13: fixed format DEMANDS `en_US_POSIX` (a
    // fixed-format formatter under a non-POSIX locale U-turns digits
    // and separators) AND an explicit Gregorian calendar (under a
    // Buddhist/Japanese-calendar host the same formatter emits
    // `2568-…`/`0007-…` keys — duplicate rows plus self-comparison
    // skew after every locale change).
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.removeObject(forKey: Self.retiredDefaultsKey)
    }

    /// 30-day WINDOW, not just 30 entries (round-8 item 14): the delta
    /// caption says "vs 30-day average" — 12 entries scattered over 6
    /// months must not average ~180-day-old scores (the HRV/RHR
    /// `latestQuantity` path already cuts off at 7 days; history never
    /// got one). `yyyy-MM-dd` keys compare chronologically as strings,
    /// so the window is a string bound — no re-parsing, no timezone
    /// drift. The Gregorian calendar is fixed (same host-independence
    /// as the keys themselves).
    private static let gregorian = Calendar(identifier: .gregorian)
    private static let windowDays = 30

    private static func cutoffString(today: Date) -> String {
        // `date(byAdding:)` is total for day units; the fallback is
        // fail-open (include all) on the impossible nil.
        let cutoff = gregorian.date(byAdding: .day, value: -windowDays, to: today) ?? .distantPast
        return dayString(cutoff)
    }

    /// Scores for the engine's `recentScores` (today excluded — the delta
    /// compares against prior mornings, not itself — plus the 30-day
    /// window floor).
    func recentScores(today: Date = Date()) -> [Int] {
        let todayString = Self.dayString(today)
        let cutoff = Self.cutoffString(today: today)
        return Self.load(from: defaults)
            .filter { $0.day != todayString && $0.day >= cutoff }
            .map(\.score)
    }

    func record(score: Int, today: Date = Date()) {
        let todayString = Self.dayString(today)
        let cutoff = Self.cutoffString(today: today)
        // Same-day replace + age prune + 31-entry cap. The cap is 31,
        // not 30 (round-9 item 10): a full 30-day window plus today is
        // 31 rows — capping at 30 drops the oldest IN-WINDOW day, so
        // the average covers 29 while the caption promises 30. The
        // window (not the cap) is the semantic; the cap only bounds a
        // pathological clock (31 rows max, one per day by construction
        // — same-day replaces, so 31 distinct days is the ceiling).
        var entries = Self.load(from: defaults).filter { $0.day != todayString && $0.day >= cutoff }
        entries.append(Entry(day: todayString, score: score))
        defaults.set(Array(entries.suffix(31)).map { [$0.day, String($0.score)] }, forKey: Self.defaultsKey)
    }

    private struct Entry: Equatable {
        var day: String
        var score: Int
    }

    /// Day key, internal so tests pin the Gregorian/POSIX contract
    /// (round-4-sync item 13) without rendering.
    static func dayString(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private static func load(from defaults: UserDefaults) -> [Entry] {
        guard let raw = defaults.array(forKey: defaultsKey) as? [[String]] else { return [] }
        return raw.compactMap { pair in
            guard pair.count == 2, let score = Int(pair[1]) else { return nil }
            return Entry(day: pair[0], score: score)
        }
    }
}
