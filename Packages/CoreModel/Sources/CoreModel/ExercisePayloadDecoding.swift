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
    /// Display title: the API's `displayName` when it sends one, else the
    /// title-cased `exerciseType` ("TRAIL_RUN" → "Trail Run").
    public let activityName: String?
    /// The raw `Exercise.ExerciseType` enum value ("RUNNING"), for anything
    /// that classifies activities -- names are for people, this is for code.
    public let exerciseType: String?
    public let distanceMeters: Double?
    public let energyKilocalories: Double?

    public init(activityName: String?, exerciseType: String? = nil, distanceMeters: Double?, energyKilocalories: Double?) {
        self.activityName = activityName
        self.exerciseType = exerciseType
        self.distanceMeters = distanceMeters
        self.energyKilocalories = energyKilocalories
    }
}

extension LocalSample {
    /// WP-51: `sessionPayload` is the API's typed `exercise` object --
    /// `exerciseType`, `displayName`, and `metricsSummary` with
    /// `distanceMillimeters` / `caloriesKcal` (published v4 reference). The
    /// pre-WP-51 keys (`exercise.activity_type` ...) never matched a real
    /// response.
    public var decodedExercisePayload: ExercisePayloadFields {
        guard let envelope = try? JSONSerialization.jsonObject(with: payloadJSON) as? [String: Any],
              let sessionBase64 = envelope["sessionPayload"] as? String,
              let sessionData = Data(base64Encoded: sessionBase64),
              let session = try? JSONSerialization.jsonObject(with: sessionData) as? [String: Any] else {
            return ExercisePayloadFields(activityName: nil, distanceMeters: nil, energyKilocalories: nil)
        }
        let exerciseType = session["exerciseType"] as? String
        let displayName = (session["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let metrics = session["metricsSummary"] as? [String: Any]
        return ExercisePayloadFields(
            activityName: displayName ?? exerciseType.map { GoogleDataType.titleCased($0.lowercased()) },
            exerciseType: exerciseType,
            distanceMeters: (metrics?["distanceMillimeters"] as? Double).map { $0 / 1000 },
            energyKilocalories: metrics?["caloriesKcal"] as? Double
        )
    }
}
