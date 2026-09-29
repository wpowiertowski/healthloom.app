// LocalKnowledgeReaderTests.swift
//
// WP-70: the refresh's local-sample half, read on a background context.

import CoreModel
import Foundation
import SwiftData
import Testing
@testable import CoachKit

@Suite struct LocalKnowledgeReaderTests {
    static func sample(_ id: String, _ type: GoogleDataType, start: Date, minutes: Double? = nil) -> LocalSample {
        let values: [String: Double] = minutes.map { ["minutes": $0] } ?? [:]
        let payload = (try? JSONSerialization.data(withJSONObject: ["values": values])) ?? Data()
        return LocalSample(
            externalID: id, dataType: type.rawValue, payloadJSON: payload,
            start: start, end: start.addingTimeInterval(60), source: "Fitbit Air"
        )
    }

    // catches: the local fields or exercise sessions going missing (or
    // widening past their windows) once the read moved off the main actor --
    // and, by running on the reader's own actor, an isolation mistake in the
    // derivation it calls (the build-21 crash class).
    @Test func readsEachWindowOnItsOwnActor() async throws {
        let container = try CoreModel.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let now = Date()
        context.insert(Self.sample("am-1", .activeMinutes, start: now.addingTimeInterval(-3600), minutes: 20))
        context.insert(Self.sample("am-2", .activeMinutes, start: now.addingTimeInterval(-7200), minutes: 10))
        context.insert(Self.sample("am-old", .activeMinutes, start: now.addingTimeInterval(-40 * 86_400), minutes: 500))
        context.insert(Self.sample("am-future", .activeMinutes, start: now.addingTimeInterval(86_400), minutes: 500))
        context.insert(Self.sample("ex-1", .exercise, start: now.addingTimeInterval(-86_400)))
        context.insert(Self.sample("ex-old", .exercise, start: now.addingTimeInterval(-400 * 86_400)))
        try context.save()

        let result = try await LocalKnowledgeReader(modelContainer: container).read(
            exerciseSince: now.addingTimeInterval(-30 * 86_400),
            localOnlySince: now.addingTimeInterval(-7 * 86_400),
            now: now,
            localOnlyTypes: [.activeMinutes, .electrocardiogram],
            windowDays: 7
        )

        #expect(result.exerciseSupplements.map(\.externalID) == ["ex-1"])
        #expect(result.localOnlyFields.count == 1)
        #expect(result.localOnlyFields.first?.displayText.hasPrefix("~30 Active Minutes") == true)
    }
}
