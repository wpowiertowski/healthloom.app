// HealthKitStoreIntegrationTests.swift
//
// test-plan.md §3 "HealthKit store (real)": save -> query-by-external-ID
// finds -> re-save skipped -> delete-by-externalID removes only target. This
// is that test, run against the REAL `HealthKitStore`/`HealthKitWriter`
// (HealthStoreProtocol.swift / HealthKitWriter.swift) wrapping a genuine
// `HKHealthStore` -- the integration-tier counterpart to
// HealthKitWriterTests.swift's mock-store suite, which covers the same
// behaviors against `MockHealthStore` and needs no entitlement at all.
//
// Gated exactly the way WP-03's KeychainSecurityBackendTests.swift gates its
// real-Keychain round-trip (see that file for the precedent this follows): a
// synchronous, side-effect-free probe checks whether this process already
// has real HealthKit *write* authorization for steps before attempting
// anything, via `.enabled(if:)`. HealthKit authorization can only ever be
// granted through interactive UI (there is no programmatic grant), so a
// headless `swift test`/`xcodebuild test` run can never satisfy this probe on
// its own -- this suite is expected to skip itself in this session (this
// repo's macOS test host reports `HKHealthStore.isHealthDataAvailable() ==
// false`, exactly as WP-06/WP-07 both already found) and is flagged as a
// required follow-up in progress.md's WP-08 entry: re-run on a real device or
// simulator where HealthLoom has already been launched once and the user
// granted write access to steps (and ideally heart rate/weight/sleep) via the
// real onboarding flow (WP-10).

#if canImport(HealthKit)
import Foundation
import HealthKit
import Testing
@testable import SyncKit

/// True only if this process can write `HKQuantityTypeIdentifier.stepCount`
/// samples *right now* -- HealthKit must be available on this host *and* a
/// prior authorization request for this type must already have been granted
/// (`.sharingAuthorized`). Purely a status read (`HKHealthStore
/// .authorizationStatus(for:)`); it never attempts a write and has no side
/// effects, so it's safe to call unconditionally as a trait condition.
nonisolated private func hasRealHealthKitStepWriteAuthorization() -> Bool {
    guard HKHealthStore.isHealthDataAvailable() else { return false }
    guard let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) else { return false }
    return HKHealthStore().authorizationStatus(for: stepType) == .sharingAuthorized
}

@Suite("HealthKitWriter against the real HKHealthStore (integration)")
struct HealthKitStoreIntegrationTests {
    private static let stepsType = HKObjectType.quantityType(forIdentifier: .stepCount)!

    @Test(
        "real store: save -> existingExternalIDs finds it -> re-save is skipped by the diff -> delete-by-externalID removes only the target",
        .enabled(
            if: hasRealHealthKitStepWriteAuthorization(),
            """
            Real HealthKit write authorization for HKQuantityTypeIdentifierStepCount \
            is not currently granted to this test process. Most commonly this is \
            because HealthKit isn't available on this host at all \
            (HKHealthStore.isHealthDataAvailable() reports false on this repo's \
            macOS test host, and a freshly-booted iOS Simulator has no prior grant \
            either, since HealthKit authorization can only ever be requested via \
            interactive UI -- never headlessly, never programmatically). This is a \
            known environment gap, not a bug in HealthKitStore/HealthKitWriter -- \
            see progress.md's WP-08 entry, which flags re-running this suite on a \
            real device/simulator with granted authorization as required follow-up. \
            The required save/dedupe/delete-by-externalID/delete-by-source behavior \
            is still fully verified by HealthKitWriterTests against MockHealthStore, \
            which needs no entitlement at all.
            """
        )
    )
    func realHealthKitStoreRoundTrip() async throws {
        let healthStore = HKHealthStore()
        // Idempotent no-op if already granted (HealthKitAuth.swift's doc
        // comment: HKHealthStore.requestAuthorization only prompts for types
        // still .notDetermined) -- included defensively in case the probe's
        // read was stale.
        try await healthStore.requestAuthorization(toShare: [Self.stepsType], read: [])

        let writer = HealthKitWriter(healthStore: healthStore)
        let externalID = "wp08-integration-\(UUID().uuidString)"
        let start = Date().addingTimeInterval(-3_600)
        let end = Date()
        let sample = HKQuantitySample(
            type: Self.stepsType,
            quantity: HKQuantity(unit: .count(), doubleValue: 42),
            start: start,
            end: end,
            metadata: [HKMetadataKeyExternalUUID: externalID, MappedMetadata.externalIDKey: externalID]
        )
        let window = (start: start.addingTimeInterval(-60), end: end.addingTimeInterval(60))

        // Best-effort clean slate in case a previous run of this suite
        // crashed before reaching its own cleanup below.
        _ = try? await writer.delete(externalIDs: [externalID], type: Self.stepsType)

        // 1. save
        try await writer.save([sample])

        // 2. existingExternalIDs (the batched D4 existence query) finds it
        let foundAfterSave = try await writer.existingExternalIDs(
            type: Self.stepsType, start: window.start, end: window.end
        )
        #expect(foundAfterSave.contains(externalID))

        // 3. re-save is skipped by the diff: a caller (WP-09's SyncEngine)
        // filters its incoming batch against `existingExternalIDs`'s result
        // before calling `save` again -- confirm that filter would correctly
        // drop this sample, then prove save([]) is a true no-op against the
        // real store too.
        let toResave = [sample].filter { _ in !foundAfterSave.contains(externalID) }
        #expect(toResave.isEmpty)
        try await writer.save(toResave)

        // 4. delete-by-externalID removes only the target
        let deletedCount = try await writer.delete(externalIDs: [externalID], type: Self.stepsType)
        #expect(deletedCount == 1)
        let foundAfterDelete = try await writer.existingExternalIDs(
            type: Self.stepsType, start: window.start, end: window.end
        )
        #expect(!foundAfterDelete.contains(externalID))
    }
}
#endif
