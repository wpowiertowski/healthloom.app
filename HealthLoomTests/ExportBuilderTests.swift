// ExportBuilderTests.swift
//
// WP-35 (implementation-plan.md) "Tests:" line: the export JSON schema
// snapshot. Exact-golden: fixed fixtures encode byte-identically (sorted
// keys, pretty printed, ISO-8601), so any schema drift fails loudly.
// Structural asserts pin the redaction-free guarantees beside it (payload
// text preserved verbatim, chat order kept, empty profile encodes null).

import CoreModel
import Foundation
import Testing
@testable import HealthLoom

@Suite("ExportBuilder")
struct ExportBuilderTests {
    private static let start = Date(timeIntervalSince1970: 1_700_000_000)
    private static let end = Date(timeIntervalSince1970: 1_700_003_600)
    private static let now = Date(timeIntervalSince1970: 1_700_010_000)

    private static func sample() -> LocalSample {
        LocalSample(
            externalID: "fitbit-steps-1",
            dataType: "steps",
            payloadJSON: Data(#"{"steps":8240}"#.utf8),
            start: start,
            end: end,
            source: "Fitbit Air"
        )
    }

    private static func profile() -> KnowledgeProfile {
        KnowledgeProfile(
            sections: [ProfileField(
                key: "steps.dailyAverage30d",
                displayText: "~8,200 steps/day",
                source: "HealthKit",
                asOf: start
            )],
            updatedAt: end
        )
    }

    private static func turns() -> [ChatTurn] {
        [
            ChatTurn(role: "user", content: "How did I sleep?", createdAt: start),
            ChatTurn(role: "assistant", content: "Well.", provider: "onDevice", createdAt: end),
        ]
    }

    @Test("schema version stamps every document")
    func schemaVersion() {
        let document = ExportBuilder.build(samples: [], profile: nil, turns: [], now: Self.now)
        #expect(document.schemaVersion == ExportBuilder.schemaVersion)
        #expect(document.samples.isEmpty)
        #expect(document.profile == nil)
        #expect(document.chat.isEmpty)
    }

    @Test("payloads and order survive verbatim")
    func verbatim() throws {
        let document = ExportBuilder.build(
            samples: [Self.sample()], profile: Self.profile(), turns: Self.turns(), now: Self.now
        )
        #expect(document.samples.first?.payloadJSON == #"{"steps":8240}"#)
        #expect(document.chat.map(\.role) == ["user", "assistant"])
        #expect(document.profile?.sections.first?.key == "steps.dailyAverage30d")
        // Twice-encoded output is byte-identical (deterministic schema).
        #expect(try ExportBuilder.encode(document) == ExportBuilder.encode(document))
    }

    @Test("golden schema snapshot")
    func golden() throws {
        let document = ExportBuilder.build(
            samples: [Self.sample()], profile: Self.profile(), turns: Self.turns(), now: Self.now
        )
        let json = String(data: try ExportBuilder.encode(document), encoding: .utf8)
        #expect(json == Self.goldenJSON)
    }

    // Verified by eye on first record: sorted keys, ISO-8601 dates,
    // pretty printed. Any field addition/removal renames this text.
    private static let goldenJSON = """
    {
      "chat" : [
        {
          "content" : "How did I sleep?",
          "createdAt" : "2023-11-14T22:13:20Z",
          "provider" : "",
          "role" : "user"
        },
        {
          "content" : "Well.",
          "createdAt" : "2023-11-14T23:13:20Z",
          "provider" : "onDevice",
          "role" : "assistant"
        }
      ],
      "exportedAt" : "2023-11-15T01:00:00Z",
      "profile" : {
        "sections" : [
          {
            "asOf" : "2023-11-14T22:13:20Z",
            "displayText" : "~8,200 steps\\/day",
            "excludedFromAI" : false,
            "isClinical" : false,
            "key" : "steps.dailyAverage30d",
            "source" : "HealthKit"
          }
        ],
        "updatedAt" : "2023-11-14T23:13:20Z"
      },
      "samples" : [
        {
          "dataType" : "steps",
          "end" : "2023-11-14T23:13:20Z",
          "externalID" : "fitbit-steps-1",
          "payloadJSON" : "{\\"steps\\":8240}",
          "source" : "Fitbit Air",
          "start" : "2023-11-14T22:13:20Z"
        }
      ],
      "schemaVersion" : 1
    }
    """
}
