// ProviderSession.swift
//
// WP-85: session construction for off-device providers behind the D9 seam.
// Every provider's `LanguageModel` conformance answers the same session,
// streaming, `@Generable` and tool surface, so one adapter
// (`LiveCoachSession`) serves them all: providers differ only in the model
// handed to the session. Generic over the model, not existential.
//
// The `LanguageModel` protocol is 27-SDK-only, so this carries the SDK's
// own availability; package tests on macOS 26 hosts never call it.

#if swift(>=6.4)
    import Foundation
    import FoundationModels

    /// A `CoachSession` answering from `model`, for a provider build
    /// (`CoachSessionFactory.ProviderBuild`) defined outside CoachKit.
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
    @available(tvOS, unavailable)
    @MainActor
    public func makeProviderSession<Model: LanguageModel>(
        model: Model,
        instructions: String,
        tools: [any Tool],
        servedModelID: (@Sendable (Transcript.Response) -> String?)? = nil
    ) -> any CoachSession {
        LiveCoachSession(
            session: LanguageModelSession(model: model, tools: tools, instructions: instructions),
            modelIDOfResponse: servedModelID
        )
    }
#endif
