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

        let assembled = try assembler.assemble(for: .chat, promptTokens: 0)
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

        let assembled = try assembler.assemble(for: .chat, promptTokens: 0)
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

        let assembled = try assembler.assemble(for: .dailyInsight, promptTokens: 0)
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
            tokenBudget: shell + twoHighestCost,
            promptTokens: 0
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

        let assembled = try assembler.assemble(for: .chat, tokenBudget: .max, promptTokens: 0)
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
            tokenBudget: ContextAssembler.estimatedTokens(for: [sleep]),
            promptTokens: 0
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
            tokenBudget: ContextAssembler.estimatedTokens(for: [big]),
            promptTokens: 0
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

        let assembled = try assembler.assemble(for: .chat, tokenBudget: 0, promptTokens: 0)
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
        let assembled = try assembler.assemble(for: .chat, now: now, promptTokens: 0)

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

        let assembled = try assembler.assemble(for: .dailyInsight, now: now, locale: locale, promptTokens: 0)
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
            tokenBudget: shell + ContextAssembler.estimatedTokens(for: [vitals]),
            promptTokens: 0
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
            for: .chat, locale: Locale(identifier: "en_US"), unitSystem: nil, promptTokens: 0
        )
        #expect(usAssembled.context.localeIdentifier == "en_US")
        #expect(usAssembled.context.unitSystem == .imperial)

        let explicit = try assembler.assemble(
            for: .chat, locale: Locale(identifier: "en_US"), unitSystem: .metric, promptTokens: 0
        )
        #expect(explicit.context.unitSystem == .metric)
    }
}

@Suite("ContextAssembler review fixes (WP-21/22 pass)")
@MainActor
struct ContextAssemblerReviewTests {
    @Test("correction-sourced fields outrank every derived field")
    func correctionsRankFirst() throws {
        // A standalone user goal (WP-19 pinning: source-marked, no derivation
        // produces its key) plus a full derived set, budget fitting exactly
        // two fields. The goal must survive with the top derived field --
        // previously it sorted dead last (rank 3 + appended-last tie-break)
        // and was dropped first, inverting \"corrections beat re-derivation\".
        let goal = ProfileField(
            key: "user.goal",
            displayText: "Run a 10K in spring",
            source: KnowledgeStore.correctionSourceLabel,
            asOf: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let vitals = field("vitals.restingHeartRate", "Resting HR ~58 bpm (30-day avg)")
        let sleep = field("sleep.duration", "7h 12m avg (14 nights)")
        let steps = field("steps.dailyAverage", "~8,200 steps/day (30-day avg)")
        let workouts = field("activity.workouts", "3 workouts in the last 30 days")
        let (assembler, _) = try makeAssembler(sections: [workouts, steps, sleep, vitals, goal])

        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let shell = ContextAssembler.estimatedShellTokens(
            localeIdentifier: "en_US",
            unitSystem: .imperial,
            today: now
        )
        let assembled = try assembler.assemble(
            for: .chat,
            now: now,
            locale: Locale(identifier: "en_US"),
            tokenBudget: shell + ContextAssembler.estimatedTokens(for: [goal, vitals]),
            promptTokens: 0
        )
        #expect(assembled.didTrim)
        #expect(assembled.context.fields.map(\.key) == ["user.goal", "vitals.restingHeartRate"])
    }

    @Test("a shadowing correction keeps its derived key's rank")
    func shadowingCorrectionKeepsRank() throws {
        // A correction overriding a derived key still orders with that key's
        // rank (here: sleep, rank 1) -- ahead of steps, behind vitals.
        let correctedSleep = ProfileField(
            key: "sleep.duration",
            displayText: "Actually 6h -- tracker overcounts",
            source: KnowledgeStore.correctionSourceLabel,
            asOf: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let vitals = field("vitals.restingHeartRate", "Resting HR ~58 bpm (30-day avg)")
        let steps = field("steps.dailyAverage", "~8,200 steps/day (30-day avg)")
        let (assembler, _) = try makeAssembler(sections: [steps, correctedSleep, vitals])

        let assembled = try assembler.assemble(for: .chat, tokenBudget: .max, promptTokens: 0)
        #expect(!assembled.didTrim)
        #expect(assembled.context.fields.map(\.key) == [
            "vitals.restingHeartRate", "sleep.duration", "steps.dailyAverage",
        ])
    }

    @Test("prompt tokens reserve budget and report overflow")
    func promptTokensReserve() throws {
        let vitals = field("vitals.restingHeartRate", "Resting HR ~58 bpm (30-day avg)")
        let sleep = field("sleep.duration", "7h 12m avg (14 nights)")
        let (assembler, _) = try makeAssembler(sections: [sleep, vitals])
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let shell = ContextAssembler.estimatedShellTokens(
            localeIdentifier: "en_US",
            unitSystem: .imperial,
            today: now
        )
        let fieldsCost = ContextAssembler.estimatedTokens(for: [vitals, sleep])
        let budget = shell + fieldsCost

        // Without a prompt reserve the full context fits, untrimmed.
        let unreserved = try assembler.assemble(
            for: .chat, now: now, locale: Locale(identifier: "en_US"), tokenBudget: budget, promptTokens: 0
        )
        #expect(!unreserved.didTrim)
        #expect(!unreserved.promptOverBudget)
        #expect(unreserved.context.fields.count == 2)

        // A prompt as large as the whole budget leaves no room for fields:
        // top-1 fallback, overflow reported, total covers prompt + request.
        let reserved = try assembler.assemble(
            for: .chat,
            now: now,
            locale: Locale(identifier: "en_US"),
            tokenBudget: budget,
            promptTokens: budget
        )
        #expect(reserved.didTrim)
        #expect(reserved.promptOverBudget)
        #expect(reserved.context.fields.map(\.key) == ["vitals.restingHeartRate"])
        #expect(reserved.estimatedTokens == budget + shell + ContextAssembler.estimatedTokens(
            for: reserved.context.fields
        ))
    }

    @Test("selectFields reports overflow for a lone over-budget field")
    func selectFieldsReportsLoneOverflow() throws {
        let big = field("vitals.restingHeartRate", String(repeating: "y", count: 400))
        let selection = ContextAssembler.selectFields(from: [big], tokenBudget: 10)
        #expect(selection.kept.count == 1)
        #expect(selection.didTrim)
    }

    @Test("assemble prunes snapshots beyond the cap")
    func snapshotPruning() throws {
        let (assembler, container) = try makeAssembler(sections: [
            field("steps.dailyAverage", "~8,200 steps/day (30-day avg)"),
        ])
        let seedContext = ModelContext(container)
        for day in 1 ... 5 {
            seedContext.insert(ContextSnapshot(
                json: Data("{\"fields\":[]}".utf8),
                createdAt: Date(timeIntervalSince1970: 1_600_000_000 + Double(day * 86_400))
            ))
        }
        try seedContext.save()

        let assembled = try assembler.assemble(for: .chat, promptTokens: 0, maxStoredSnapshots: 3)
        let remaining = try ModelContext(container).fetch(FetchDescriptor<ContextSnapshot>())
        #expect(remaining.count == 3)
        #expect(remaining.map(\.id).contains(assembled.snapshotID))
        #expect(remaining.allSatisfy {
            $0.createdAt >= Date(timeIntervalSince1970: 1_600_000_000 + Double(3 * 86_400))
        })
    }
}

@Suite("ContextAssembler prune correctness (round 2)")
@MainActor
struct ContextAssemblerPruneTests {
    @Test("a past-dated assembly never evicts its own snapshot")
    func pastDatedNowKeepsOwnSnapshot() throws {
        // The review probe: a future-dated row plus a past `now` (WP-23's
        // morning insight, clock skew). The returned ID must always resolve.
        let (assembler, container) = try makeAssembler(sections: [
            field("steps.dailyAverage", "~8,200 steps/day (30-day avg)"),
        ])
        let seedContext = ModelContext(container)
        seedContext.insert(ContextSnapshot(
            json: Data("{\"fields\":[]}".utf8),
            createdAt: Date(timeIntervalSince1970: 2_000_000_000)
        ))
        try seedContext.save()

        let assembled = try assembler.assemble(
            for: .chat,
            now: Date(timeIntervalSince1970: 1_700_000_100),
            promptTokens: 0,
            maxStoredSnapshots: 1
        )
        let remaining = try ModelContext(container).fetch(FetchDescriptor<ContextSnapshot>())
        #expect(remaining.map(\.id).contains(assembled.snapshotID))
    }

    @Test("eviction nulls linked turns instead of dangling")
    func evictionNullsLinks() throws {
        let (assembler, container) = try makeAssembler(sections: [
            field("steps.dailyAverage", "~8,200 steps/day (30-day avg)"),
        ])
        // Five old snapshots, the oldest linked from a chat turn.
        let seedContext = ModelContext(container)
        var linkedID = UUID()
        for day in 1 ... 5 {
            let row = ContextSnapshot(
                json: Data("{\"fields\":[]}".utf8),
                createdAt: Date(timeIntervalSince1970: 1_600_000_000 + Double(day * 86_400))
            )
            if day == 1 { linkedID = row.id }
            seedContext.insert(row)
        }
        seedContext.insert(ChatTurn(
            role: "assistant",
            content: "Old turn.",
            provider: "test",
            contextSnapshotID: linkedID
        ))
        try seedContext.save()

        // Six rows in, cap three: d3, d2, d1 evicted. The bound holds for
        // linked rows too -- d1's turn is nulled (renders "context expired",
        // never a dangling ID) instead of pinning its snapshot forever.
        let assembled = try assembler.assemble(for: .chat, promptTokens: 0, maxStoredSnapshots: 3)
        let remaining = try ModelContext(container).fetch(FetchDescriptor<ContextSnapshot>())
        #expect(remaining.count == 3)
        #expect(remaining.map(\.id).contains(assembled.snapshotID))
        #expect(!remaining.map(\.id).contains(linkedID))
        let turns = try ModelContext(container).fetch(FetchDescriptor<ChatTurn>())
        #expect(turns.count == 1)
        #expect(turns[0].contextSnapshotID == nil)
    }

    @Test("assemblies record their producer purpose")
    func purposeRecorded() throws {
        let (assembler, container) = try makeAssembler(sections: [
            field("steps.dailyAverage", "~8,200 steps/day (30-day avg)"),
        ])
        let chat = try assembler.assemble(for: .chat, promptTokens: 0)
        let insight = try assembler.assemble(for: .dailyInsight, promptTokens: 0)
        let byID = try ModelContext(container)
            .fetch(FetchDescriptor<ContextSnapshot>())
            .reduce(into: [UUID: String]()) { $0[$1.id] = $1.purpose }
        #expect(byID[chat.snapshotID] == "chat")
        #expect(byID[insight.snapshotID] == "dailyInsight")
    }

    @Test("an over-budget prompt overflows loudly, flagged as the prompt")
    func emptyContextPromptOverflowReported() throws {
        // No eligible fields at all; the prompt alone overflows ten times
        // over. didTrim must signal (the request cannot fit), and
        // promptOverBudget names the remedy: shorten the prompt, don't
        // escalate for context that never existed.
        let (assembler, _) = try makeAssembler()
        let assembled = try assembler.assemble(
            for: .chat,
            tokenBudget: 100,
            promptTokens: 1_000
        )
        #expect(assembled.context.fields.isEmpty)
        #expect(assembled.didTrim)
        #expect(assembled.promptOverBudget)
    }

    @Test("a prompt that exactly fills the budget is flagged as the prompt, not as trimming")
    func promptExactlyFillingBudgetIsOverBudget() throws {
        // Round-4 #3: at `promptTokens + shell == tokenBudget` the field
        // budget is already 0, so no field selection can fit and the remedy
        // is a shorter prompt. `>` reported "fields were dropped to fit" for
        // a request whose prompt plus shell consumed the entire window.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let locale = Locale(identifier: "en_US")
        let (assembler, _) = try makeAssembler(sections: [
            field("vitals.restingHeartRate", "Resting HR ~58 bpm (30-day avg)"),
        ])
        let shell = ContextAssembler.estimatedShellTokens(
            localeIdentifier: locale.identifier, unitSystem: .imperial, today: now
        )
        let promptTokens = 500
        let assembled = try assembler.assemble(
            for: .chat,
            now: now,
            locale: locale,
            tokenBudget: promptTokens + shell,
            promptTokens: promptTokens
        )
        #expect(assembled.promptOverBudget)
    }

    @Test("a cap of zero retains only the in-flight snapshot, never every row")
    func zeroCapPrunesEverythingButTheNewRow() throws {
        // Round-4 #1: `assemble` passes `maxStoredSnapshots - 1`, so cap 0
        // reached `pruneSnapshots` as -1 and hit a `guard keeping >= 0`
        // early return -- making 0 the one value that disabled pruning
        // entirely and grew the store without bound. Cap 0 must retain the
        // in-flight row (its ID has to resolve) and nothing else.
        let (assembler, container) = try makeAssembler(sections: [
            field("steps.dailyAverage", "~8,200 steps/day (30-day avg)"),
        ])
        let seed = ModelContext(container)
        for offset in 0..<3 {
            seed.insert(ContextSnapshot(
                json: Data("{}".utf8),
                createdAt: Date(timeIntervalSince1970: 1_600_000_000 + Double(offset)),
                purpose: "chat"
            ))
        }
        try seed.save()

        let assembled = try assembler.assemble(
            for: .chat,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            promptTokens: 0,
            maxStoredSnapshots: 0
        )

        let remaining = try ModelContext(container).fetch(FetchDescriptor<ContextSnapshot>())
        #expect(remaining.count == 1)
        #expect(remaining.map(\.id) == [assembled.snapshotID])
    }
}
