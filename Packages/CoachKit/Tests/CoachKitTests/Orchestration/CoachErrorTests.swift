// CoachErrorTests.swift
//
// WP-27 "Tests" line: the error-normalization table. Framework cases are
// toolchain-gated (constructing a `LanguageModelError` needs the 27 SDK);
// the ungated fallback is tested on both toolchains.

#if swift(>=6.4)
    import FoundationModels
#endif
import Foundation
import Testing

@testable import CoachKit

@Suite("CoachError normalization")
@MainActor
struct CoachErrorTests {
    // NOTE (review N7, no action): this constructs `.underlying` raw by
    // hand -- it pins the case exists, not the sanitizer. Sanitizer
    // coverage lives in `errorPayloadSanitized` (through `respond`) and the
    // table's `sanitizedSummary` asserts below.
    @Test("unknown errors degrade to underlying with their description")
    func underlyingFallback() {
        struct Boom: Error {}
        let normalized = CoachError.underlying(String(describing: Boom()))
        #expect(normalized == .underlying("Boom()"))
    }

#if swift(>=6.4)
    /// Same host caveat as `makeModelLiveness`: compile-checked on beta,
    /// executed on macOS 27+ hosts, early return on macOS 26.
    @Test("framework error table")
    func languageModelErrorTable() {
        guard #available(macOS 27, *) else { return }
        #expect(
            CoachError(languageModelError: LanguageModelError.contextSizeExceeded(.init(
                contextSize: 4096, tokenCount: 5000, debugDescription: "full"
            ))) == .contextOverflow(offerEscalation: true)
        )
        // F2: the offer bit is structural in the mapping, keyed on the
        // requesting tier -- a cloud overflow has nowhere bigger to go.
        #expect(
            CoachError(
                languageModelError: LanguageModelError.contextSizeExceeded(.init(
                    contextSize: 32000, tokenCount: 40000, debugDescription: "full"
                )),
                on: .claude
            ) == .contextOverflow(offerEscalation: false)
        )
        #expect(
            CoachError(languageModelError: LanguageModelError.rateLimited(.init(
                resetDate: nil, debugDescription: "slow down"
            ))) == .rateLimited(retryAfter: nil)
        )
        #expect(
            CoachError(languageModelError: LanguageModelError.timeout(.init(
                debugDescription: "timed out"
            ))) == .requestTimeout
        )
        #expect(
            CoachError(languageModelError: LanguageModelError.guardrailViolation(.init(
                debugDescription: "blocked"
            ))) == .declined
        )
        #expect(
            CoachError(languageModelError: LanguageModelError.refusal(.init(
                explanation: "no", debugDescription: "no"
            ))) == .declined
        )
        // The four `unsupported*` arms share one mapping line (sanitized
        // `debugDescription`); three are constructed here. The fourth,
        // `unsupportedTranscriptContent`, is not: its payload needs a
        // `[Transcript.Entry]`, which has no test-constructible init, so
        // the arm is covered by symmetry with its siblings, not by an
        // instance. Revisit if the SDK gains a lightweight `Entry` init.
        #expect(
            CoachError(languageModelError: LanguageModelError.unsupportedCapability(.init(
                capability: .toolCalling, debugDescription: "no tools here"
            ))) == .unsupported("no tools here")
        )
        #expect(
            CoachError(languageModelError: LanguageModelError.unsupportedGenerationGuide(.init(
                schemaName: nil, debugDescription: "bad guide"
            ))) == .unsupported("bad guide")
        )
        #expect(
            CoachError(languageModelError: LanguageModelError.unsupportedLanguageOrLocale(.init(
                languageCode: Locale.LanguageCode("en"), debugDescription: "no Klingon"
            ))) == .unsupported("no Klingon")
        )
        // Sanitizer contract (§7): multi-line, over-long payloads arrive
        // single-line and bounded -- never raw dumps.
        let messy = String(repeating: "x", count: 500) + "\nleaked line"
        let clean = CoachError.sanitizedSummary(messy)
        #expect(!clean.contains("\n"))
        #expect(clean.count <= 300)
        #expect(clean.hasSuffix("…"))
        #expect(CoachError.sanitizedSummary("short\nlines") == "short lines")
    }
#endif
}
