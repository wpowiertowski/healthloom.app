// HealthKitAuthTests.swift
//
// WP-06 (implementation-plan.md): exercises HealthKitAuth's own logic — type
// validation ordering, the isAvailable gate, and writeStatus's fallback —
// without ever triggering a real HealthKit permission prompt (this suite
// never calls requestAuthorization on a host where isAvailable is true).
//
// Guarded with #if canImport(HealthKit), matching HealthKitAuth itself.

#if canImport(HealthKit)
import CoreModel
import HealthKit
import Testing
@testable import SyncKit

@Suite struct HealthKitAuthTests {
    /// `requestWrite`/`requestRead` validate every type's HealthKit mapping
    /// *before* touching `isAvailable` or the store, so a `.localOnly`/`.skip`
    /// type is rejected the same way on every platform, regardless of whether
    /// this host actually has HealthKit data available.
    @Test func requestWriteThrowsNoHealthKitMappingForLocalOnlyType() async {
        let auth = HealthKitAuth()
        await #expect {
            try await auth.requestWrite(for: [.electrocardiogram])
        } throws: { error in
            guard case .noHealthKitMapping(.electrocardiogram) = error as? HealthKitAuthError else {
                return false
            }
            return true
        }
    }

    /// `requestShareAndRead` validates *both* sets before the
    /// `isAvailable` gate, so a bad mapping on either side is rejected the
    /// same way on every platform -- including the simulator, where the
    /// combined onboarding call must fail for the mapping reason, never
    /// with a presentation collision.
    @Test func requestShareAndReadThrowsNoHealthKitMappingForBadShareType() async {
        let auth = HealthKitAuth()
        await #expect {
            try await auth.requestShareAndRead(share: [.electrocardiogram], read: [.steps])
        } throws: { error in
            guard case .noHealthKitMapping(.electrocardiogram) = error as? HealthKitAuthError else {
                return false
            }
            return true
        }
    }

    @Test func requestShareAndReadThrowsNoHealthKitMappingForBadReadType() async {
        let auth = HealthKitAuth()
        await #expect {
            try await auth.requestShareAndRead(share: [.steps], read: [.activityLevel])
        } throws: { error in
            guard case .noHealthKitMapping(.activityLevel) = error as? HealthKitAuthError else {
                return false
            }
            return true
        }
    }

    @Test func requestShareAndReadThrowsHealthDataUnavailableWhenGated() async {
        let auth = HealthKitAuth()
        guard !auth.isAvailable else { return }
        await #expect {
            try await auth.requestShareAndRead(share: HealthKitAuth.p0WriteTypes, read: [.steps])
        } throws: { error in
            guard case .healthDataUnavailable = error as? HealthKitAuthError else { return false }
            return true
        }
    }

    @Test func requestReadThrowsNoHealthKitMappingForSkipType() async {
        let auth = HealthKitAuth()
        await #expect {
            try await auth.requestRead([.activityLevel])
        } throws: { error in
            guard case .noHealthKitMapping(.activityLevel) = error as? HealthKitAuthError else {
                return false
            }
            return true
        }
    }

    /// `writeStatus(for:)` never throws; for a type with no HealthKit mapping
    /// it deterministically reports `.notDetermined` -- there is nothing to
    /// determine.
    @Test func writeStatusIsNotDeterminedForLocalOnlyType() {
        let auth = HealthKitAuth()
        #expect(auth.writeStatus(for: .electrocardiogram) == .notDetermined)
    }

    @Test func writeStatusIsNotDeterminedForSkipType() {
        let auth = HealthKitAuth()
        #expect(auth.writeStatus(for: .activityLevel) == .notDetermined)
    }

    /// Once every requested type resolves successfully, `requestWrite`/
    /// `requestRead` check `isAvailable` before calling the store. On this
    /// package's macOS test host `HKHealthStore.isHealthDataAvailable()` is
    /// false (WP-06's platform constraint), so a valid P0 request throws
    /// `.healthDataUnavailable` rather than presenting a system prompt. If
    /// this ever runs somewhere HealthKit data genuinely is available, the
    /// gate doesn't apply and this test steps aside rather than asserting the
    /// wrong thing.
    @Test func requestWriteThrowsHealthDataUnavailableWhenGated() async {
        let auth = HealthKitAuth()
        guard !auth.isAvailable else { return }
        await #expect {
            try await auth.requestWrite(for: HealthKitAuth.p0WriteTypes)
        } throws: { error in
            guard case .healthDataUnavailable = error as? HealthKitAuthError else { return false }
            return true
        }
    }

    @Test func requestReadThrowsHealthDataUnavailableWhenGated() async {
        let auth = HealthKitAuth()
        guard !auth.isAvailable else { return }
        await #expect {
            try await auth.requestRead([.exercise, .heartRate])
        } throws: { error in
            guard case .healthDataUnavailable = error as? HealthKitAuthError else { return false }
            return true
        }
    }

    /// `writeStatus(for:)` short-circuits to `.notDetermined` without
    /// querying the store when `isAvailable` is false -- same host-dependent
    /// caveat as above.
    @Test func writeStatusIsNotDeterminedWhenHealthDataUnavailable() {
        let auth = HealthKitAuth()
        guard !auth.isAvailable else { return }
        for type in HealthKitAuth.p0WriteTypes {
            #expect(auth.writeStatus(for: type) == .notDetermined)
        }
    }

    /// The P0 write set is exactly the four types WP-06 step 2 names.
    @Test func p0WriteTypesMatchesSpec() {
        #expect(HealthKitAuth.p0WriteTypes == [.steps, .heartRate, .weight, .sleep])
    }
}
#endif
