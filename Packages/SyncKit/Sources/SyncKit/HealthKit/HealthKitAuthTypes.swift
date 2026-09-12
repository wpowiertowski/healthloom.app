// HealthKitAuthTypes.swift
//
// WP-06 (implementation-plan.md) / architecture.md §2 (SyncKit), §6 ("HealthKit
// write denied" error-posture row).
//
// Deliberately HealthKit-import-free: this file only imports CoreModel, so
// HealthLoom's own vocabulary for auth status/errors is usable from any code —
// tests included — without pulling in HealthKit. Only `HealthKitAuth` and
// `HealthKitObjectTypeResolver` (which actually touch `HK*` types) live behind
// `#if canImport(HealthKit)`; see those files' headers for why.

import CoreModel

/// HealthLoom's own per-type HealthKit **write** (share) authorization status,
/// decoupled from `HKAuthorizationStatus` so it can be referenced without
/// importing HealthKit.
///
/// Mapping from `HKAuthorizationStatus` (see `HealthKitAuth.writeStatus(for:)`):
/// `.sharingAuthorized` → `.authorized`, `.sharingDenied` → `.denied`,
/// `.notDetermined` → `.notDetermined`.
///
/// This status is meaningful for **write** only. HealthKit has no equivalent
/// query for read authorization — see `HealthKitAuth.requestRead(_:)`'s doc
/// comment for why every read-path caller must code defensively instead.
public enum HealthKitAuthorizationStatus: String, Sendable, Hashable, CaseIterable, Codable {
    case authorized
    case denied
    case notDetermined
}

/// Error surface for `HealthKitAuth` and the identifier-resolution layer it
/// builds on. Per WP-06: an unresolvable HealthKit identifier string must be
/// surfaced, never silently dropped from a requested set — every case here
/// exists so a caller can find out *which* type/string failed and why, instead
/// of a request silently requesting fewer types than asked.
public enum HealthKitAuthError: Error, Sendable, Equatable, CustomStringConvertible {
    /// `HKHealthStore.isHealthDataAvailable()` is `false` on this device/host
    /// (e.g. an iPad model without Health support, or a platform HealthKit
    /// doesn't run on at all — this package's macOS test host, per WP-06's
    /// platform constraint). No system prompt is shown; nothing was requested.
    case healthDataUnavailable

    /// `dataType`'s `GoogleDataType.writability` isn't `.healthKit` (it's
    /// `.localOnly` or `.skip`) — there is no HealthKit type to request
    /// authorization for, so the request for this type is rejected outright
    /// rather than silently skipped.
    case noHealthKitMapping(GoogleDataType)

    /// `dataType`'s writability **is** `.healthKit(identifier)`, but
    /// `identifier` didn't resolve to any known HealthKit
    /// quantity/category/workout/correlation type (see
    /// `HealthKitIdentifierClassifier`). This should never happen for a
    /// `GoogleDataType` case CoreModel currently ships — the
    /// `HealthKitIdentifierClassifier` completeness test (`SyncKitTests`)
    /// guards exactly that — so seeing this in practice means CoreModel added
    /// a new `.healthKit` writability string this package's classifier
    /// doesn't yet recognize; both need updating together.
    case unresolvedIdentifier(dataType: GoogleDataType, identifier: String)

    /// `dataType` resolves to a HealthKit type HealthKit forbids requesting share
    /// (write) authorization for — correlation types such as Food: passing one in
    /// `toShare` throws an uncatchable `NSInvalidArgumentException` ("Authorization
    /// to share ... is disallowed") that terminates the app, NOT a Swift error.
    /// Thrown by `requestWrite(for:)` (fail loud, naming the type) instead of
    /// crashing; the combined `requestShareAndRead` routes such types to `read`
    /// instead (see `HealthKitAuth.partitionedAuthorization`).
    case sharingDisallowed(dataType: GoogleDataType, identifier: String)

    /// The underlying `HKHealthStore` call itself failed. Carries only the
    /// error's string description (matches architecture.md D11's redaction
    /// posture: no health values, no tokens — and there are none to leak here
    /// regardless, but the convention is kept consistent across packages).
    case underlying(String)

    public var description: String {
        switch self {
        case .healthDataUnavailable:
            return "HealthKitAuthError.healthDataUnavailable"
        case .noHealthKitMapping(let dataType):
            return "HealthKitAuthError.noHealthKitMapping(\(dataType))"
        case .unresolvedIdentifier(let dataType, let identifier):
            return "HealthKitAuthError.unresolvedIdentifier(dataType: \(dataType), identifier: \"\(identifier)\")"
        case .sharingDisallowed(let dataType, let identifier):
            return "HealthKitAuthError.sharingDisallowed(dataType: \(dataType), identifier: \"\(identifier)\")"
        case .underlying(let message):
            return "HealthKitAuthError.underlying(\(message))"
        }
    }
}
