// ExercisePayloadDecoding.swift
// CoreModel
//
// Code review (2026-08-28), finding #14: `CoachKit`'s `KnowledgeStore` and
// the app target's Activities view (WP-12b) each hand-duplicated an
// identical `JSONSerialization`-based decoder for a `.exercise`-type
// `LocalSample.payloadJSON`'s `sessionPayload` field. `LocalSample`'s own
// header explains why `payloadJSON` has no shared/public schema (SyncEngine/
// BackfillCoordinator each encode it via a private, file-local `Codable`
// struct) -- but the *decode* side has no such reason to be duplicated: both
// call sites decode the exact same wire shape for the exact same reason
// (rendering a Fitbit-session supplement), so this is the one shared
// implementation both depend on instead of two copies that can silently
// diverge if the wire shape ever changes.

import Foundation

/// The Google Exercise session fields embedded in an `.exercise`-type
/// `LocalSample.payloadJSON` (see `LocalSample.decodedExercisePayload`).
/// Every field is `nil` when decoding finds nothing -- never a thrown error,
/// matching `LocalSample.payloadJSON`'s documented "no schema" posture.
///
/// `nonisolated`: `@Model`-generated types are themselves `nonisolated`
/// (they must be usable from SwiftData's background contexts, overriding
/// CoreModel's package-wide `.defaultIsolation(MainActor.self)` for their
/// own members), and `LocalSample.decodedExercisePayload`'s isolation is
/// inferred from `LocalSample` -- the type it extends -- not from the
/// module default. Without this annotation, constructing this plain struct
/// (which *would* get the module's MainActor default, having no base type
/// of its own to infer from) from that nonisolated context fails to build.
nonisolated public struct ExercisePayloadFields: Sendable, Hashable {
    public let activityName: String?
    public let distanceMeters: Double?
    public let energyKilocalories: Double?

    public init(activityName: String?, distanceMeters: Double?, energyKilocalories: Double?) {
        self.activityName = activityName
        self.distanceMeters = distanceMeters
        self.energyKilocalories = energyKilocalories
    }
}

extension LocalSample {
    /// Decodes `payloadJSON`'s `sessionPayload` key (base64 `Data` under
    /// `JSONEncoder`'s default strategy, itself holding another JSON object)
    /// for a `.exercise`-type sample: the Google Exercise session's own
    /// fields (`exercise.activity_type` / `exercise.distance` (m) /
    /// `exercise.energy` (kcal) -- SyncKit's `ExerciseSessionDecoding.swift`
    /// wire shape). Degrades to all-`nil` fields on any decode failure at
    /// any level -- never throws.
    public var decodedExercisePayload: ExercisePayloadFields {
        guard let envelope = try? JSONSerialization.jsonObject(with: payloadJSON) as? [String: Any],
              let sessionBase64 = envelope["sessionPayload"] as? String,
              let sessionData = Data(base64Encoded: sessionBase64),
              let session = try? JSONSerialization.jsonObject(with: sessionData) as? [String: Any] else {
            return ExercisePayloadFields(activityName: nil, distanceMeters: nil, energyKilocalories: nil)
        }
        let activityName = (session["exercise.activity_type"] as? String).map(GoogleDataType.titleCased)
        return ExercisePayloadFields(
            activityName: activityName,
            distanceMeters: session["exercise.distance"] as? Double,
            energyKilocalories: session["exercise.energy"] as? Double
        )
    }
}
