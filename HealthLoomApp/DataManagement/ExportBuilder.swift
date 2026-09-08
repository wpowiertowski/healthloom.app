// ExportBuilder.swift
//
// WP-35 (implementation-plan.md): user-initiated JSON export of
// `LocalSample` + knowledge profile + chat. Pure builder (AGENTS.md §2:
// pure core, thin adapters): models in, versioned `ExportDocument` out —
// the share sheet, file write, and SwiftData fetch live in the view.
// Payloads stay UTF-8 JSON text (lossless, human-readable); undecodable
// payload bytes fall back to a placeholder rather than failing the whole
// export. Dates ISO-8601, keys sorted: byte-stable output the schema
// snapshot test pins exactly.

import CoreModel
import Foundation

enum ExportBuilder {
    /// Schema version of `ExportDocument`. Bump on any field change, with
    /// a migration note here — importers key off this, not app version.
    static let schemaVersion = 1

    struct SampleRecord: Codable, Equatable {
        var externalID: String
        var dataType: String
        var start: Date
        var end: Date
        var source: String
        var payloadJSON: String
        var linkedWatchWorkoutUUID: UUID?
    }

    struct ProfileRecord: Codable, Equatable {
        var sections: [ProfileField]
        var updatedAt: Date
    }

    struct ChatRecord: Codable, Equatable {
        var role: String
        var content: String
        var provider: String
        var createdAt: Date
    }

    struct ExportDocument: Codable, Equatable {
        var schemaVersion: Int
        var exportedAt: Date
        var samples: [SampleRecord]
        var profile: ProfileRecord?
        var chat: [ChatRecord]
    }

    static func build(
        samples: [LocalSample],
        profile: KnowledgeProfile?,
        turns: [ChatTurn],
        now: Date
    ) -> ExportDocument {
        ExportDocument(
            schemaVersion: schemaVersion,
            exportedAt: now,
            samples: samples.map { sample in
                SampleRecord(
                    externalID: sample.externalID,
                    dataType: sample.dataType,
                    start: sample.start,
                    end: sample.end,
                    source: sample.source,
                    payloadJSON: String(data: sample.payloadJSON, encoding: .utf8)
                        ?? "<non-UTF8 payload, \(sample.payloadJSON.count) bytes>",
                    linkedWatchWorkoutUUID: sample.linkedWatchWorkoutUUID
                )
            },
            profile: profile.map { ProfileRecord(sections: $0.sections, updatedAt: $0.updatedAt) },
            chat: turns.map {
                ChatRecord(role: $0.role, content: $0.content, provider: $0.provider, createdAt: $0.createdAt)
            }
        )
    }

    static func encode(_ document: ExportDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(document)
    }
}
