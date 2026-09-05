// HealthKitPermissionView.swift
//
// WP-10 (implementation-plan.md): onboarding step 2 of 4 -- calls
// `HealthKitAuth.requestWrite(for:)` for the P0 types (steps, heart rate,
// weight, sleep) and handles both the HK-unavailable state (architecture.md
// §6: "HealthKit write denied" row's sibling case, `isHealthDataAvailable()
// == false`, e.g. an iPad) and generic request failures.
//
// Real API discovered here (progress.md's WP-06 entry, `HealthKitAuth
// .swift`): `requestWrite(for:)` throws typed `HealthKitAuthError` and
// never reports *per-type* denial itself -- HealthKit resolves the
// completion handler once the system sheet is dismissed regardless of which
// individual toggles the user left on/off. Per-type write denial is only
// ever visible later via `writeStatus(for:)`, which is exactly what the
// WP-10 dashboard's status badges read (`SyncTypeRow.swift`) -- this screen
// itself does not attempt to detect single-type denial.

import CoreModel
import SwiftUI
import SyncKit

struct HealthKitPermissionView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    var onUnavailable: () -> Void
    var onGranted: () -> Void

    @State private var isRequesting = false
    @State private var errorMessage: String?

    var body: some View {
        OnboardingScaffold(
            step: .healthKit,
            symbol: "heart.text.square.fill",
            title: "Connect Apple Health",
            message: "HealthLoom needs permission to write your steps, heart rate, weight, and sleep data to Apple Health. It also asks to read your workouts and heart rate so activities your Apple Watch already recorded aren't double-counted when your Fitbit data arrives."
        ) {
            if let errorMessage {
                OnboardingErrorPanel(
                    message: errorMessage,
                    accessibilityIdentifier: "onboarding.healthkit.error"
                )
                .padding(.top, 20)
            }
        } actions: {
            OnboardingPrimaryButton(
                title: "Allow Access",
                isLoading: isRequesting,
                accessibilityIdentifier: "onboarding.healthkit.allow",
                action: requestAccess
            )
            .disabled(isRequesting)
        }
        // No container-level identifier -- see WelcomeView.swift's note:
        // it would override the more specific `onboarding.healthkit.allow`/
        // `.error` identifiers, which are passed into the themed components
        // above and applied directly to their own leaf views.
        .task {
            // Gate up front (WP-06's `isAvailable`, `HKHealthStore
            // .isHealthDataAvailable()`) so a device that can never grant
            // HealthKit access (e.g. an iPad model without Health support)
            // skips straight to the dedicated unavailable screen instead of
            // showing an "Allow Access" button that can only fail.
            if !appEnvironment.healthKitAuth.isAvailable {
                onUnavailable()
            }
        }
    }

    private func requestAccess() {
        guard appEnvironment.healthKitAuth.isAvailable else {
            onUnavailable()
            return
        }
        isRequesting = true
        errorMessage = nil
        Task {
            do {
                // One combined system sheet (share + read in a single
                // `requestAuthorization`): two back-to-back requests present
                // the second sheet while the first is still dismissing,
                // which HealthKit's remote presentation rejects with a
                // "view is not in the window hierarchy" failure. The
                // separate `requestWrite`/`requestRead` APIs stay for
                // incremental callers (WP-06); onboarding needs both halves
                // now, so it takes the combined path.
                //
                // WP-12b (architecture.md D13.1): read access to workouts +
                // heart rate so `WatchCoverageIndex` can detect Apple Watch
                // recording windows -- the copy above explains why. A read
                // denial is invisible to the app by design (reads never
                // reveal denial -- the resolver just sees no coverage and
                // imports Fitbit data as before, D13's graceful floor).
                //
                // WP-33 widened this read set to the Today view's metric
                // kinds (TodayMetricsProvider.swift) -- steps, sleep,
                // weight, blood oxygen, distance, active energy -- same
                // single sheet, same invisible-denial posture: a denied
                // read just renders that row's "No data yet" state.
                try await appEnvironment.healthKitAuth.requestShareAndRead(
                    share: AppEnvironment.p0Types,
                    read: [
                        .exercise, .heartRate, .steps, .sleep, .weight,
                        .oxygenSaturation, .distance, .activeEnergyBurned,
                    ],
                    // Workout saves (and their cycling/swimming/rowing
                    // distance attachments) need share types no
                    // `GoogleDataType` maps to -- unioned into this same
                    // single sheet, derived from the writer's table.
                    includingWorkoutShare: true
                )
                isRequesting = false
                onGranted()
            } catch {
                isRequesting = false
                errorMessage = String(describing: error)
            }
        }
    }
}

#Preview {
    HealthKitPermissionView(onUnavailable: {}, onGranted: {})
        .environment(AppEnvironment())
}
