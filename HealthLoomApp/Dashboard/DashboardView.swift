// DashboardView.swift
//
// WP-10 (implementation-plan.md step 2): "Dashboard list: 4 types x
// (last-sync time, item count, status icon, error text) driven by
// SyncState; a 'Sync now' button calling syncAll; a data-freshness header
// ('data reaches Google ~15 min after device sync' -- set expectations,
// D-context §1)."
//
// Driven by `@Query` over CoreModel's `SyncState` (SwiftData), reading from
// whichever `ModelContainer` `HealthLoomApp` put in the environment via
// `.modelContainer(_:)` -- production, or an in-memory one seeded by
// `AppEnvironment.seedDashboardFixtures` under `-UITestSeedData`. "Sync now"
// calls the exact same `SyncEngine.syncAll(types:)` onboarding's
// `FirstSyncView` calls; `@Query` picks up whatever that run persists to
// `SyncState` without this view re-fetching manually.
//
// WP-14 (implementation-plan.md): a second `@Query`, over CoreModel's
// `LocalSample`, drives a second section for the four `.localOnly`-writability
// types (architecture.md D2) -- these don't have a `SyncState` row of their
// own to key off of (they never touch HealthKit), so they're grouped
// client-side by `LocalSample.dataType` instead and rendered via
// `LocalOnlyTypeRow`, not `SyncTypeRow`. Deliberately **not** wired into
// `syncNow()`'s `syncAll(types:)` call below: `GoogleConsentView`'s OAuth
// scope request (`AppEnvironment.p0Types.map(\.scope)`) only covers P0's
// scopes, and ECG/IRN sit behind their own separate `.ecg`/`.irn` Google
// scopes (`GoogleDataType.scope`) -- syncing them without first requesting
// those scopes would 403 against a real (non-stubbed) Google account. Widening
// onboarding consent to request those scopes is out of this WP's stated file
// scope (`GoogleConsentView.swift` isn't listed); flagged in progress.md as
// follow-up for whichever WP does that. Until then, these rows populate from
// `-UITestSeedData`'s seeded fixtures (tests) or from a future WP's backfill/
// broader-sync wiring (production) -- never from this screen's own button.

import CoreModel
import SwiftData
import SwiftUI

struct DashboardView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @Query(sort: \SyncState.dataType) private var syncStates: [SyncState]
    @Query(sort: \LocalSample.dataType) private var localSamples: [LocalSample]
    @State private var isSyncing = false
    @State private var isConnectingGoogle = false
    @State private var connectError: String?

    /// Onboarding-skip-Google: read live from defaults every render (no cached copy
    /// to go stale across the Settings connect flow).
    private var googleSkipped: Bool { GoogleConnectionSetting().isSkipped }

    private var orderedRows: [(GoogleDataType, SyncState?)] {
        AppEnvironment.p0Types.map { type in
            (type, syncStates.first { $0.dataType == type.rawValue })
        }
    }

    private var localOnlyRows: [(GoogleDataType, [LocalSample])] {
        AppEnvironment.p1LocalOnlyTypes.map { type in
            (type, localSamples.filter { $0.dataType == type.rawValue })
        }
    }

    // WP-33 follow-on: the stock `List` this screen shipped with is replaced
    // by the Yacht club panel layout (`Shared/ThemedChrome.swift`) so the
    // Data tab matches Today. Structure, data flow, copy and every
    // accessibility identifier are unchanged -- only the presentation.
    var body: some View {
        NavigationStack {
            ThemedScreen(title: "HealthLoom") {
                // The toolbar's two items, redrawn as themed header actions
                // (the system navigation bar is hidden for tab roots -- see
                // ThemedChrome.swift's "Navigation chrome" note).
                NavigationLink(destination: SettingsView(chrome: .pushed)) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 24, height: 24)
                        // WP-37: 44pt touch target (the 24pt glyph alone
                        // fails the hit-region audit).
                        .padding(10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("dashboard.settings")

                ThemedIconButton(
                    systemImage: "arrow.triangle.2.circlepath",
                    accessibilityLabel: "Sync Now",
                    accessibilityIdentifier: "dashboard.syncNow",
                    isBusy: isSyncing,
                    action: syncNow
                )
                .disabled(isSyncing)
            } content: {
                ephemeralStoreWarning
                googleConnectPanel
                freshnessHeader
                    .padding(.top, 18)

                ThemedSectionHeader(title: "Your Data")
                ThemedPanel {
                    ForEach(Array(orderedRows.enumerated()), id: \.element.0) { index, row in
                        if index > 0 { ThemedRowDivider() }
                        SyncTypeRow(type: row.0, state: row.1)
                    }
                }

                ThemedSectionHeader(title: "Not in Apple Health")
                ThemedPanel {
                    ForEach(Array(localOnlyRows.enumerated()), id: \.element.0) { index, row in
                        if index > 0 { ThemedRowDivider() }
                        LocalOnlyTypeRow(type: row.0, samples: row.1)
                    }
                }

                // WP-15 / WP-12b nav links, unchanged in behavior -- now one
                // panel of themed rows rather than two bare `List` sections.
                ThemedSectionHeader(title: "More")
                ThemedPanel {
                    ThemedNavRow(
                        title: "Historical Backfill",
                        accessibilityIdentifier: "dashboard.backfill.link"
                    ) {
                        BackfillView()
                    }
                    ThemedRowDivider()
                    ThemedNavRow(
                        title: "Activities",
                        accessibilityIdentifier: "dashboard.activities.link"
                    ) {
                        ActivitiesView(chrome: .pushed)
                    }
                }
            }
        }
    }

    private var freshnessHeader: some View {
        ThemedCallout(
            title: "About data freshness",
            message: "Your Fitbit or Pixel Watch reaches Google roughly every 15 minutes while the Google Health app is open. HealthLoom then pulls from Google each time you sync below -- this isn't a live feed.",
            accessibilityIdentifier: "dashboard.freshnessHeader"
        )
    }

    /// Loud ephemeral-store banner (round-6 item 3): when the on-disk
    /// store failed to open, the session runs on a throwaway memory
    /// store — say so up front instead of reporting success while
    /// discarding everything at relaunch.
    @ViewBuilder
    private var ephemeralStoreWarning: some View {
        if appEnvironment.isStoreEphemeral {
            ThemedCallout(
                title: "Temporary data mode",
                message: "HealthLoom couldn't open its saved data. Everything works, but nothing will persist until you restart the app.",
                accessibilityIdentifier: "dashboard.ephemeralStoreWarning"
            )
        }
    }

    /// Google-not-connected panel (onboarding-skip-Google): an inline Connect
    /// affordance INSTEAD of red per-type errors. Per-type rows below stay in their
    /// never-synced idle state (no `syncAll` ever runs while skipped, so no error
    /// rows can mint); this panel is the honest state + the way back.
    @ViewBuilder
    private var googleConnectPanel: some View {
        if googleSkipped {
            ThemedPanel {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Google isn't connected")
                        .font(Theme.font(14, .medium, relativeTo: .subheadline))
                        .foregroundStyle(Theme.ink)
                    Text("Your daily activity lives in Google — connect the account linked to your Fitbit or Pixel Watch to start syncing.")
                        .font(Theme.font(13, .regular, relativeTo: .footnote))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let connectError {
                        Text(connectError)
                            .font(Theme.font(11.5, .regular, relativeTo: .caption))
                            .foregroundStyle(Theme.accentDeep)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button {
                        connectGoogle()
                    } label: {
                        Text(isConnectingGoogle ? "Connecting…" : "Connect Google")
                            .font(Theme.font(15, .semibold, relativeTo: .callout))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.accent))
                    }
                    .buttonStyle(.plain)
                    .disabled(isConnectingGoogle || isSyncing)
                    .accessibilityIdentifier("dashboard.connectGoogle")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .padding(.top, 18)
            .accessibilityIdentifier("dashboard.googleConnectPanel")
        }
    }

    private func connectGoogle() {
        isConnectingGoogle = true
        connectError = nil
        let scopes = Array(Set(AppEnvironment.p0Types.map(\.scope)))
        Task {
            let result = await appEnvironment.consentCoordinator.beginConsent(scopes: scopes)
            isConnectingGoogle = false
            switch result {
            case .success:
                GoogleConnectionSetting().clearSkipped()
                syncNow()
            case .workspaceUnsupported:
                connectError = "Google Workspace (work or school) accounts aren't supported — try a personal account."
            case .cancelled:
                break
            case .failure(let message):
                connectError = message
            }
        }
    }

    private func syncNow() {
        // Third-party r9: quiesced (wipe latched, relaunch pending) — never dispatch.
        // `SyncEngine.sync` also guards structurally; this cheap check keeps the UI
        // from flashing a sync pass that can only return stopped.
        guard !WipeQuiesce.isLatched else { return }
        // Onboarding-skip-Google: without credentials `syncAll` would only mint
        // per-type `.unauthorized` error rows — stay quiet, the panel above owns
        // this state. (`SyncEngine` has no credentials notion; the gate lives with
        // the skip flag that caused it.)
        guard !googleSkipped else { return }
        isSyncing = true
        // Round-6 item 9: every syncable type (not just P0) minus
        // disabled — an enabled non-P0 row updates on demand, not only
        // on background wake. (Disabling stops future syncing but does
        // not delete anything already written — WP-35's wipe flow.)
        let typesToSync = SyncPreferences.manualSyncTypes()
        Task {
            _ = await appEnvironment.syncEngine.syncAll(types: typesToSync)
            isSyncing = false
        }
    }
}

#Preview {
    DashboardView()
        .environment(AppEnvironment())
}
