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
// starts `AppEnvironment.foregroundSync` (WP-53), the same sequential
// per-type walk over `SyncEngine` onboarding's `FirstSyncView` runs, owned
// outside this view so it survives tab switches; `@Query` picks up whatever
// that run persists to `SyncState` without this view re-fetching manually.
//
// WP-14 (implementation-plan.md): a second `@Query`, over CoreModel's
// `LocalSample`, drives a second section for the four `.localOnly`-writability
// types (architecture.md D2) -- these don't have a `SyncState` row of their
// own to key off of (they never touch HealthKit), so they're grouped
// client-side by `LocalSample.dataType` instead and rendered via
// `LocalOnlyTypeRow`, not `SyncTypeRow`. `syncNow()` walks every syncable
// type (round-6 item 9), local-only ones included, and every connect path
// asks for `SyncPreferences.consentScopes()` -- the scopes of exactly those
// types, ECG/IRN included (WP-52; asking only for P0's scopes left them
// 403ing against a real account).

import CoachKit
import CoreModel
import SwiftData
import SwiftUI

struct DashboardView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @Query(sort: \SyncState.dataType) private var syncStates: [SyncState]
    /// WP-67: the in-app rows' summaries, built off the main thread.
    @State private var localSummaries: [GoogleDataType: LocalRowSummary] = [:]
    @State private var isConnectingGoogle = false
    /// WP-56: 7-day vs 30-day trends from Apple Health, per P0 row.
    @State private var trends: [GoogleDataType: RollingTrend] = [:]
    @Environment(\.locale) private var locale
    @State private var connectError: String?

    /// Onboarding-skip-Google: read live from defaults every render (no cached copy
    /// to go stale across the Settings connect flow).
    private var googleSkipped: Bool { GoogleConnectionSetting().isSkipped }

    /// WP-53: the run lives in `AppEnvironment`, not this view's `@State`,
    /// so leaving the tab mid-sync doesn't reset the spinner.
    private var isSyncing: Bool { appEnvironment.foregroundSync.isRunning }

    private var orderedRows: [(GoogleDataType, SyncState?)] {
        AppEnvironment.p0Types.map { type in
            (type, syncStates.first { $0.dataType == type.rawValue })
        }
    }

    private var localOnlyRows: [(GoogleDataType, LocalRowSummary)] {
        AppEnvironment.p1LocalOnlyTypes.map { type in (type, localSummaries[type] ?? .empty) }
    }

    // WP-33 follow-on: the stock `List` this screen shipped with is replaced
    // by the Yacht club panel layout (`Shared/ThemedChrome.swift`) so the
    // Data tab matches Today. Structure, data flow, copy and every
    // accessibility identifier are unchanged -- only the presentation.
    var body: some View {
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
            syncProgress

            ThemedSectionHeader(title: "Your Data")
            ThemedPanel {
                ForEach(Array(orderedRows.enumerated()), id: \.element.0) { index, row in
                    if index > 0 { ThemedRowDivider() }
                    SyncTypeRow(type: row.0, state: row.1, trend: trendText(for: row.0))
                }
            }

            ThemedSectionHeader(title: "Not in Apple Health")
            ThemedPanel {
                ForEach(Array(localOnlyRows.enumerated()), id: \.element.0) { index, row in
                    if index > 0 { ThemedRowDivider() }
                    LocalOnlyTypeRow(type: row.0, summary: row.1)
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
        // WP-56: trends load on appear and again whenever a Sync Now starts
        // or finishes (the run's end brings new days into Apple Health).
        .task(id: appEnvironment.foregroundSync.isRunning) {
            trends = await DataTrendProvider().trends(for: AppEnvironment.p0Types)
            localSummaries = await LocalRowSummarizer(modelContainer: appEnvironment.modelContainer)
                .summaries(for: AppEnvironment.p1LocalOnlyTypes, now: Date(), calendar: .current)
        }
    }

    /// Names the types in flight during Sync Now (WP-53): a first heart-rate
    /// sync runs for minutes and logs nothing until it finishes, so without
    /// this the tab looks done while it's still working.
    @ViewBuilder
    private var syncProgress: some View {
        if let text = Self.syncProgressText(appEnvironment.foregroundSync.inFlight) {
            Text(text)
                .font(Theme.font(Theme.Step.caption, .regular, relativeTo: .footnote))
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
                .accessibilityIdentifier("dashboard.syncProgress")
        }
    }

    /// "Syncing Steps, Sleep and Weight…" -- several types run at once
    /// since WP-63; nil when none is in flight.
    static func syncProgressText(_ inFlight: [GoogleDataType]) -> String? {
        guard !inFlight.isEmpty else { return nil }
        return "Syncing \(inFlight.map(\.displayName).formatted(.list(type: .and)))…"
    }

    private func trendText(for type: GoogleDataType) -> DataTrendText {
        guard let metric = DataTrendMetric(type) else { return .empty }
        return DataTrendText.make(
            trends[type],
            metric: metric,
            locale: locale,
            unitSystem: ContextAssembler.defaultUnitSystem(for: locale)
        )
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
                        .font(Theme.font(Theme.Step.body, .medium, relativeTo: .subheadline))
                        .foregroundStyle(Theme.ink)
                    Text("Your daily activity lives in Google — connect the account linked to your Fitbit or Pixel Watch to start syncing.")
                        .font(Theme.font(Theme.Step.caption, .regular, relativeTo: .footnote))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let connectError {
                        Text(connectError)
                            .font(Theme.font(Theme.Step.caption, .regular, relativeTo: .caption))
                            .foregroundStyle(Theme.accentDeep)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button {
                        connectGoogle()
                    } label: {
                        Text(isConnectingGoogle ? "Connecting…" : "Connect Google")
                            .font(Theme.font(Theme.Step.body, .semibold, relativeTo: .callout))
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
        let scopes = SyncPreferences.consentScopes()
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
        // Round-6 item 9: every syncable type (not just P0) minus
        // disabled — an enabled non-P0 row updates on demand, not only
        // on background wake. (Disabling stops future syncing but does
        // not delete anything already written — WP-35's wipe flow.)
        appEnvironment.foregroundSync.start(types: SyncPreferences.manualSyncTypes())
    }
}

#Preview {
    // The app shell (HomeView) supplies the stack in the running app.
    NavigationStack { DashboardView() }
        .environment(AppEnvironment())
}
