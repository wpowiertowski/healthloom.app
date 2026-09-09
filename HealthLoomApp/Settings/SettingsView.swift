// SettingsView.swift
//
// WP-17 (implementation-plan.md): "Settings screen: per-type sync toggles
// (grouped by Google scope); enabling a type whose scope isn't granted
// triggers `ensure(scopes:)` incremental consent; disabling stops sync but
// keeps written data (deletion is WP-35's wipe)."
//
// Grouping: one `List` section per `GoogleDataType.Scope`
// (`.activityAndFitness`/`.healthMetrics`/`.sleep`/`.nutrition`/`.ecg`/`.irn`,
// CoreModel), over `SyncPreferences.syncableTypes` -- every non-`.skip`
// `GoogleDataType`, per that file's header note.
//
// **`ensure(scopes:)` already existed** -- this WP did not need to add
// anything to `GoogleAuthManager` (GoogleHealthClient, WP-04): read
// `GoogleAuthManager+Consent.swift` before assuming otherwise, and found
// `public func ensure(scopes: [GoogleDataType.Scope], presentationContextProvider:)
// async throws(GoogleAuthError) -> Bool`, which already computes the missing
// subset via `missingHealthScopes(from:)` and only presents consent for that
// subset (returns `true`/no UI if nothing was missing) -- exactly WP-17's
// "incremental consent" ask, word for word. `IncrementalConsentPresenter`
// (this folder) supplies the one thing `ensure` needs beyond scopes: an
// `ASWebAuthenticationPresentationContextProviding`.
//
// Toggling a type OFF does not touch HealthKit/`LocalSample` data already
// written (WP-35's wipe flow is separate, out of scope here) -- it only
// updates `SyncPreferences`, which callers of `syncAll(types:)` are expected
// to consult (see that file's header note on the two known call sites).
//
// WP-18 (implementation-plan.md) addendum: one additive `Section` below adds
// a `NavigationLink` to the new "Sync Log" viewer (`HealthLoomApp/Diagnostics/
// SyncLogView.swift`) -- this is the one small nav-link edit that WP's scope
// fence explicitly allows in this file; nothing above this comment block
// changed.

import Combine
import CoreModel
import GoogleHealthClient
import SwiftData
import SwiftUI

struct SettingsView: View {
    /// Reachable both as a tab root (`HomeView`) and pushed from the Data
    /// dashboard's gear -- see ThemedChrome.swift's "Navigation chrome".
    var chrome: ScreenChrome = .tabRoot

    @Environment(AppEnvironment.self) private var appEnvironment
    @State private var preferences = SyncPreferences()
    // WP-12b: "Prefer Apple Watch during workouts" (architecture.md D13.5).
    @State private var watchPriority = WatchPriorityPreferences()
    // WP-34: morning-insight toggles + live notification posture.
    @State private var insightPrefs = InsightPreferences()
    @State private var insightAuthStatus: InsightAuthStatus = .notDetermined
    @Environment(\.scenePhase) private var scenePhase
    // WP-35: export file state.
    @State private var exportURL: URL?
    @State private var isExporting = false
    @State private var exportError: String?
    private let consentPresenter = IncrementalConsentPresenter()

    @State private var pendingTypes: Set<GoogleDataType> = []
    @State private var scopeErrors: [GoogleDataType: String] = [:]
    /// Newest consent attempt per type. A toggle flip invalidates any
    /// earlier attempt's token, so a late failure from a stalled attempt
    /// can't revert a newer attempt that already succeeded (or a newer
    /// explicit OFF).
    @State private var consentAttempts: [GoogleDataType: UUID] = [:]
    /// One-shot HealthKit re-request state (existing installs, see below).
    @State private var isRefreshingHealthSharing = false
    @State private var healthSharingMessage: String? = nil

    private var groupedByScope: [(scope: GoogleDataType.Scope, types: [GoogleDataType])] {
        let grouped = Dictionary(grouping: SyncPreferences.syncableTypes, by: \.scope)
        return GoogleDataType.Scope.allCases
            .compactMap { scope in grouped[scope].map { (scope, $0) } }
    }

    // WP-33 follow-on (Shared/ThemedChrome.swift): Yacht club presentation --
    // `List` sections become tracked headers over surface panels, the section
    // footer becomes a rust-tint callout, and toggles carry the accent tint
    // instead of the system green. Behavior, copy and every accessibility
    // identifier are unchanged.
    var body: some View {
        ThemedScreen(title: "Sync Settings", chrome: chrome) {
            Text("Turn off a type to stop syncing it. Data already written to Apple Health or saved on-device is not deleted -- that's a separate step in a future release.")
                .font(Theme.font(13, .regular, relativeTo: .footnote))
                .foregroundStyle(Theme.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 18)
                .accessibilityIdentifier("settings.disclaimer")

            ThemedPanel {
                ThemedNavRow(
                    title: "Sync Log",
                    accessibilityIdentifier: "settings.synclog.link"
                ) {
                    SyncLogView()
                }
            }
            .padding(.top, 20)

            // WP-29 (implementation-plan.md): per-tier status, consent
            // flows, key entry/validation, quota state, model picker.
            ThemedPanel {
                ThemedNavRow(
                    title: "AI Models",
                    accessibilityIdentifier: "settings.aimodels.link"
                ) {
                    AIModelsView(viewModel: appEnvironment.aiModelsViewModel())
                }
            }
            .padding(.top, 20)

            // WP-34 (implementation-plan.md): morning insights. Enabling
            // the toggle is the in-context notification-permission moment
            // (never at launch): a `.notDetermined` status triggers the
            // system request right here; a denial flips the toggle back
            // off and the guidance line below points at Settings.
            ThemedPanel {
                ThemedToggleRow(
                    title: "Morning insights",
                    accessibilityIdentifier: "settings.insights.toggle",
                    isOn: Binding(
                        get: { insightPrefs.morningInsightsEnabled },
                        set: { toggleInsights(isOn: $0) }
                    )
                )
                ThemedRowDivider()
                ThemedToggleRow(
                    title: "Show details on lock screen",
                    accessibilityIdentifier: "settings.insights.fullText",
                    isOn: $insightPrefs.lockScreenDetails
                )
                ThemedRowDivider()
                ThemedToggleRow(
                    title: "Generate via Apple cloud",
                    accessibilityIdentifier: "settings.insights.viaCloud",
                    isOn: $insightPrefs.insightsViaCloud
                )
                if insightAuthStatus == .denied {
                    Text("Notifications are off for HealthLoom — enable them in Settings to receive morning insights.")
                        .font(Theme.font(11.5, .regular, relativeTo: .caption))
                        .foregroundStyle(Theme.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .accessibilityIdentifier("settings.insights.deniedHint")
                }
            }
            .padding(.top, 20)

            Text("After the first sync past 5am, HealthLoom generates one insight — on-device unless Apple cloud (PCC) is enabled in AI Models and generation via Apple cloud is on above. The lock-screen notification shows the headline only (numbers removed) unless details are on.")
                .font(Theme.font(11.5, .regular, relativeTo: .caption))
                .foregroundStyle(Theme.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)
                .task {
                    await refreshInsightAuthStatus()
                }
                // N5: the denied hint goes stale if the user grants in
                // Settings.app — re-read on every foreground return.
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task {
                        await refreshInsightAuthStatus()
                    }
                }

            // iCloud sync (private DB: settings, insight prefs, coach
            // history — never HealthKit values). Status-first surface:
            // local-only is silent-by-design at the engine, but Settings
            // names it so "why isn't my other device updated" has an
            // answer; failures show their message; nothing is ever lost
            // (local store stays the source of truth, intent queues).
            ThemedSectionHeader(title: "iCloud Sync")
            ThemedPanel {
                HStack {
                    Text(cloudSyncStatusText)
                        .font(Theme.font(14, .regular, relativeTo: .subheadline))
                        .foregroundStyle(Theme.secondary)
                        .accessibilityIdentifier("settings.icloud.status")
                    Spacer()
                    Button("Sync Now") {
                        Task {
                            await appEnvironment.cloudSync.syncNow()
                        }
                    }
                    .font(Theme.font(14, .medium, relativeTo: .subheadline))
                    .accessibilityIdentifier("settings.icloud.syncNow")
                }
                .padding(.horizontal, 16).padding(.vertical, 13)
                if case .failed(let message) = appEnvironment.cloudSync.status {
                    ThemedRowDivider()
                    Text(message)
                        .font(Theme.font(11.5, .regular, relativeTo: .caption))
                        .foregroundStyle(Theme.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .accessibilityIdentifier("settings.icloud.error")
                }
            }
            .padding(.top, 20)
            // A pull applied server state through the engine's own owner
            // instances — this screen's instances re-read the same keys.
            .onReceive(NotificationCenter.default.publisher(for: .cloudSyncDidApply)) { _ in
                preferences.reload()
                insightPrefs.reload()
            }

            // Tip jar (StoreKit 2 consumables). Graceful empty state:
            // before the human creates the products in App Store Connect,
            // `products` is empty and the section says so instead of
            // rendering dead buttons.
            ThemedSectionHeader(title: "Tip Jar")
            ThemedPanel {
                if appEnvironment.tipStore.tipCount > 0 {
                    Text("Thanks for supporting HealthLoom — \(appEnvironment.tipStore.tipCount) tip\(appEnvironment.tipStore.tipCount == 1 ? "" : "s") so far!")
                        .font(Theme.font(13, .regular, relativeTo: .footnote))
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .accessibilityIdentifier("settings.tips.thanks")
                    ThemedRowDivider()
                }
                if appEnvironment.tipStore.products.isEmpty {
                    Text("Tips are coming soon — in-app purchase products are being set up.")
                        .font(Theme.font(13, .regular, relativeTo: .footnote))
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 13)
                        .accessibilityIdentifier("settings.tips.status")
                } else {
                    ForEach(appEnvironment.tipStore.products.sorted(by: { $0.price < $1.price })) { product in
                        Button {
                            Task {
                                await appEnvironment.tipStore.purchase(product)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(product.displayName)
                                        .font(Theme.font(14, .medium, relativeTo: .subheadline))
                                        .foregroundStyle(Theme.ink)
                                    Text(product.description)
                                        .font(Theme.font(11.5, .regular, relativeTo: .caption))
                                        .foregroundStyle(Theme.secondary)
                                }
                                Spacer()
                                Text(product.displayPrice)
                                    .font(Theme.font(15, .regular, relativeTo: .subheadline))
                                    .foregroundStyle(Theme.secondary)
                                    .monospacedDigit()
                            }
                            .padding(.horizontal, 16).padding(.vertical, 13)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings.tips.\(TipProductID(rawValue: product.id)?.shortName ?? product.id)")
                        .disabled(appEnvironment.tipStore.isPurchasing)
                    }
                }
                if case .failed(let message) = appEnvironment.tipStore.lastResult {
                    ThemedRowDivider()
                    Text(message)
                        .font(Theme.font(11.5, .regular, relativeTo: .caption))
                        .foregroundStyle(Theme.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .accessibilityIdentifier("settings.tips.error")
                }
            }
            .padding(.top, 20)
            .task {
                await appEnvironment.tipStore.loadProducts()
            }

            // WP-35 (implementation-plan.md): export (JSON dump + share
            // sheet, user-initiated) and the disconnect-and-wipe flow.
            ThemedPanel {
                Button {
                    prepareExport()
                } label: {
                    HStack {
                        Text("Export my data")
                            .font(Theme.font(14, .medium, relativeTo: .subheadline))
                            .foregroundStyle(Theme.ink)
                        Spacer()
                        if isExporting {
                            ProgressView().controlSize(.mini).tint(Theme.accent)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                // 44pt target via frame alone: adding `.contentShape`
                // here silently eats taps (proven by UI-test failure;
                // mechanism unknown, so do not "fix" this line).
                .frame(minWidth: 44, minHeight: 44)
                .disabled(isExporting)
                .accessibilityIdentifier("settings.export.prepare")
                if let exportURL {
                    ThemedRowDivider()
                    ShareLink(item: exportURL, subject: Text("HealthLoom data export")) {
                        HStack {
                            Text("Share export file")
                                .font(Theme.font(14, .medium, relativeTo: .subheadline))
                                .foregroundStyle(Theme.accentDeep)
                            Spacer()
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 15, weight: .light))
                                .foregroundStyle(Theme.accentDeep)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 11)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.export.share")
                }
                if let exportError {
                    ThemedErrorText(
                        message: exportError,
                        accessibilityIdentifier: "settings.export.error"
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
                ThemedRowDivider()
                // NavigationLink, not a sheet: nav rows are the proven
                // drill-in pattern on this screen (AI Models UI tests),
                // and a multi-step flow wants a back stack anyway.
                ThemedNavRow(
                    title: "Disconnect & wipe",
                    accessibilityIdentifier: "settings.wipe.open"
                ) {
                    WipeFlowView()
                }
            }
            .padding(.top, 20)

            Text("Export downloads LocalSample rows, your knowledge profile, and chat history as one JSON file. Disconnect & wipe signs out of Google, deletes saved keys, HealthKit samples HealthLoom wrote, all app data, and settings — then restart the app.")
                .font(Theme.font(11.5, .regular, relativeTo: .caption))
                .foregroundStyle(Theme.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)

            // WP-26 (implementation-plan.md): the coach prompt editor --
            // base prompt, token estimate, reset, history restore,
            // diff-vs-default, and the locked-suffix effective preview.
            ThemedPanel {
                ThemedNavRow(
                    title: "Coach Prompt",
                    accessibilityIdentifier: "settings.prompt.link"
                ) {
                    PromptEditorView(viewModel: PromptEditorViewModel(deps: PromptEditorViewModel.Dependencies(
                        manager: appEnvironment.promptManager,
                        factory: appEnvironment.coachSessionFactory
                    )))
                }
            }
            .padding(.top, 20)

            // WP-12b (architecture.md D13.5): watch-priority conflict
            // resolution toggle, default ON. The callout copy documents the
            // one asymmetry D13.5 mandates: OFF is forward-only (previously
            // skipped data isn't restored), ON cleans up duplicates on the
            // next sync (D13.4's retroactive pass).
            ThemedPanel {
                ThemedToggleRow(
                    title: "Prefer Apple Watch during workouts",
                    accessibilityIdentifier: "settings.watchPriority.toggle",
                    isOn: Binding(
                        get: { watchPriority.isEnabled },
                        set: { watchPriority.setEnabled($0) }
                    )
                )
            }
            .padding(.top, 20)

            Text("When on, activities your Apple Watch recorded win: overlapping Fitbit workouts and their heart rate, steps, energy, and distance aren't duplicated into Apple Health -- the Fitbit session is kept in HealthLoom as a supplement instead. Turning this off doesn't restore data that was already skipped; turning it back on removes duplicates on the next sync.")
                .font(Theme.font(11.5, .regular, relativeTo: .caption))
                .foregroundStyle(Theme.tertiary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)

            ForEach(groupedByScope, id: \.scope) { group in
                ThemedSectionHeader(title: scopeDisplayName(group.scope))
                ThemedPanel {
                    ForEach(Array(group.types.enumerated()), id: \.element) { index, type in
                        if index > 0 { ThemedRowDivider() }
                        row(for: type)
                    }
                }
            }

            // One-shot catch-up for installs onboarded before workout
            // sharing shipped (see `refreshHealthSharing`): re-presents
            // only the still-undetermined HealthKit types.
            ThemedSectionHeader(title: "Apple Health Sharing")
            ThemedPanel {
                Button {
                    refreshHealthSharing()
                } label: {
                    HStack {
                        Text("Update Apple Health Sharing")
                        Spacer()
                        if isRefreshingHealthSharing {
                            ProgressView()
                        }
                    }
                    // WP-37: row geometry + 44pt target (the bare text
                    // measured 358×20 — audit-small).
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("settings.healthSharing.refresh")
                .disabled(isRefreshingHealthSharing)

                if let message = healthSharingMessage {
                    ThemedErrorText(
                        message: message,
                        accessibilityIdentifier: "settings.healthSharing.message"
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func row(for type: GoogleDataType) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ThemedToggleRow(
                title: displayName(type),
                isBusy: pendingTypes.contains(type),
                accessibilityIdentifier: "settings.toggle.\(type.rawValue)",
                isOn: Binding(
                    get: { preferences.isEnabled(type) },
                    set: { toggle(type: type, isOn: $0) }
                )
            )

            if let message = scopeErrors[type] {
                ThemedErrorText(
                    message: message,
                    accessibilityIdentifier: "settings.error.\(type.rawValue)"
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
    }

    private func refreshInsightAuthStatus() async {
        insightAuthStatus = await appEnvironment.insightNotifier.authorizationStatus()
    }

    /// WP-35 export: fetches every exportable row, encodes the versioned
    /// document, and stages a temp file for the `ShareLink` above. Errors
    /// surface inline (never a silent no-op). Previous staged files are
    /// swept first (F3): exports must not accumulate health JSON in tmp.
    private func prepareExport() {
        isExporting = true
        exportError = nil
        exportURL = nil
        Task {
            defer { isExporting = false }
            do {
                let context = ModelContext(appEnvironment.modelContainer)
                let samples = try context.fetch(FetchDescriptor<LocalSample>())
                let profile = try context.fetch(FetchDescriptor<KnowledgeProfile>()).first
                let turns = try context.fetch(FetchDescriptor<ChatTurn>(
                    sortBy: [SortDescriptor(\.createdAt, order: .forward)]
                ))
                let document = ExportBuilder.build(
                    samples: samples,
                    profile: profile,
                    turns: turns,
                    now: Date()
                )
                let data = try ExportBuilder.encode(document)
                // Sweep previous staged exports before writing (F3).
                try StoreDeleter.deleteExportFiles()
                let url = FileManager.default.temporaryDirectory.appending(
                    path: "healthloom-export-\(Int(Date().timeIntervalSince1970)).json",
                    directoryHint: .notDirectory
                )
                try data.write(to: url, options: .atomic)
                exportURL = url
            } catch {
                exportError = "Couldn't prepare the export file."
            }
        }
    }

    /// Morning-insights toggle with the in-context permission request.
    /// Optimistic ON: enabling requests unless already authorized — the
    /// user action is the context, never launch. A denial (or an already-
    /// denied status, which answers immediately) reverts the toggle and
    /// the guidance line appears.
    private func toggleInsights(isOn: Bool) {
        insightPrefs.morningInsightsEnabled = isOn
        guard isOn else { return }
        Task {
            let already = await appEnvironment.insightNotifier.authorizationStatus() == .authorized
            var granted = already
            if !granted {
                granted = await appEnvironment.insightNotifier.requestAuthorization()
            }
            if !granted {
                insightPrefs.morningInsightsEnabled = false
            }
            insightAuthStatus = await appEnvironment.insightNotifier.authorizationStatus()
        }
    }

    private func toggle(type: GoogleDataType, isOn: Bool) {
        // Every flip mints a new attempt token: flipping OFF invalidates a
        // stalled ON attempt (its late failure then no-ops below), and a
        // second ON supersedes the first.
        consentAttempts[type] = UUID()
        preferences.setEnabled(isOn, for: type)
        scopeErrors[type] = nil
        guard isOn else { return }

        let attempt = consentAttempts[type]
        let scopes = Array(preferences.requiredScopes(toEnable: type))
        pendingTypes.insert(type)
        Task {
            defer { pendingTypes.remove(type) }
            do {
                try await appEnvironment.googleAuthManager.ensure(
                    scopes: scopes,
                    presentationContextProvider: consentPresenter
                )
                // Success clears only its own token (a newer flip already
                // replaced it, and must not be disturbed).
                if consentAttempts[type] == attempt {
                    consentAttempts[type] = nil
                }
            } catch {
                // Revert the optimistic toggle ONLY if no newer flip
                // superseded this attempt: otherwise a stalled first attempt
                // failing late would turn OFF a type a second attempt just
                // enabled (with a granted scope and an error banner).
                guard consentAttempts[type] == attempt else { return }
                consentAttempts[type] = nil
                preferences.setEnabled(false, for: type)
                scopeErrors[type] = "Couldn't confirm Google access for \(displayName(type)): \(error)"
            }
        }
    }

    /// Re-requests HealthKit sharing including the workout/distance buckets
    /// (round-3 fix: `includingWorkoutShare`). Exists for installs onboarded
    /// BEFORE that flag shipped -- onboarding passes it, but
    /// already-onboarded users never see that sheet again, so without this
    /// their workout/distance types sit at `.notDetermined` and every
    /// exercise sync fails permanently. User-initiated, idempotent
    /// (HealthKit only prompts for still-undetermined types).
    private func refreshHealthSharing() {
        isRefreshingHealthSharing = true
        healthSharingMessage = nil
        Task {
            defer { isRefreshingHealthSharing = false }
            do {
                try await appEnvironment.healthKitAuth.requestShareAndRead(
                    share: AppEnvironment.p0Types,
                    read: [
                        .exercise, .heartRate, .steps, .sleep, .weight,
                        .oxygenSaturation, .distance, .activeEnergyBurned,
                    ],
                    includingWorkoutShare: true
                )
                healthSharingMessage = "Health sharing is up to date."
            } catch {
                healthSharingMessage = "Couldn't update Health sharing: \(error)"
            }
        }
    }

    private func displayName(_ type: GoogleDataType) -> String {
        type.displayName
    }

    private func scopeDisplayName(_ scope: GoogleDataType.Scope) -> String {
        switch scope {
        case .activityAndFitness: return "Activity & Fitness"
        case .healthMetrics: return "Health Metrics"
        case .sleep: return "Sleep"
        case .nutrition: return "Nutrition"
        case .ecg: return "ECG"
        case .irn: return "Irregular Rhythm Notifications"
        }
    }

    /// iCloud status line. Every state names what it means for the user's
    /// data — especially local-only (not an error) and pending (nothing
    /// lost, intent queued).
    private var cloudSyncStatusText: String {
        switch appEnvironment.cloudSync.status {
        case .localOnly:
            return "Local only — sign in to iCloud to sync"
        case .syncing:
            return "Syncing…"
        case .synced(_, let pending) where pending > 0:
            return "Waiting to sync (\(pending))"
        case .synced(let at, _):
            guard let at else { return "Not synced yet" }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return "Synced \(formatter.localizedString(for: at, relativeTo: Date()))"
        case .failed:
            return "Sync needs attention"
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .environment(AppEnvironment())
}
