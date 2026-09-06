// YouViewModelTests.swift
//
// WP-30 (implementation-plan.md): the You tab's truth table — toggling a
// field off removes it from the next assembled context; a correction pins
// and persists; forget clears insights/chat but keeps the profile.
// Ephemeral `ModelContainer` + empty reads: no HealthKit, no network.

import CoachKit
import CoreModel
import Foundation
import SwiftData
import SyncKit
import Testing

@testable import HealthLoom

@MainActor
struct YouViewModelTests {
    private func makeViewModel() throws -> (YouViewModel, ModelContainer, KnowledgeStore, CoachSessionFactory) {
        let container = try CoreModel.makeContainer(inMemory: true)
        let store = KnowledgeStore(
            modelContainer: container,
            healthReadStore: EmptyReadStore(),
            healthKitAuth: HealthKitAuth()
        )
        // Fresh session per build so cache hits are observable by identity.
        let factory = CoachSessionFactory(build: { _, _ in TestCoachSession() })
        return (
            YouViewModel(container: container, store: store, factory: factory),
            container, store, factory
        )
    }

    private func seedProfile(in container: ModelContainer) throws {
        let context = ModelContext(container)
        context.insert(KnowledgeProfile(sections: [
            ProfileField(
                key: "steps.dailyAverage", displayText: "~8,200 steps/day",
                source: "HealthKit", asOf: .now
            ),
            ProfileField(
                key: "heart.ecg", displayText: "Sinus rhythm",
                source: "Apple Watch", asOf: .now, isClinical: true
            ),
        ]))
        try context.save()
    }

    @Test("load renders every field with source and clinical posture")
    func loadRendersFields() throws {
        let (viewModel, container, _, _) = try makeViewModel()
        try seedProfile(in: container)
        viewModel.load()
        #expect(viewModel.fields.count == 2)
        #expect(viewModel.updatedAt != nil)
        #expect(viewModel.fields.contains(where: { $0.key == "heart.ecg" && $0.isClinical && $0.excludedFromAI }))
    }

    @Test("toggling a field off removes it from the next context")
    func toggleOffExcludesFromContext() throws {
        let (viewModel, container, _, _) = try makeViewModel()
        try seedProfile(in: container)
        let assembler = ContextAssembler(modelContainer: container)
        let before = try assembler.assemble(for: .chat, promptTokens: 10)
        #expect(before.context.fields.contains(where: { $0.key == "steps.dailyAverage" }))
        viewModel.load()
        viewModel.setExcluded(true, forKey: "steps.dailyAverage")
        #expect(viewModel.fields.first(where: { $0.key == "steps.dailyAverage" })?.excludedFromAI == true)
        let after = try assembler.assemble(for: .chat, promptTokens: 10)
        #expect(!after.context.fields.contains(where: { $0.key == "steps.dailyAverage" }))
        #expect(after.context.fields.contains(where: { $0.key == "heart.ecg" }) == false)
    }

    @Test("a correction pins, persists, and keeps the sharing posture")
    func correctionPins() throws {
        let (viewModel, container, store, factory) = try makeViewModel()
        try seedProfile(in: container)
        viewModel.load()
        viewModel.pinCorrection("~9,000 steps/day (my tracker)", forKey: "steps.dailyAverage")
        #expect(viewModel.errorMessage == nil)
        let row = viewModel.fields.first(where: { $0.key == "steps.dailyAverage" })
        #expect(row?.displayText == "~9,000 steps/day (my tracker)")
        #expect(row?.source == KnowledgeStore.correctionSourceLabel)
        // Persists across VM instances (re-fetch from the store).
        let reloaded = YouViewModel(container: container, store: store, factory: factory)
        reloaded.load()
        #expect(reloaded.fields.first(where: { $0.key == "steps.dailyAverage" })?.displayText == "~9,000 steps/day (my tracker)")
    }

    @Test("empty correction is refused with a message")
    func emptyCorrectionRefused() throws {
        let (viewModel, container, _, _) = try makeViewModel()
        try seedProfile(in: container)
        viewModel.load()
        viewModel.pinCorrection("   ", forKey: "steps.dailyAverage")
        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.fields.first(where: { $0.key == "steps.dailyAverage" })?.displayText == "~8,200 steps/day")
    }

    @Test("forget clears insights and chat but keeps the profile")
    func forgetKeepsProfile() throws {
        let (viewModel, container, _, _) = try makeViewModel()
        try seedProfile(in: container)
        let context = ModelContext(container)
        context.insert(DerivedInsight(text: "Walk more", sourceProvider: "onDevice", sourceFields: ["steps.dailyAverage"]))
        context.insert(ChatTurn(role: "user", content: "hi"))
        context.insert(ChatTurn(role: "assistant", content: "hello", provider: "onDevice"))
        try context.save()

        viewModel.load()
        viewModel.resetInsights()
        #expect(viewModel.notice != nil)
        #expect(try context.fetch(FetchDescriptor<DerivedInsight>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<ChatTurn>()).count == 2)

        viewModel.wipeChatHistory()
        #expect(try context.fetch(FetchDescriptor<ChatTurn>()).isEmpty)
        viewModel.load()
        #expect(viewModel.fields.count == 2)
    }

    @Test("empty store renders the empty state")
    func emptyState() throws {
        let (viewModel, _, _, _) = try makeViewModel()
        viewModel.load()
        #expect(viewModel.fields.isEmpty)
        #expect(viewModel.updatedAt == nil)
    }

    @Test("wiping history resets the live conversation session (F1)")
    func wipeResetsConversationSession() throws {
        let (viewModel, container, _, factory) = try makeViewModel()
        let context = ModelContext(container)
        context.insert(ChatTurn(role: "user", content: "hi"))
        try context.save()

        let first = factory.makeSession(for: .conversation, instructions: "prompt")
        let cached = factory.makeSession(for: .conversation, instructions: "prompt")
        #expect(ObjectIdentifier(first as AnyObject) == ObjectIdentifier(cached as AnyObject))

        viewModel.wipeChatHistory()
        #expect(try context.fetch(FetchDescriptor<ChatTurn>()).isEmpty)
        let second = factory.makeSession(for: .conversation, instructions: "prompt")
        #expect(ObjectIdentifier(first as AnyObject) != ObjectIdentifier(second as AnyObject))
    }
}
