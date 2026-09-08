// HealthKitAuth.swift
//
// WP-06 (implementation-plan.md) / architecture.md §2 (SyncKit module map),
// §4 D2 (writable types flow Google → HealthKit directly), §6 ("HealthKit
// write denied" error-posture row).
//
// Guarded with #if canImport(HealthKit) per WP-06's platform constraint — see
// HealthKitObjectTypeResolver.swift's header for the same note in more detail.

#if canImport(HealthKit)
import CoreModel
import HealthKit

/// Wraps a single shared `HKHealthStore` and mediates every HealthKit
/// read/write authorization request HealthLoom makes (architecture.md §2:
/// SyncKit; implementation-plan.md WP-06).
///
/// The app should construct exactly **one** `HealthKitAuth` and share it
/// (dependency-injected, same pattern as `Secrets.KeychainStore` and
/// `GoogleHealthClient.GoogleAuthManager`) rather than creating one per call
/// site — `HKHealthStore` is safe to share (it's `Sendable`), and Apple's own
/// guidance is one store per app.
///
/// ## HealthKit's read-denial blind spot
/// HealthKit **never reveals whether the user denied read access.** Only
/// write (share) denial is visible, via `HKHealthStore.authorizationStatus(for:)`
/// reporting `.sharingDenied` (see `writeStatus(for:)`). If a user denies read
/// access to, say, heart rate, that same query still reports whatever the
/// *write* status happens to be (usually `.sharingAuthorized` or
/// `.notDetermined` — the read decision doesn't change it), and any query
/// against denied-read data simply returns zero results, indistinguishable
/// from "no data recorded yet." **Every caller of `requestRead(_:)` must code
/// defensively**: treat an empty/zero result set as "no data OR denied read
/// access," never as a hard error, and never gate a user-facing flow solely on
/// a read query returning something.
public final class HealthKitAuth: Sendable {
    private let store: HKHealthStore

    /// P0 write set (implementation-plan.md WP-06 step 2 / architecture.md P0
    /// vertical slice): steps, heart rate, weight, sleep — the four
    /// `GoogleDataType`s whose `writability` the first onboarding permission
    /// sheet requests write access for. Derived from CoreModel's writability
    /// table, not hand-duplicated: `.steps` → `HKQuantityTypeIdentifierStepCount`,
    /// `.heartRate` → `HKQuantityTypeIdentifierHeartRate`, `.weight` →
    /// `HKQuantityTypeIdentifierBodyMass`, `.sleep` →
    /// `HKCategoryTypeIdentifierSleepAnalysis`.
    public static let p0WriteTypes: [GoogleDataType] = [.steps, .heartRate, .weight, .sleep]

    public init() {
        self.store = HKHealthStore()
    }

    /// `HKHealthStore.isHealthDataAvailable()` — false on iPad models without
    /// Health support, and always false on a host HealthKit doesn't run on at
    /// all (this package's macOS test host, per WP-06's platform constraint).
    /// Every other method here is safe to call regardless — they check this
    /// gate themselves — but UI code should check it up front to skip showing
    /// HealthKit-dependent screens entirely.
    public var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    /// Request write (share) authorization for `types`.
    ///
    /// Validates every type's HealthKit mapping *before* checking
    /// `isAvailable` or touching the store, so a request for a type with no
    /// HealthKit mapping (or an unresolvable identifier string) fails the same
    /// way on every platform — throwing `.noHealthKitMapping` /
    /// `.unresolvedIdentifier` — rather than being masked by an
    /// availability-gate short-circuit. Only once every type resolves does
    /// this check `isAvailable` (throwing `.healthDataUnavailable`, no system
    /// prompt shown, if false) and then call
    /// `HKHealthStore.requestAuthorization(toShare:read:)`.
    ///
    /// Fails fast on the first type that doesn't resolve — it does not
    /// silently drop that type and proceed with the rest.
    public func requestWrite(for types: [GoogleDataType]) async throws(HealthKitAuthError) {
        let sampleTypes = try resolveSampleTypes(for: types)
        guard isAvailable else { throw .healthDataUnavailable }
        do {
            try await store.requestAuthorization(toShare: sampleTypes, read: [])
        } catch {
            throw .underlying(String(describing: error))
        }
    }

    /// Request share AND read authorization in a single system prompt.
    ///
    /// Same validation order as the separate calls (every type in both sets
    /// must resolve before the `isAvailable` gate, before the store call),
    /// then one `HKHealthStore.requestAuthorization(toShare:read:)`.
    /// Prefer this whenever a screen needs both halves *now* (onboarding):
    /// two back-to-back `requestAuthorization` calls present the second
    /// sheet while the first is still dismissing, which HealthKit's remote
    /// presentation can reject with a "view is not in the window
    /// hierarchy" failure. Incremental callers that only need one half
    /// keep using `requestWrite(for:)` / `requestRead(_:)`.
    /// The exact share set `requestShareAndRead` requests (F10): the
    /// mapped types plus the writer's workout-attachment union. Public so
    /// WP-35's wipe derives from the same function the share sheet uses --
    /// a future share extension through this function lands in the wipe
    /// automatically; one through any other channel stays visible in
    /// review (this is the only share-set computation to grep).
    public func authorizedShareTypes(
        sharing types: [GoogleDataType],
        includingWorkoutShare: Bool
    ) throws(HealthKitAuthError) -> Set<HKSampleType> {
        var shareTypes = try resolveSampleTypes(for: types)
        if includingWorkoutShare {
            shareTypes.formUnion(HealthKitWriter.workoutShareTypes)
        }
        return shareTypes
    }

    public func requestShareAndRead(
        share: [GoogleDataType],
        read: [GoogleDataType],
        includingWorkoutShare: Bool = false
    ) async throws(HealthKitAuthError) {
        let shareTypes = try authorizedShareTypes(sharing: share, includingWorkoutShare: includingWorkoutShare)
        let readTypes = try resolveSampleTypes(for: read)
        // Workout-attachment buckets (cycling/swimming/rowing distance) are
        // unreachable from `GoogleDataType.writability`, so no type list
        // can ever authorize them -- without this union every cycled/swam/
        // (Workout-attachment rationale lives on `authorizedShareTypes`
        // above -- this call site just uses the shared computation.)
        guard isAvailable else { throw .healthDataUnavailable }
        do {
            try await store.requestAuthorization(
                toShare: shareTypes,
                read: Set(readTypes.map { $0 as HKObjectType })
            )
        } catch {
            throw .underlying(String(describing: error))
        }
    }

    /// Request read authorization for `types`.
    ///
    /// Shaped for **incremental** calls: pass only the types you need read
    /// access to *right now*. `HKHealthStore.requestAuthorization` only
    /// prompts for types whose authorization is still `.notDetermined` —
    /// types already granted or denied in an earlier call are silently
    /// no-ops — so calling this repeatedly with different (and growing) sets
    /// over the app's lifetime is the normal, correct usage pattern, not a
    /// workaround. Two known future call sites (implementation-plan.md
    /// WP-06 step 3): WP-12b's `WatchCoverageIndex` calls this with
    /// `[.exercise, .heartRate]` to detect Apple Watch recording windows; P2's
    /// `KnowledgeStore` calls it later with its own (larger, unrelated) read
    /// set. Neither needs to know about the other's requested types.
    ///
    /// Same validation order as `requestWrite(for:)`: type mapping is
    /// resolved before the `isAvailable` gate, before the store call.
    ///
    /// **Read denial is invisible — see this type's header.** A successful
    /// return from this method does not mean the user will actually see data
    /// when queried; it only means the permission prompt (if any) was shown
    /// and the call itself didn't fail.
    public func requestRead(_ types: [GoogleDataType]) async throws(HealthKitAuthError) {
        let sampleTypes = try resolveSampleTypes(for: types)
        guard isAvailable else { throw .healthDataUnavailable }
        let readTypes = Set(sampleTypes.map { $0 as HKObjectType })
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
        } catch {
            throw .underlying(String(describing: error))
        }
    }

    /// Current write (share) authorization status for `type`
    /// (implementation-plan.md WP-06 step 4).
    ///
    /// Returns `.notDetermined` without querying the store at all when
    /// `isAvailable` is false, or when `type` has no resolvable HealthKit
    /// mapping (`.localOnly`/`.skip` writability, or an identifier string this
    /// package's classifier doesn't recognize) — there is nothing to
    /// determine in either case. Otherwise maps
    /// `HKAuthorizationStatus.sharingAuthorized` → `.authorized`,
    /// `.sharingDenied` → `.denied`, `.notDetermined` → `.notDetermined`.
    ///
    /// This reports **write** status only — see this type's header for why
    /// there is no read-status equivalent.
    public func writeStatus(for type: GoogleDataType) -> HealthKitAuthorizationStatus {
        guard isAvailable, let sampleType = try? resolveSampleType(for: type) else {
            return .notDetermined
        }
        switch store.authorizationStatus(for: sampleType) {
        case .sharingAuthorized:
            return .authorized
        case .sharingDenied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }

    // MARK: - Private

    private func resolveSampleTypes(
        for types: [GoogleDataType]
    ) throws(HealthKitAuthError) -> Set<HKSampleType> {
        var result = Set<HKSampleType>()
        for type in types {
            result.insert(try resolveSampleType(for: type))
        }
        return result
    }

    /// Maps one type the way `requestShareAndRead` does (WP-35's wipe
    /// set derives from this, so wipe covers exactly what onboarding
    /// authorized — a future P0 addition lands in both or neither).
    public func resolveSampleType(
        for type: GoogleDataType
    ) throws(HealthKitAuthError) -> HKSampleType {
        guard case .healthKit(let identifier) = type.writability else {
            throw .noHealthKitMapping(type)
        }
        do {
            return try HealthKitObjectTypeResolver.sampleType(for: identifier)
        } catch {
            throw .unresolvedIdentifier(dataType: type, identifier: identifier)
        }
    }
}
#endif
