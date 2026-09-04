// PrivateCloudComputeSession.swift
//
// WP-28a: live PCC session construction. Gated file (the model type is
// 27-SDK-only): the stable matrix toolchain never sees this declaration.
//
// Why a free function, not a factory case: `CoachSessionFactory` stays
// provider-blind by design (WP-22 -- concrete over the on-device model,
// generalized only when the deployment floor allows). PCC dispatch opts in
// by injecting this build closure; the orchestrator's tier-aware cache
// keeps PCC conversation sessions separate from on-device ones.

#if swift(>=6.4)
    import Foundation
    import FoundationModels

    /// `CoachSessionFactory` build closure that answers every turn from the
    /// PCC model. Same `LiveCoachSession` adapter (streaming deltas,
    /// `@Generable` guides, transcripts) as on-device -- the D9 route rule:
    /// providers differ only in the model handed to the session.
    ///
    /// Same SDK availability as the model type; the app injects this only on
    /// the PCC tier path.
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
    @available(tvOS, unavailable)
    @MainActor
    public func makePrivateCloudComputeBuild() -> @MainActor @Sendable (String, [any Tool]) -> any CoachSession {
        makeProviderSessionBuild(model: PrivateCloudComputeLanguageModel())
    }
#endif
