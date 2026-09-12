// OnboardingSkipGoogleTests.swift
//
// Onboarding-skip-Google: unit pins for the skip flag (single source of truth) and
// background-sync quiescence without credentials. The flow copy and the end-to-end
// skip path ride in `OnboardingUITests.testOnboardingSkipGooglePath` (needs a
// launched app); `FirstSyncView`'s skipped branch is declarative (no logic to unit
// test beyond "never calls syncAll", which the UI test proves by reaching Continue
// with no OAuth and no error rows).

import CoreModel
import Foundation
import GoogleHealthClient
import HealthKit
import SwiftData
import SyncKit
import Testing
@testable import HealthLoom

@Suite("GoogleConnectionSetting persistence")
struct GoogleConnectionSettingTests {
    private func makeDefaults() throws -> EphemeralDefaults {
        try EphemeralDefaults(prefix: "skipgoogle")
    }

    @Test func skipRoundTripsAndStartsClear() throws {
        // Catches: the skip must be explicit and persisted (single source) — a fresh
        // domain reads clear, set reads set, clear reads clear again.
        let ephemeral = try makeDefaults()
        let setting = GoogleConnectionSetting(defaults: ephemeral.defaults)
        #expect(setting.isSkipped == false)
        setting.setSkipped()
        #expect(setting.isSkipped == true)
        // A fresh instance over the same defaults sees it (no reload protocol).
        #expect(GoogleConnectionSetting(defaults: ephemeral.defaults).isSkipped == true)
        setting.clearSkipped()
        #expect(GoogleConnectionSetting(defaults: ephemeral.defaults).isSkipped == false)
    }

    @Test func skipKeyIsIsolatedFromSyncPreferences() throws {
        // Catches: literal drift — the skip key must not collide with the disabled-types
        // key (a collision would wipe toggles on clear, or misread them as skipped).
        let ephemeral = try makeDefaults()
        let prefs = SyncPreferences(defaults: ephemeral.defaults)
        prefs.setEnabled(false, for: .steps)
        GoogleConnectionSetting(defaults: ephemeral.defaults).setSkipped()
        GoogleConnectionSetting(defaults: ephemeral.defaults).clearSkipped()
        #expect(SyncPreferences(defaults: ephemeral.defaults).isEnabled(.steps) == false)
    }
}

/// Minimal recording reconcile client (local to this file — `BGStubReconcileClient`
/// is file-private to `BackgroundSyncTests.swift`).
private final class SkipRecordingReconcileClient: GoogleReconcileClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [GoogleDataType] = []

    nonisolated func reconcile(
        type: GoogleDataType,
        since: Date,
        until: Date,
        pageToken: String?
    ) async throws(GoogleHealthClientError) -> Page {
        lock.withLock { calls.append(type) }
        return Page(points: [], nextPageToken: nil)
    }
}

@Suite("BackgroundSync credentials quiescence")
@MainActor
struct BackgroundSyncQuiescenceTests {
    @Test func noCredentialsStaysQuiet() async throws {
        // Catches: without a stored refresh token (skipped or never-consented), a
        // background wake must return [] with zero pulls — the old path minted
        // per-type `.unauthorized` error rows every wake.
        let container = try CoreModel.makeContainer(inMemory: true)
        let client = SkipRecordingReconcileClient()
        let context = BackgroundSyncLaunchContext(
            modelContainer: container,
            syncEngine: SyncEngine(
                client: client,
                writer: HealthKitWriter(),
                modelContainer: container
            ),
            syncableTypes: [.steps, .heartRate],
            hasGoogleCredentials: { false }
        )
        let outcomes = await HealthLoomBackgroundSync.run(context: context)
        #expect(outcomes.isEmpty)
        #expect(client.calls.isEmpty)
        #expect(HealthLoomBackgroundSync.backgroundTaskSucceeded(outcomes))
    }

    @Test func credentialsPresentRunsNormally() async throws {
        // Pin: the gate passes through when credentials exist — a `.localOnly` type
        // upserts with no HealthKit store touch, so this needs no health store double.
        let container = try CoreModel.makeContainer(inMemory: true)
        let client = SkipRecordingReconcileClient()
        let context = BackgroundSyncLaunchContext(
            modelContainer: container,
            syncEngine: SyncEngine(
                client: client,
                writer: HealthKitWriter(),
                modelContainer: container
            ),
            syncableTypes: [.electrocardiogram],
            hasGoogleCredentials: { true }
        )
        let outcomes = await HealthLoomBackgroundSync.run(context: context)
        #expect(client.calls == [.electrocardiogram])
        #expect(outcomes.map(\.dataType) == [.electrocardiogram])
    }
}
