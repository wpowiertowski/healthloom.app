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
