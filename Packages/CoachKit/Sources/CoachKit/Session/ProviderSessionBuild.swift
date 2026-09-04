// ProviderSessionBuild.swift
//
// WP-28: provider session construction behind the D9 seam. Gated file (the
// `LanguageModel` protocol is 27-SDK-only): the stable matrix toolchain
// never sees this declaration.
//
// `CoachSessionFactory` stays provider-blind (WP-22) -- off-device tiers
// opt in by injecting the build closure this returns. Generic over the
// model (not existential): every provider's conformance answers the same
// session/streaming/`@Generable`/tool surface, so one construction point
// serves PCC, Claude, and Gemini.

#if swift(>=6.4)
    import Foundation
    import FoundationModels

    /// `CoachSessionFactory` build closure answering from `model`: the same
    /// `LiveCoachSession` adapter as on-device (streaming deltas,
    /// `@Generable` guides, transcripts) -- providers differ only in the
    /// model handed to the session.
    ///
    /// Same SDK availability as the protocol itself. Callers inject the
    /// result as `CoachSessionFactory(build:)`; the orchestrator's
    /// tier-aware cache keeps provider conversation sessions separate.
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
    @available(tvOS, unavailable)
    @MainActor
    public func makeProviderSessionBuild<Model: LanguageModel>(
        model: Model
    ) -> @MainActor @Sendable (String, [any Tool]) -> any CoachSession {
        { instructions, tools in
            LiveCoachSession(
                session: LanguageModelSession(model: model, tools: tools, instructions: instructions)
            )
        }
    }
#endif
