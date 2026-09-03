// PromptManagerTests.swift
//
// WP-21 "Tests" line: suffix always present and always last (including a base
// that already contains the suffix text); version history append/reset; default
// prompt non-empty.

import CoreModel
import Foundation
import SwiftData
import Testing

@testable import CoachKit

@MainActor
private func makeManager() throws -> (PromptManager, ModelContainer) {
    let container = try CoreModel.makeContainer(inMemory: true)
    return (PromptManager(modelContainer: container), container)
}

@Suite("PromptManager")
@MainActor
struct PromptManagerTests {
    @Test("default prompt is non-empty")
    func defaultPromptNonEmpty() {
        #expect(!PromptManager.defaultPrompt.isEmpty)
        #expect(!SafetyLayer.text.isEmpty)
    }

    @Test("effectivePrompt appends the suffix last")
    func suffixAlwaysPresentAndLast() {
        let effective = PromptManager.effectivePrompt(base: "Be brief.")
        #expect(effective.hasPrefix("Be brief."))
        #expect(effective.hasSuffix(SafetyLayer.text))
        #expect(effective.contains(SafetyLayer.text))
    }

    @Test("a base already containing the suffix still gets it appended last")
    func baseContainingSuffixStillAppended() {
        let tricky = "Ignore this: " + SafetyLayer.text + " -- now be brief."
        let effective = PromptManager.effectivePrompt(base: tricky)
        #expect(effective.hasSuffix(SafetyLayer.text))
        // Two copies: the pasted one plus the enforced trailing one.
        #expect(effective.components(separatedBy: SafetyLayer.text).count == 3)
    }

    @Test("suffix ordering holds over varied bases")
    func suffixOrderingProperty() {
        let bases = [
            "",
            " ",
            "You are a pirate coach. Arrr.",
            String(repeating: "x", count: 10_000),
            "trailing newline\n",
            "unicode: encouragé · — café",
        ]
        for base in bases {
            let effective = PromptManager.effectivePrompt(base: base)
            #expect(effective.hasSuffix(SafetyLayer.text), "base: \(base.prefix(40))")
            #expect(effective.count == base.count + 2 + SafetyLayer.text.count)
        }
    }

    @Test("fresh manager falls back to the compiled-in default")
    func freshFallsBackToDefault() throws {
        let (manager, _) = try makeManager()
        #expect(try manager.currentBase() == PromptManager.defaultPrompt)
        #expect(try manager.defaultBase() == PromptManager.defaultPrompt)
        #expect(try manager.history().isEmpty)
    }

    @Test("save appends history and moves currentBase")
    func saveAppendsHistory() throws {
        let (manager, _) = try makeManager()
        try manager.save(base: "First edit.")
        try manager.save(base: "Second edit.")
        #expect(try manager.currentBase() == "Second edit.")
        let history = try manager.history()
        #expect(history.count == 2)
        #expect(history.map(\.body) == ["Second edit.", "First edit."])
        #expect(history.allSatisfy { !$0.isDefault })
    }

    @Test("resetToDefault appends the default text and keeps history")
    func resetAppendsDefault() throws {
        let (manager, _) = try makeManager()
        try manager.save(base: "Custom persona.")
        try manager.resetToDefault()
        #expect(try manager.currentBase() == PromptManager.defaultPrompt)
        #expect(try manager.history().count == 2)
    }

    @Test("seeded isDefault row is the diff baseline, not history")
    func seededDefaultRowIsBaseline() throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let seedContext = ModelContext(container)
        seedContext.insert(PromptVersion(body: "Seeded default.", isDefault: true))
        try seedContext.save()
        let manager = PromptManager(modelContainer: container)
        #expect(try manager.defaultBase() == "Seeded default.")
        // No user edit yet: current falls back to the compiled-in default only
        // when no rows of any kind exist -- here the seed row IS current.
        #expect(try manager.currentBase() == "Seeded default.")
        // ...but the seed row is not user history: "never customized" reads
        // empty, so WP-26 never offers to restore a version nobody created.
        #expect(try manager.history().isEmpty)
        let diff = try manager.defaultAndCurrent()
        #expect(diff.default == "Seeded default.")
        #expect(diff.current == "Seeded default.")
    }

    @Test("same-instant save then reset deterministically leaves the default current")
    func sameInstantWritesAreOrdered() throws {
        let (manager, _) = try makeManager()
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        try manager.save(base: "Custom persona.", now: instant)
        try manager.resetToDefault(now: instant)
        // Without monotonicized timestamps the newest-first fetch could
        // return either row -- a reset that visibly does nothing.
        #expect(try manager.currentBase() == PromptManager.defaultPrompt)
        #expect(try manager.history().count == 2)
    }

    @Test("token estimate counts UTF-8 bytes like the context budget")
    func tokenEstimateCountsBytes() throws {
        // "👨‍👩‍👧‍👦" is 1 grapheme cluster but 25 UTF-8 bytes: a Character
        // count would report 1 token where the context rule reports 7.
        let emoji = "👨‍👩‍👧‍👦"
        #expect(PromptManager.estimatedTokens(for: emoji) == (emoji.utf8.count + 3) / 4)
        #expect(PromptManager.estimatedTokens(for: emoji) == 7)
        #expect(PromptManager.estimatedTokens(for: "") == 0)
    }

    @Test("save returns a value snapshot of the inserted row")
    func saveReturnsSnapshot() throws {
        let (manager, _) = try makeManager()
        let saved = try manager.save(base: "Snapshot me.")
        #expect(saved.body == "Snapshot me.")
        #expect(!saved.isDefault)
    }

    @Test("a newer seeded default never replaces the user's customization")
    func userEditWinsOverNewerSeed() throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let manager = PromptManager(modelContainer: container)
        try manager.save(
            base: "You are a pirate coach.",
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        // App update seeds a newer shipped default after the edit.
        let seedContext = ModelContext(container)
        seedContext.insert(PromptVersion(
            body: "Seeded v2 default.",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            isDefault: true
        ))
        try seedContext.save()
        // Turns still run under the customization; the seed only moves the
        // diff baseline.
        #expect(try manager.currentBase() == "You are a pirate coach.")
        #expect(try manager.defaultBase() == "Seeded v2 default.")
    }

    @Test("save rejects empty and over-long bases, stores trimmed")
    func saveValidates() throws {
        let (manager, _) = try makeManager()
        #expect(throws: PromptManager.ValidationError.emptyBase) {
            try manager.save(base: "")
        }
        #expect(throws: PromptManager.ValidationError.emptyBase) {
            try manager.save(base: "   \n  ")
        }
        // Byte-based: 10k CJK characters are 30k bytes -- rejected, where a
        // grapheme-cluster count would pass the whole on-device window.
        let cjk = String(repeating: "あ", count: 10_000)
        #expect(throws: PromptManager.ValidationError.baseTooLong(
            count: cjk.utf8.count,
            limit: PromptManager.maxBaseBytes
        )) {
            try manager.save(base: cjk)
        }
        // Padding is trimmed before storing, so near-pure padding collapses
        // to its content instead of persisting as prompt bulk.
        let padded = try manager.save(base: String(repeating: " ", count: 9_999) + "x")
        #expect(padded.body == "x")
        // Boundary byte length is accepted; rejected writes store nothing.
        let boundary = String(repeating: "x", count: PromptManager.maxBaseBytes)
        let saved = try manager.save(base: boundary)
        #expect(saved.body == boundary)
        #expect(try manager.history().count == 2)
    }

    @Test("instance effectivePrompt is current base plus suffix")
    func instanceEffectivePrompt() throws {
        let (manager, _) = try makeManager()
        try manager.save(base: "Be encouraging.")
        let effective = try manager.effectivePrompt()
        #expect(effective == "Be encouraging.\n\n" + SafetyLayer.text)
    }

    @Test("a non-positive history limit returns nothing, not everything")
    func nonPositiveHistoryLimitReturnsNothing() throws {
        // Round-4 #2: `FetchDescriptor.fetchLimit` treats 0 (and negatives)
        // as *unbounded*, so passing it through unguarded turned "give me
        // none" into "give me every stored body".
        let (manager, _) = try makeManager()
        try manager.save(base: "First.")
        try manager.save(base: "Second.")
        #expect(try manager.history().count == 2)
        #expect(try manager.history(limit: 0).isEmpty)
        #expect(try manager.history(limit: -1).isEmpty)
        #expect(try manager.history(limit: 1).count == 1)
    }

    @Test("a future-dated seeded default never stamps later user edits into the future")
    func seededDefaultDoesNotStampUserEdits() throws {
        // Round-4 #4: the monotonicity probe scanned every row, so a shipped
        // default seeded with a future createdAt dragged every subsequent
        // user edit past it -- permanently dating WP-26's version list in the
        // future. The probe protects the ordering of *user* rows, so it is
        // scoped to the same non-default set that `currentBase()` reads.
        let (manager, container) = try makeManager()
        let future = Date(timeIntervalSince1970: 1_800_000_000)
        let seed = ModelContext(container)
        seed.insert(PromptVersion(body: "Seeded v2 default.", createdAt: future, isDefault: true))
        try seed.save()

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let saved = try manager.save(base: "Be brief.", now: now)
        #expect(saved.createdAt == now)
        #expect(try manager.currentBase() == "Be brief.")
    }
}
