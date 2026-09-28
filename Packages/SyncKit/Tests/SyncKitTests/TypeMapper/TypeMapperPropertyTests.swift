// TypeMapperPropertyTests.swift
//
// WP-07/WP-11/WP-12/WP-13 (implementation-plan.md) "Tests:" line: "property
// test: mapping never produces a sample with end < start"; "fraction-typed
// outputs stay 0...1" (WP-11 -- SpO2/body-fat). Per WP-11's explicit
// instruction ("extend WP-07's existing property test to cover the new
// types, don't write a separate one"), `neverEmitsSampleWithEndBeforeStart`
// below now exercises all nineteen implemented `.healthKit` rows (the four
// P0 types, WP-11's thirteen, WP-12's Exercise -> `.workout`, and WP-13's
// Nutrition Log -> `.correlation`), not a second, parallel test suite.

import CoreModel
import Foundation
import GoogleHealthClient
import Testing
@testable import SyncKit

@Suite struct TypeMapperPropertyTests {
    /// Exercises all four P0 decision paths across a spread of start/end
    /// windows -- a normal interval, a zero-length instant, and a
    /// deliberately reversed pair -- confirming that whenever `decide(_:)`
    /// *does* emit a `.quantity`/`.category` sample, every one of its dates
    /// satisfies `end >= start`. A reversed window is expected to produce
    /// `.skip`/`.localOnly` for these four types (each guards `point.end >=
    /// point.start` up front); this test doesn't hardcode that as a
    /// per-type assumption, it simply never accepts an emitted sample that
    /// violates the invariant, however it got there.
    @Test(
        arguments: [
            ("2026-07-01T00:00:00Z", "2026-07-01T01:00:00Z"), // normal interval
            ("2026-07-01T00:00:00Z", "2026-07-01T00:00:00Z"), // instant (zero-length, allowed)
            ("2026-07-01T01:00:00Z", "2026-07-01T00:00:00Z"), // reversed (must never be emitted)
        ]
    )
    func neverEmitsSampleWithEndBeforeStart(window: (String, String)) {
        let start = TypeMapperFixtures.date(window.0)
        let end = TypeMapperFixtures.date(window.1)

        let decisions: [MappedDecision] = [
            TypeMapper.decide(TypeMapperFixtures.stepsPoint(start: start, end: end)),
            TypeMapper.decide(TypeMapperFixtures.heartRatePoint(start: start, end: end)),
            TypeMapper.decide(TypeMapperFixtures.weightPoint(start: start, end: end)),
            TypeMapper.decide(TypeMapperFixtures.sleepPoint(start: start, end: end)),
            // WP-11 additions:
            TypeMapper.decide(TypeMapperFixtures.distancePoint(start: start, end: end)),
            TypeMapper.decide(TypeMapperFixtures.floorsPoint(start: start, end: end)),
            TypeMapper.decide(TypeMapperFixtures.activeEnergyBurnedPoint(start: start, end: end)),
            TypeMapper.decide(TypeMapperFixtures.restingHeartRatePoint(start: start, end: end)),
            TypeMapper.decide(TypeMapperFixtures.heartRateVariabilityPoint(start: start, end: end)),
            TypeMapper.decide(TypeMapperFixtures.oxygenSaturationPoint(start: start, end: end)),
            TypeMapper.decide(TypeMapperFixtures.respiratoryRatePoint(start: start, end: end)),
            TypeMapper.decide(TypeMapperFixtures.vo2MaxPoint(start: start, end: end)),
            TypeMapper.decide(TypeMapperFixtures.heightPoint(start: start, end: end)),
            TypeMapper.decide(TypeMapperFixtures.bodyFatPoint(start: start, end: end)),
            TypeMapper.decide(TypeMapperFixtures.bloodGlucoseMgDLPoint(start: start, end: end)),
            TypeMapper.decide(TypeMapperFixtures.bloodGlucoseMmolLPoint(start: start, end: end)),
            TypeMapper.decide(TypeMapperFixtures.coreBodyTemperaturePoint(start: start, end: end)),
            TypeMapper.decide(TypeMapperFixtures.hydrationPoint(start: start, end: end)),
            // WP-12 addition:
            TypeMapper.decide(TypeMapperFixtures.exercisePoint(start: start, end: end)),
            // WP-13 addition:
            TypeMapper.decide(TypeMapperFixtures.nutritionLogPoint(start: start, end: end)),
        ]

        for decision in decisions {
            switch decision {
            case .quantity(let sample):
                #expect(sample.end >= sample.start)
            case .category(let segments):
                for segment in segments {
                    #expect(segment.end >= segment.start)
                }
            case .workout(let workout):
                #expect(workout.end >= workout.start)
            case .correlation(let meal):
                #expect(meal.end >= meal.start)
                for constituent in meal.constituents {
                    #expect(constituent.end >= constituent.start)
                }
            case .localOnly, .skip:
                continue
            }
        }
    }

    /// A reversed window is never merely "clamped into shape" -- it must be
    /// dropped, for every P0 and WP-11 type, and HRV since WP-62 wrote it.
    @Test func reversedWindowIsAlwaysDropped() {
        let start = TypeMapperFixtures.date("2026-07-01T01:00:00Z")
        let end = TypeMapperFixtures.date("2026-07-01T00:00:00Z")

        #expect(TypeMapper.decide(TypeMapperFixtures.stepsPoint(start: start, end: end)) == .skip)
        #expect(TypeMapper.decide(TypeMapperFixtures.heartRatePoint(start: start, end: end)) == .skip)
        #expect(TypeMapper.decide(TypeMapperFixtures.weightPoint(start: start, end: end)) == .skip)
        #expect(TypeMapper.decide(TypeMapperFixtures.sleepPoint(start: start, end: end)) == .skip)
        #expect(TypeMapper.decide(TypeMapperFixtures.distancePoint(start: start, end: end)) == .skip)
        #expect(TypeMapper.decide(TypeMapperFixtures.floorsPoint(start: start, end: end)) == .skip)
        #expect(TypeMapper.decide(TypeMapperFixtures.activeEnergyBurnedPoint(start: start, end: end)) == .skip)
        #expect(TypeMapper.decide(TypeMapperFixtures.restingHeartRatePoint(start: start, end: end)) == .skip)
        #expect(TypeMapper.decide(TypeMapperFixtures.heartRateVariabilityPoint(start: start, end: end)) == .skip)
        #expect(TypeMapper.decide(TypeMapperFixtures.oxygenSaturationPoint(start: start, end: end)) == .skip)
        #expect(TypeMapper.decide(TypeMapperFixtures.respiratoryRatePoint(start: start, end: end)) == .skip)
        #expect(TypeMapper.decide(TypeMapperFixtures.vo2MaxPoint(start: start, end: end)) == .skip)
        #expect(TypeMapper.decide(TypeMapperFixtures.heightPoint(start: start, end: end)) == .skip)
        #expect(TypeMapper.decide(TypeMapperFixtures.bodyFatPoint(start: start, end: end)) == .skip)
        #expect(TypeMapper.decide(TypeMapperFixtures.bloodGlucoseMgDLPoint(start: start, end: end)) == .skip)
        #expect(TypeMapper.decide(TypeMapperFixtures.bloodGlucoseMmolLPoint(start: start, end: end)) == .skip)
        #expect(TypeMapper.decide(TypeMapperFixtures.coreBodyTemperaturePoint(start: start, end: end)) == .skip)
        #expect(TypeMapper.decide(TypeMapperFixtures.hydrationPoint(start: start, end: end)) == .skip)
        #expect(TypeMapper.decide(TypeMapperFixtures.exercisePoint(start: start, end: end)) == .skip)
        #expect(TypeMapper.decide(TypeMapperFixtures.nutritionLogPoint(start: start, end: end)) == .skip)
    }

    /// WP-11's required property test: "SpO2/body-fat outputs are always in
    /// 0...1." Exercised across a spread of *valid* wire-percentage inputs
    /// (0, a normal mid-range reading, and 100, the two boundary values plus
    /// one interior point) -- every one of them must decode to a
    /// `MappedUnit.fraction` sample whose `value` is in `0...1`, and every
    /// such sample's unit must actually be `.fraction` (never accidentally
    /// left as a raw percentage in some other unit).
    @Test(arguments: [0.0, 22.0, 55.5, 97.0, 100.0])
    func fractionOutputsAlwaysStayInUnitInterval(percentage: Double) {
        let decisions: [MappedDecision] = [
            TypeMapper.decide(TypeMapperFixtures.oxygenSaturationPoint(percentage: percentage)),
            TypeMapper.decide(TypeMapperFixtures.bodyFatPoint(percentage: percentage)),
        ]
        for decision in decisions {
            guard case .quantity(let sample) = decision else {
                Issue.record("expected .quantity for a valid 0...100 percentage input")
                continue
            }
            #expect(sample.unit == .fraction)
            #expect((0.0...1.0).contains(sample.value))
        }
    }

    /// An out-of-range wire percentage (negative, or > 100 -- clearly not a
    /// percentage at all) must never be force-converted into an
    /// out-of-bounds fraction; it's dropped instead, preserving the 0...1
    /// invariant by construction rather than by clamping.
    @Test(arguments: [-5.0, -0.01, 100.01, 250.0])
    func outOfRangePercentageIsDroppedNotClamped(percentage: Double) {
        #expect(TypeMapper.decide(TypeMapperFixtures.oxygenSaturationPoint(percentage: percentage)) == .skip)
        #expect(TypeMapper.decide(TypeMapperFixtures.bodyFatPoint(percentage: percentage)) == .skip)
    }
}
