// HealthContextFramingTests.swift
// CoreModelTests
//
// WP-25 review #14: the "data, not instructions" delimiter block both
// prompt composers (`DailyInsight.prompt`, the chat prompt) share must
// frame identically, including the empty-context case.

import Foundation
import Testing
@testable import CoreModel

@Suite("HealthContext.framedAsData")
struct HealthContextFramingTests {
    private static func context(fields: [ProfileField]) -> HealthContext {
        HealthContext(fields: fields, localeIdentifier: "en_US", unitSystem: .metric, today: .now)
    }

    @Test("non-empty fields render as a delimited data block")
    func delimitedBlock() {
        let context = Self.context(fields: [
            ProfileField(key: "a", displayText: "8,000 steps", source: "HealthKit", asOf: .now),
            ProfileField(key: "b", displayText: "7h sleep", source: "Manual", asOf: .now),
        ])
        #expect(context.framedAsData(emptyMessage: "EMPTY") == [
            "---",
            "- 8,000 steps [HealthKit]",
            "- 7h sleep [Manual]",
            "---",
        ])
    }

    @Test("empty fields collapse to the caller's empty message")
    func emptyMessage() {
        #expect(Self.context(fields: []).framedAsData(emptyMessage: "EMPTY") == ["EMPTY"])
    }
}

@Suite("HealthContext.promptBlock")
struct PromptBlockTests {
    private static func context(fields: [ProfileField] = []) -> HealthContext {
        HealthContext(fields: fields, localeIdentifier: "en_US", unitSystem: .metric, today: .now)
    }

    /// The single shared composer (WP-27 review R1): message, blank line,
    /// framing sentence, framed fields. Both message-style prompts
    /// (orchestrator turns, chat) emit exactly this.
    @Test("empty context keeps the legacy quirk")
    func emptyBlock() {
        #expect(
            Self.context().promptBlock(message: "Hi")
                == "Hi\n\n\(HealthContext.dataFramingSentence)\n(No health context available.)"
        )
    }

    @Test("fields render under the sentence")
    func fieldsBlock() {
        let block = Self.context(fields: [
            ProfileField(key: "a", displayText: "8,000 steps", source: "HealthKit", asOf: .now),
        ]).promptBlock(message: "Hi")
        #expect(block.hasPrefix("Hi\n\n\(HealthContext.dataFramingSentence)\n---\n- 8,000 steps [HealthKit]"))
    }
}
