// KnowledgeDerivation.swift
//
// WP-19 (implementation-plan.md) steps 1-2 / architecture.md D7 ("Each
// derived ProfileField: display text... source... asOf, flags").
//
// Every function here is `nonisolated` and touches nothing but its
// arguments -- no HealthKit, no SwiftData, no wall-clock reads except the
// `now`/`asOf` parameter every caller supplies. This is deliberate (this
// WP's own "Tests" line: "derivation functions with synthetic sample
// arrays... unit-testable without HK") and mirrors SyncKit's established
// pure/impure split (`TypeMapper`'s `decide*` functions vs `MappedObject`'s
// HealthKit-touching half).
//
// Returns `nil` (never a "No data" `ProfileField`) when there is nothing to
// derive: an absent field is `ContextAssembler`'s (WP-20) and the profile
// UI's signal that a fact isn't known yet, not a fact whose value is "none."

import CoreModel
import Foundation
import SyncKit

public enum KnowledgeDerivation {
    // MARK: - Key prefixes
    //
    // Shared with `ContextAssembler.priorityRank(for:)` (WP-20): the rank
    // function matches on these prefixes rather than its own literals, and
    // every key below is composed from them, so renaming a prefix breaks the
    // composition site at compile time instead of silently demoting a field
    // to rank 3 ("history") at trim time. Code review (WP-20 round 1) #6.

    public static let stepsKeyPrefix = "steps."
    public static let vitalsKeyPrefix = "vitals."
    public static let sleepKeyPrefix = "sleep."
    public static let activityKeyPrefix = "activity."
    public static let clinicalKeyPrefix = "clinical."

    // MARK: - Steps

    public static let stepsFieldKey = stepsKeyPrefix + "dailyAverage"

    /// "~8,240 steps/day (30-day avg)" -- architecture.md D7's own example
    /// text. Average is over days that have *any* data, not the window
    /// length, so a partial history (new user, mid-backfill) isn't diluted by
    /// zero-filled days it never had a chance to record.
    public static func stepsField(
        dailyValues: [DailyQuantityValue],
        windowDays: Int,
        asOf: Date,
        source: String,
        locale: Locale = .current
    ) -> ProfileField? {
        guard !dailyValues.isEmpty else { return nil }
        let average = dailyValues.reduce(0.0) { $0 + $1.value } / Double(dailyValues.count)
        let text = "~\(groupedCount(average, locale: locale)) steps/day (\(windowDays)-day avg)"
        return ProfileField(key: stepsFieldKey, displayText: text, source: source, asOf: asOf)
    }

    // MARK: - Vitals (resting heart rate, HRV)

    public static let restingHeartRateFieldKey = vitalsKeyPrefix + "restingHeartRate"
    public static let heartRateVariabilityFieldKey = vitalsKeyPrefix + "heartRateVariability"

    /// Trend threshold: ±5% around the window's own average counts as
    /// "steady." A starting point, not a tuned constant -- same "beta-tunable
    /// constant table" posture as architecture.md D13's overlap thresholds
    /// (open question #3); `ReadinessEngine` (WP-23) owns the real scoring
    /// math this text only describes in prose.
    private static let trendSteadyBand = 0.05

    /// "Resting HR ~58 bpm (30-day avg); latest 55 bpm, steady with your baseline."
    public static func restingHeartRateField(
        readings: [QuantityReading],
        windowDays: Int,
        asOf: Date,
        source: String,
        locale: Locale = .current
    ) -> ProfileField? {
        vitalsField(
            key: restingHeartRateFieldKey,
            label: "Resting HR",
            unit: "bpm",
            readings: readings,
            windowDays: windowDays,
            asOf: asOf,
            source: source,
            locale: locale,
            valueFormatter: { groupedCount($0, locale: locale) }
        )
    }

    /// "HRV (SDNN) ~42 ms (30-day baseline); latest 47 ms, higher than your baseline."
    public static func heartRateVariabilityField(
        readings: [QuantityReading],
        windowDays: Int,
        asOf: Date,
        source: String,
        locale: Locale = .current
    ) -> ProfileField? {
        vitalsField(
            key: heartRateVariabilityFieldKey,
            label: "HRV (SDNN)",
            unit: "ms",
            readings: readings,
            windowDays: windowDays,
            asOf: asOf,
            source: source,
            locale: locale,
            valueFormatter: { groupedCount($0, locale: locale) },
            baselineNoun: "baseline"
        )
    }

    private static func vitalsField(
        key: String,
        label: String,
        unit: String,
        readings: [QuantityReading],
        windowDays: Int,
        asOf: Date,
        source: String,
        locale: Locale,
        valueFormatter: (Double) -> String,
        baselineNoun: String = "avg"
    ) -> ProfileField? {
        guard !readings.isEmpty else { return nil }
        let baseline = readings.reduce(0.0) { $0 + $1.value } / Double(readings.count)
        let latest = readings.max { $0.date < $1.date }!
        let ratio = baseline == 0 ? 1 : latest.value / baseline
        let trendWord: String
        if ratio > 1 + trendSteadyBand {
            trendWord = "higher than"
        } else if ratio < 1 - trendSteadyBand {
            trendWord = "lower than"
        } else {
            trendWord = "steady with"
        }
        let text = "\(label) ~\(valueFormatter(baseline)) \(unit) (\(windowDays)-day \(baselineNoun)); "
            + "latest \(valueFormatter(latest.value)) \(unit), \(trendWord) your baseline."
        return ProfileField(key: key, displayText: text, source: source, asOf: asOf)
    }

    // MARK: - Sleep

    public static let sleepDurationFieldKey = sleepKeyPrefix + "duration"
    public static let sleepStageSplitFieldKey = sleepKeyPrefix + "stageSplit"

    /// Segments belong to the night that started the evening before their
    /// start time -- a segment starting anywhere from noon on day D through
    /// noon on day D+1 buckets to "night of D" (subtract 12h, then take
    /// `startOfDay`). Wide enough for any real bedtime/wake time, and stable
    /// across the one DST-shift hour twice a year.
    static func nightKey(for date: Date, calendar: Calendar) -> Date {
        let shifted = calendar.date(byAdding: .hour, value: -12, to: date) ?? date
        return calendar.startOfDay(for: shifted)
    }

    /// Two fields: total asleep duration (avg per night, over nights with
    /// any data) and stage-split percentages (of total asleep time). Returns
    /// both, or neither -- there's no meaningful stage split without a
    /// duration to split.
    public static func sleepFields(
        segments: [SleepStageSegment],
        nights: Int,
        asOf: Date,
        source: String,
        calendar: Calendar = .current
    ) -> [ProfileField] {
        guard !segments.isEmpty else { return [] }
        let byNight = Dictionary(grouping: segments) { nightKey(for: $0.start, calendar: calendar) }
        let nightlyTotals = byNight.mapValues { $0.reduce(0.0) { $0 + $1.duration } }
        guard !nightlyTotals.isEmpty else { return [] }
        let averageSeconds = nightlyTotals.values.reduce(0, +) / Double(nightlyTotals.count)

        let durationField = ProfileField(
            key: sleepDurationFieldKey,
            displayText: "~\(duration(seconds: averageSeconds)) asleep/night (\(nights)-night avg, "
                + "\(nightlyTotals.count) night\(nightlyTotals.count == 1 ? "" : "s") recorded)",
            source: source,
            asOf: asOf
        )

        let totalAsleep = segments.reduce(0.0) { $0 + $1.duration }
        guard totalAsleep > 0 else { return [durationField] }
        let rawPercentages = SleepStageKind.allCases.compactMap { stage -> (SleepStageKind, Double)? in
            let stageTotal = segments.filter { $0.stage == stage }.reduce(0.0) { $0 + $1.duration }
            guard stageTotal > 0 else { return nil }
            return (stage, stageTotal / totalAsleep * 100)
        }
        guard !rawPercentages.isEmpty else { return [durationField] }
        let percentages = largestRemainderRounding(rawPercentages)
        let breakdown = percentages
            .sorted { $0.1 > $1.1 }
            .map { "\($1)% \(displayName(for: $0))" }
            .joined(separator: ", ")
        let stageField = ProfileField(
            key: sleepStageSplitFieldKey,
            displayText: "Sleep stages: \(breakdown)",
            source: source,
            asOf: asOf
        )
        return [durationField, stageField]
    }

    private static func displayName(for stage: SleepStageKind) -> String {
        switch stage {
        case .unspecified: return "unspecified"
        case .core: return "core"
        case .deep: return "deep"
        case .rem: return "REM"
        }
    }

    /// Code review (2026-08-28) finding #13: rounding each stage's
    /// percentage independently (`Int(x.rounded())`) can make the displayed
    /// breakdown sum to 99% or 101% (e.g. 33.4/33.3/33.3, or 24.5/37.8/37.7).
    /// The largest-remainder method fixes every value to its floor, then
    /// distributes the shortfall (`100 - sum of floors`, always in
    /// `0..<count` since each floor loses less than 1) one point at a time to
    /// the entries with the largest fractional remainder -- the standard
    /// apportionment technique that guarantees integer percentages summing to
    /// exactly 100 whenever the inputs themselves sum to (approximately) 100.
    static func largestRemainderRounding<T>(_ raw: [(T, Double)]) -> [(T, Int)] {
        guard !raw.isEmpty else { return [] }
        var entries = raw.map { (key: $0.0, floor: Int($0.1), remainder: $0.1 - Double(Int($0.1))) }
        let shortfall = 100 - entries.reduce(0) { $0 + $1.floor }
        let byRemainderDescending = entries.indices.sorted { entries[$0].remainder > entries[$1].remainder }
        for index in byRemainderDescending.prefix(max(shortfall, 0)) {
            entries[index].floor += 1
        }
        return entries.map { ($0.key, $0.floor) }
    }

    // MARK: - Workouts (architecture.md D13.6: merge linked Fitbit supplements,
    // never describing both copies of one activity)

    public static let workoutsFieldKey = activityKeyPrefix + "workouts"

    /// One HealthKit workout is one activity, full stop -- `exerciseSupplements`
    /// only ever *adds* to the count when a supplement links to no workout in
    /// `workouts` (a deferred session whose watch workout isn't currently
    /// readable -- D13.2's "surfaces standalone rather than vanishing," in
    /// prose form here). A supplement linked to a counted workout contributes
    /// nothing extra: that would be describing the same activity twice.
    public static func workoutsField(
        workouts: [WorkoutRecord],
        exerciseSupplements: [ExerciseSupplement],
        windowDays: Int,
        asOf: Date,
        source: String
    ) -> ProfileField? {
        let workoutIDs = Set(workouts.map(\.id))
        let unlinkedSupplements = exerciseSupplements.filter { supplement in
            guard let linked = supplement.linkedWatchWorkoutUUID else { return true }
            return !workoutIDs.contains(linked)
        }
        let totalCount = workouts.count + unlinkedSupplements.count
        guard totalCount > 0 else { return nil }

        var byName: [String: Int] = [:]
        for workout in workouts { byName[workout.activityName, default: 0] += 1 }
        let breakdown = byName
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { "\($0.value)\u{00D7} \($0.key)" }
            .joined(separator: ", ")

        var text = "\(totalCount) workout\(totalCount == 1 ? "" : "s") in the last \(windowDays) days"
        if !breakdown.isEmpty {
            text += ": \(breakdown)"
        }
        if !unlinkedSupplements.isEmpty {
            // Code review (2026-08-28) finding #11: name the *actual* source
            // device, never a hardcoded "Fitbit" -- `LocalSample.source` is a
            // free-text label, not type-restricted to Fitbit. When every
            // unlinked supplement shares one source, name it; a genuinely
            // mixed set (multiple importers) falls back to a generic word
            // rather than asserting any single one of them.
            let sources = Set(unlinkedSupplements.map(\.source))
            let sourceLabel = sources.count == 1 ? sources.first! : "other"
            text += "; plus \(unlinkedSupplements.count) \(sourceLabel) session"
                + "\(unlinkedSupplements.count == 1 ? "" : "s") not currently linked to a watch workout"
        }
        text += "."
        return ProfileField(key: workoutsFieldKey, displayText: text, source: source, asOf: asOf)
    }

    // MARK: - LocalSample-only types (architecture.md D2/D8; WP-19 step 1:
    // "clinical types only produce isClinical fields")

    /// One field per `.localOnly`-writability `GoogleDataType` that has at
    /// least one sample in `[windowStart, now]`. Clinical types (ECG,
    /// Irregular Rhythm Notification -- `isClinicalType`, SyncKit) produce a
    /// **presence-only** field: a count and a pointer to the Health app,
    /// never an aggregated value -- the minimization architecture.md D8 asks
    /// for applied one layer earlier than the AI-context exclusion itself.
    /// Non-clinical local types (Active Zone Minutes, Active Minutes) get a
    /// real aggregated value via `sumPayloadValues`.
    public static func localOnlyField(
        dataType: GoogleDataType,
        samples: [LocalSample],
        windowStart: Date,
        windowDays: Int,
        asOf: Date
    ) -> ProfileField? {
        // Code review (2026-08-28) finding #9: upper-bound against `asOf` too
        // -- a future-dated sample (device clock skew during import) must
        // age out like any other, not match `start >= windowStart` forever.
        let matching = samples.filter {
            $0.dataType == dataType.rawValue && $0.start >= windowStart && $0.start <= asOf
        }
        guard !matching.isEmpty else { return nil }
        // Code review (2026-08-28) finding #12: `samples`' order is whatever
        // the caller's fetch returned (SwiftData gives no ordering guarantee)
        // -- `.first` would make the displayed device label flip
        // nondeterministically across refreshes for unchanged data. Picking
        // the most-recent sample's source is both deterministic (a pure
        // function of the input set, independent of array order) and
        // meaningful (the freshest device wins display).
        //
        // Code review (2026-09-01): `start` alone isn't a strict ordering --
        // two samples sharing an exact `start` (a batch re-sync) tied under
        // plain `max(by: { $0.start < $1.start })`, and Swift's `max(by:)`
        // breaks a tie by array traversal order, not "independent of array
        // order" as the paragraph above claims. `externalID` is
        // `@Attribute(.unique)` (LocalSample.swift), so pairing it in as a
        // secondary key makes the comparator a true strict ordering with no
        // remaining ties -- genuinely order-independent, not just usually so.
        let deviceLabel = matching.max { ($0.start, $0.externalID) < ($1.start, $1.externalID) }?.source ?? "unknown"
        let source = "LocalSample \u{00B7} \(deviceLabel)"
        let name = localOnlyDisplayName(dataType)

        if isClinicalType(dataType) {
            let text = "\(matching.count) \(name) record\(matching.count == 1 ? "" : "s") "
                + "in the last \(windowDays) days \u{2014} view in the Health app."
            return ProfileField(
                key: clinicalKeyPrefix + dataType.rawValue,
                displayText: text,
                source: source,
                asOf: asOf,
                isClinical: true
            )
        }

        let total = matching.reduce(0.0) { $0 + sumPayloadValues($1) }
        // Both non-clinical `.localOnly` types (Active Zone Minutes, Active
        // Minutes) are themselves minutes-denominated -- avoid "Active Zone
        // Minutes minutes."
        let unitSuffix = name.hasSuffix("Minutes") ? "" : " minutes"
        // Code review (2026-09-01): `sumPayloadValues` is deliberately
        // unbounded (its own doc comment: sums every numeric value present,
        // "would only overcount, never throw") -- but `Int(total.rounded())`
        // itself traps if a corrupted/malformed payload's sum ever exceeds
        // `Int`'s range. Clamping here, at the one place that converts to
        // `Int`, keeps that "never throw" contract true end to end.
        let safeTotal = total.isFinite ? min(max(total, 0), 1_000_000_000) : 0
        let text = "~\(Int(safeTotal.rounded())) \(name)\(unitSuffix) in the last \(windowDays) days."
        return ProfileField(key: activityKeyPrefix + dataType.rawValue, displayText: text, source: source, asOf: asOf)
    }

    private static func localOnlyDisplayName(_ type: GoogleDataType) -> String {
        switch type {
        case .electrocardiogram: return "ECG"
        case .activeZoneMinutes: return "Active Zone Minutes"
        case .activeMinutes: return "Active Minutes"
        case .irregularRhythmNotification: return "Irregular Rhythm Notification"
        default: return type.rawValue
        }
    }

    // MARK: - Formatting (pure, locale-injectable -- same shape as the app
    // target's `TodayMetricFormatter`, WP-33)

    static func groupedCount(_ value: Double, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value.rounded()))"
    }

    static func duration(seconds: Double) -> String {
        // Code review (2026-09-01): clamp to 0 -- a `SleepStageSegment` with
        // `end < start` (clock-skewed/malformed HealthKit data) would
        // otherwise produce a negative `totalMinutes`, and Swift's
        // truncating `/`/`%` on a negative dividend yields nonsensical
        // coach-facing text (e.g. a -25 hour skew rendering as "0m" instead
        // of anything indicating a problem).
        let totalMinutes = max(Int((seconds / 60).rounded()), 0)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}
