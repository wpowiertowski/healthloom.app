// ModelsTests.swift
// CoreModelTests
//
// Covers implementation-plan.md WP-02's required tests: "unique-constraint enforcement
// (externalID, dataType)" and the "Done when" bullet "container round-trips every
// model in memory."

import Foundation
import Testing
import SwiftData
@testable import CoreModel

@Suite("SwiftData unique-constraint enforcement")
struct UniqueConstraintTests {
    @Test("SyncState.dataType is unique — re-inserting the same dataType upserts, not duplicates")
    func syncStateDataTypeIsUnique() throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let context = ModelContext(container)

        context.insert(SyncState(dataType: GoogleDataType.steps.filterName, itemCount: 1))
        try context.save()

        context.insert(SyncState(dataType: GoogleDataType.steps.filterName, itemCount: 2))
        try context.save()

        let all = try context.fetch(FetchDescriptor<SyncState>())
        #expect(all.count == 1)
        #expect(all.first?.itemCount == 2)
    }

    @Test("LocalSample.externalID is unique — re-sync upserts by externalID, not duplicates")
    func localSampleExternalIDIsUnique() throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let now = Date.now

        context.insert(LocalSample(
            externalID: "google-datapoint-ext-1",
            dataType: GoogleDataType.electrocardiogram.filterName,
            payloadJSON: Data("{\"v\":1}".utf8),
            start: now,
            end: now,
            source: "Fitbit Air"
        ))
        try context.save()

        context.insert(LocalSample(
            externalID: "google-datapoint-ext-1",
            dataType: GoogleDataType.electrocardiogram.filterName,
            payloadJSON: Data("{\"v\":2}".utf8),
            start: now,
            end: now,
            source: "Fitbit Air"
        ))
        try context.save()

        let all = try context.fetch(FetchDescriptor<LocalSample>())
        #expect(all.count == 1)
        #expect(String(data: all.first?.payloadJSON ?? Data(), encoding: .utf8) == "{\"v\":2}")
    }
}

@Suite("ModelContainer round trip")
struct ContainerRoundTripTests {
    @Test("makeContainer(inMemory: true) round-trips every CoreModel model")
    func roundTripsEveryModel() throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let now = Date.now

        context.insert(SyncState(dataType: GoogleDataType.steps.filterName))

        context.insert(LocalSample(
            externalID: "ext-1",
            dataType: GoogleDataType.electrocardiogram.filterName,
            payloadJSON: Data("{}".utf8),
            start: now,
            end: now,
            source: "Fitbit Air"
        ))

        context.insert(KnowledgeProfile(sections: [
            ProfileField(key: "k", displayText: "d", source: "s", asOf: now),
        ]))

        context.insert(DerivedInsight(
            text: "Great sleep last night — recovery looks strong.",
            sourceProvider: "appleFoundation",
            sourceFields: ["sleep.duration14d"]
        ))

        context.insert(PromptVersion(body: "You are a supportive fitness coach.", isDefault: true))

        let snapshot = ContextSnapshot(json: Data("{\"fields\":[]}".utf8))
        context.insert(snapshot)

        context.insert(ChatTurn(
            role: "assistant",
            content: "Here's how last night's sleep looked.",
            provider: "appleFoundation",
            contextSnapshotID: snapshot.id
        ))

        try context.save()

        #expect(try context.fetch(FetchDescriptor<SyncState>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<LocalSample>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<KnowledgeProfile>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<DerivedInsight>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<PromptVersion>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<ContextSnapshot>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<ChatTurn>()).count == 1)

        // The chat turn's contextSnapshotID actually resolves to the stored snapshot.
        let turns = try context.fetch(FetchDescriptor<ChatTurn>())
        #expect(turns.first?.contextSnapshotID == snapshot.id)

        // `CoreModel.modelTypes` (the container's schema source) lists exactly the
        // seven models this test exercises — keeps the schema and this test honest
        // about covering "every model."
        #expect(CoreModel.modelTypes.count == 7)
    }

    @Test("makeContainer(inMemory: true) can be created repeatedly without on-disk side effects")
    func inMemoryContainersAreIndependent() throws {
        let containerA = try CoreModel.makeContainer(inMemory: true)
        let contextA = ModelContext(containerA)
        contextA.insert(SyncState(dataType: GoogleDataType.heartRate.filterName))
        try contextA.save()

        let containerB = try CoreModel.makeContainer(inMemory: true)
        let contextB = ModelContext(containerB)

        #expect(try contextA.fetch(FetchDescriptor<SyncState>()).count == 1)
        #expect(try contextB.fetch(FetchDescriptor<SyncState>()).count == 0)
    }
}

@Suite("Store file protection decision")
struct StoreProtectionDecisionTests {
    @Test("store files are stamped Complete")
    func completeProtectionPinned() {
        // Round-6 item 12: pins the DECISION (named constant) anywhere —
        // enforcement itself is iOS-only, unobservable on macOS and
        // (empirically) the simulator, enforced on device.
        #expect(CoreModel.completeProtection == FileProtectionType.complete)
    }
}
