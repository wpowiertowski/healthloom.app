// ContextAssemblerTests.swift
//
// WP-20 "Tests" line: exclusion honored (excluded string never appears in
// serialized context -- substring assert); clinical default-out/opt-in;
// budget trimming order; snapshot ID round-trip.

@testable import CoachKit
import CoreModel
import Foundation
import SwiftData
import Testing

@MainActor
private func makeAssembler(sections: [ProfileField] = []) throws -> (ContextAssembler, ModelContainer) {
    let container = try CoreModel.makeContainer(inMemory: true)
    if !sections.isEmpty {
        let context = ModelContext(container)
        context.insert(KnowledgeProfile(sections: sections))
        try context.save()
    }
    return (ContextAssembler(modelContainer: container), container)
}

@MainActor
private func field(
    _ key: String,
    _ displayText: String,
    excluded: Bool? = nil,
    clinical: Bool = false
) -> ProfileField {
    ProfileField(
        key: key,
        displayText: displayText,
        source: "HealthKit",
        asOf: Date(timeIntervalSince1970: 1_700_000_000),
        excludedFromAI: excluded,
        isClinical: clinical
    )
}

@Suite("ContextAssembler filtering (D7/D8)")
@MainActor
struct ContextAssemblerFilteringTests {
    @Test("excluded fields never reach the context or its serialized snapshot")
    func exclusionHonored() throws {
        let sentinel = "zxq-sentinel-excluded-\(UUID().uuidString)"
        let (assembler, container) = try makeAssembler(sections: [
            field("steps.dailyAverage", "~8,200 steps/day (30-day avg)"),
            field("user.goal", sentinel, excluded: true),
        ])

        let assembled = try assembler.assemble(for: .chat)
        #expect(assembled.context.fields.allSatisfy { !$0.excludedFromAI })
        #expect(!assembled.context.fields.contains { $0.key == "user.goal" })

        // Substring assert over the exact bytes handed to the provider: the
        // excluded string must appear nowhere in the serialized snapshot.
        let snapshots = try ModelContext(container).fetch(FetchDescriptor<ContextSnapshot>())
        #expect(snapshots.count == 1)
        let serialized = String(data: snapshots[0].json, encoding: .utf8) ?? ""
        #expect(!serialized.contains(sentinel))
        #expect(serialized.contains("8,200"))
    }

    @Test("clinical fields stay out by default")
    func clinicalDefaultOut() throws {
        let (assembler, _) = try makeAssembler(sections: [
            field("clinical.electrocardiogram", "1 ECG record in the last 7 days", clinical: true),
            field("steps.dailyAverage", "~8,200 steps/day (30-day avg)"),
        ])

        let assembled = try assembler.assemble(for: .chat)
        #expect(!assembled.context.fields.contains { $0.isClinical })
        #expect(assembled.context.fields.contains { $0.key == "steps.dailyAverage" })
    }

    @Test("an explicitly opted-in clinical field is included")
    func clinicalOptIn() throws {
        let (assembler, _) = try makeAssembler(sections: [
            field(
                "clinical.irregularRhythmNotification",
                "1 Irregular Rhythm Notification record in the last 7 days",
                excluded: false,
                clinical: true
            ),
        ])

        let assembled = try assembler.assemble(for: .dailyInsight)
        #expect(assembled.context.fields.count == 1)
        #expect(assembled.context.fields[0].isClinical)
    }
}

@Suite("ContextAssembler budget trimming")
@MainActor
struct ContextAssemblerTrimmingTests {
    @Test("fields trim vitals-first regardless of profile order")
    func trimmingOrder() throws {
        // Seeded lowest-priority-first on purpose: trimming must reorder by
        // rank, not profile position.
        let vitals = field("vitals.restingHeartRate", "Resting HR ~58 bpm (30-day avg)")
        let sleep = field("sleep.duration", "7h 12m avg (14 nights)")
        let steps = field("steps.dailyAverage", "~8,200 steps/day (30-day avg)")
        let workouts = field("activity.workouts", "3 workouts in the last 30 days")
        let goal = field("user.goal", "Run a 10K in spring")
        let all = [goal, workouts, steps, sleep, vitals]
        let (assembler, _) = try makeAssembler(sections: all)

        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let locale = Locale(identifier: "en_US")
        let shell = ContextAssembler.estimatedShellTokens(
            localeIdentifier: "en_US",
            unitSystem: .imperial,
            today: now
        )
        let twoHighestCost = ContextAssembler.estimatedTokens(for: [vitals, sleep])
        let assembled = try assembler.assemble(
            for: .chat,
            now: now,
            locale: locale,
            tokenBudget: shell + twoHighestCost
        )

        #expect(assembled.didTrim)
        #expect(assembled.context.fields.map(\.key) == ["vitals.restingHeartRate", "sleep.duration"])
        #expect(assembled.estimatedTokens == shell + twoHighestCost)
    }

    @Test("priority rank tracks KnowledgeDerivation's keys")
    func rankTracksDerivationKeys() throws {
        #expect(ContextAssembler.priorityRank(for: KnowledgeDerivation.restingHeartRateFieldKey) == 0)
        #expect(ContextAssembler.priorityRank(for: KnowledgeDerivation.heartRateVariabilityFieldKey) == 0)
        #expect(ContextAssembler.priorityRank(for: KnowledgeDerivation.sleepDurationFieldKey) == 1)
        #expect(ContextAssembler.priorityRank(for: KnowledgeDerivation.sleepStageSplitFieldKey) == 1)
        #expect(ContextAssembler.priorityRank(for: KnowledgeDerivation.stepsFieldKey) == 2)
        #expect(ContextAssembler.priorityRank(for: KnowledgeDerivation.workoutsFieldKey) == 2)
    }

    @Test("a fitting budget keeps everything in rank order, untrimmed")
    func fittingBudgetKeepsAll() throws {
        let sections = [
            field("activity.workouts", "3 workouts in the last 30 days"),
            field("vitals.restingHeartRate", "Resting HR ~58 bpm (30-day avg)"),
        ]
        let (assembler, _) = try makeAssembler(sections: sections)

        let assembled = try assembler.assemble(for: .chat, tokenBudget: .max)
        #expect(!assembled.didTrim)
        #expect(assembled.context.fields.map(\.key) == ["vitals.restingHeartRate", "activity.workouts"])
    }

    @Test("a too-big top field is kept alone, never jumped by a smaller lower field")
    func topFieldNeverJumped() throws {
        let vitals = field("vitals.restingHeartRate", String(repeating: "x", count: 400))
        let sleep = field("sleep.duration", "7h 12m avg")
        let (assembler, _) = try makeAssembler(sections: [vitals, sleep])
        #expect(ContextAssembler.estimatedTokens(for: [vitals]) > ContextAssembler.estimatedTokens(for: [sleep]))

        let assembled = try assembler.assemble(
            for: .chat,
            tokenBudget: ContextAssembler.estimatedTokens(for: [sleep])
        )
        #expect(assembled.context.fields.map(\.key) == ["vitals.restingHeartRate"])
        #expect(assembled.didTrim)
    }

    @Test("a lone over-budget field is kept but still reports overflow")
    func loneOverBudgetReportsTrim() throws {
        let big = field("vitals.restingHeartRate", String(repeating: "y", count: 400))
        let (assembler, _) = try makeAssembler(sections: [big])

        let assembled = try assembler.assemble(
            for: .chat,
            tokenBudget: ContextAssembler.estimatedTokens(for: [big])
        )
        #expect(assembled.context.fields.map(\.key) == ["vitals.restingHeartRate"])
        #expect(assembled.didTrim)
    }

    @Test("selection total equals one batched estimate over the kept set")
    func singleFormula() throws {
        let sections = [
            field("user.goal", "Run a 10K in spring"),
            field("activity.workouts", "3 workouts in the last 30 days"),
            field("sleep.duration", "7h 12m avg (14 nights)"),
            field("vitals.restingHeartRate", "Resting HR ~58 bpm (30-day avg)"),
        ]
        let selection = ContextAssembler.selectFields(from: sections, tokenBudget: .max)
        #expect(!selection.didTrim)
        #expect(selection.estimatedTokens == ContextAssembler.estimatedTokens(for: selection.kept))
    }

    @Test("a zero budget still keeps the single highest-priority field and reports overflow")
    func zeroBudgetKeepsOne() throws {
        let (assembler, _) = try makeAssembler(sections: [
            field("user.goal", "Run a 10K in spring"),
            field("sleep.duration", "7h 12m avg (14 nights)"),
        ])

        let assembled = try assembler.assemble(for: .chat, tokenBudget: 0)
        #expect(assembled.context.fields.map(\.key) == ["sleep.duration"])
        #expect(assembled.didTrim)
    }
}

@Suite("ContextAssembler snapshot persistence")
@MainActor
struct ContextAssemblerSnapshotTests {
    @Test("every assembly persists a ContextSnapshot a ChatTurn can link to")
    func snapshotIDRoundTrip() throws {
        let (assembler, container) = try makeAssembler(sections: [
            field("steps.dailyAverage", "~8,200 steps/day (30-day avg)"),
        ])

        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let assembled = try assembler.assemble(for: .chat, now: now)

        // The exact bytes handed out decode back to the exact struct: the
        // trace UI renders what was sent, never a reconstruction.
        let context = ModelContext(container)
        let snapshots = try context.fetch(FetchDescriptor<ContextSnapshot>())
        #expect(snapshots.count == 1)
        #expect(snapshots[0].id == assembled.snapshotID)
        #expect(snapshots[0].createdAt == now)
        let decoded = try JSONDecoder().decode(HealthContext.self, from: snapshots[0].json)
        #expect(decoded == assembled.context)

        // WP-32's future join key works end to end: an assistant turn links
        // the snapshot ID, and the link resolves.
        let turn = ChatTurn(role: "assistant", content: "Nice week.", contextSnapshotID: assembled.snapshotID)
        context.insert(turn)
        try context.save()
        let turns = try context.fetch(FetchDescriptor<ChatTurn>())
        #expect(turns.count == 1)
        #expect(turns[0].contextSnapshotID == assembled.snapshotID)
    }

    @Test("a missing profile assembles an empty -- but still snapshotted -- context")
    func emptyProfileSnapshotsEmpty() throws {
        let (assembler, container) = try makeAssembler()
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let locale = Locale(identifier: "en_US")

        let assembled = try assembler.assemble(for: .dailyInsight, now: now, locale: locale)
        #expect(assembled.context.fields.isEmpty)
        #expect(!assembled.didTrim)
        #expect(assembled.estimatedTokens == ContextAssembler.estimatedShellTokens(
            localeIdentifier: "en_US",
            unitSystem: .imperial,
            today: now
        ))
        #expect(try ModelContext(container).fetch(FetchDescriptor<ContextSnapshot>()).count == 1)
    }

    @Test("the budget covers shell plus fields, and the total is their sum")
    func shellAccounted() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let locale = Locale(identifier: "en_US")
        let vitals = field("vitals.restingHeartRate", "Resting HR ~58 bpm (30-day avg)")
        let sleep = field("sleep.duration", "7h 12m avg (14 nights)")
        let (assembler, _) = try makeAssembler(sections: [sleep, vitals])
        let shell = ContextAssembler.estimatedShellTokens(
            localeIdentifier: "en_US",
            unitSystem: .imperial,
            today: now
        )

        let assembled = try assembler.assemble(
            for: .chat,
            now: now,
            locale: locale,
            tokenBudget: shell + ContextAssembler.estimatedTokens(for: [vitals])
        )
        #expect(assembled.context.fields.map(\.key) == ["vitals.restingHeartRate"])
        #expect(assembled.didTrim)
        #expect(assembled.estimatedTokens == shell + ContextAssembler.estimatedTokens(for: assembled.context.fields))
    }

    @Test("locale and unit system flow into the context")
    func localeAndUnits() throws {
        let (assembler, _) = try makeAssembler(sections: [
            field("steps.dailyAverage", "~8,200 steps/day (30-day avg)"),
        ])

        let usAssembled = try assembler.assemble(
            for: .chat, locale: Locale(identifier: "en_US"), unitSystem: nil
        )
        #expect(usAssembled.context.localeIdentifier == "en_US")
        #expect(usAssembled.context.unitSystem == .imperial)

        let explicit = try assembler.assemble(
            for: .chat, locale: Locale(identifier: "en_US"), unitSystem: .metric
        )
        #expect(explicit.context.unitSystem == .metric)
    }
}
