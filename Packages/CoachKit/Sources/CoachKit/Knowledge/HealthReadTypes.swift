// HealthReadTypes.swift
//
// WP-19 (implementation-plan.md) / architecture.md D7 ("KnowledgeStore reads
// HealthKit... never a raw dump"). Plain, HealthKit-free value types the read
// layer (HealthReadStore.swift) returns and the pure derivation layer
// (KnowledgeDerivation.swift) consumes -- the same pure/impure split SyncKit
// established (`HealthStoreProtocol` vs `HealthKitWriter`, `WatchCoverageIndex`
// vs `WatchCoverageProvider`): everything here is `Sendable`/`Codable`-free of
// HealthKit imports, so derivation is unit-testable with synthetic arrays and
// no HealthKit entitlement, per this WP's own "Tests" line.
//
// `nonisolated` on every type below (WP-12b's precedent, SyncKit's
// `MappedMetadata`/`MappedQuantitySample` et al., MappedTypes.swift):
// CoachKit's package-wide `.defaultIsolation(MainActor.self)` would
// otherwise make each initializer MainActor-isolated, which breaks
// construction from the `nonisolated` HealthKit-query completion closures in
// HealthReadStore.swift.

import Foundation

/// One day's cumulative total for a quantity type (e.g. steps), bucketed to
/// the reading calendar's start-of-day.
nonisolated public struct DailyQuantityValue: Sendable, Hashable {
    public let day: Date
    public let value: Double

    public init(day: Date, value: Double) {
        self.day = day
        self.value = value
    }
}

/// One discrete quantity reading (e.g. a daily resting-HR average) at a
/// point in time -- used for trend/baseline math over vitals that are not
/// naturally cumulative.
nonisolated public struct QuantityReading: Sendable, Hashable {
    public let date: Date
    public let value: Double

    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

/// `HKCategoryValueSleepAnalysis`'s asleep-stage cases, reduced to what
/// derivation needs -- deliberately excludes `inBed`/`awake` (never counted
/// toward sleep duration, matching `TodayMetricsProvider`'s asleep-value set
/// and `MappedSleepStage`'s precedent).
nonisolated public enum SleepStageKind: String, Sendable, Hashable, Codable, CaseIterable {
    case unspecified
    case core
    case deep
    case rem
}

/// One sleep-stage segment, already stage-classified and clamped to a single
/// night's data by the caller.
nonisolated public struct SleepStageSegment: Sendable, Hashable {
    public let start: Date
    public let end: Date
    public let stage: SleepStageKind

    public init(start: Date, end: Date, stage: SleepStageKind) {
        self.start = start
        self.end = end
        self.stage = stage
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// One workout, reduced to what derivation needs to describe it in prose.
/// Deliberately carries a stable identity (`HKWorkout.uuid`) so derivation can
/// match it against a linked Fitbit `LocalSample` supplement (architecture.md
/// D13.6) without re-touching HealthKit.
nonisolated public struct WorkoutRecord: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let start: Date
    public let end: Date
    public let activityName: String
    public let totalEnergyKilocalories: Double?
    public let totalDistanceMeters: Double?

    public init(
        id: UUID,
        start: Date,
        end: Date,
        activityName: String,
        totalEnergyKilocalories: Double?,
        totalDistanceMeters: Double?
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.activityName = activityName
        self.totalEnergyKilocalories = totalEnergyKilocalories
        self.totalDistanceMeters = totalDistanceMeters
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}
