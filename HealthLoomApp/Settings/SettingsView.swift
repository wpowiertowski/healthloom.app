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

import CoreModel
import GoogleHealthClient
import SwiftUI

struct SettingsView: View {
    /// Reachable both as a tab root (`HomeView`) and pushed from the Data
    /// dashboard's gear -- see ThemedChrome.swift's "Navigation chrome".
    var chrome: ScreenChrome = .tabRoot

    @Environment(AppEnvironment.self) private var appEnvironment
    @State private var preferences = SyncPreferences()
    // WP-12b: "Prefer Apple Watch during workouts" (architecture.md D13.5).
    @State private var watchPriority = WatchPriorityPreferences()
    private let consentPresenter = IncrementalConsentPresenter()

    @State private var pendingTypes: Set<GoogleDataType> = []
    @State private var scopeErrors: [GoogleDataType: String] = [:]

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

    private func toggle(type: GoogleDataType, isOn: Bool) {
        preferences.setEnabled(isOn, for: type)
        scopeErrors[type] = nil
        guard isOn else { return }

        let scopes = Array(preferences.requiredScopes(toEnable: type))
        pendingTypes.insert(type)
        Task {
            defer { pendingTypes.remove(type) }
            do {
                try await appEnvironment.googleAuthManager.ensure(
                    scopes: scopes,
                    presentationContextProvider: consentPresenter
                )
            } catch {
                scopeErrors[type] = "Couldn't confirm Google access for \(displayName(type)): \(error)"
            }
        }
    }

    private func displayName(_ type: GoogleDataType) -> String {
        type.rawValue
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
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
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .environment(AppEnvironment())
}
