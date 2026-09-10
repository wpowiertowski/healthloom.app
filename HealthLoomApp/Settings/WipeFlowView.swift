// WipeFlowView.swift
//
// WP-35 (implementation-plan.md): the "Disconnect & wipe" confirmation
// flow + the JSON export row, hosted in `SettingsView`. Phases:
// confirm (destructive alert) → options (HealthKit opt-out, default ON)
// → running (per-step ledger from `WipeCoordinator`) → done (restart
// instruction — the store files are gone, so the open container is
// invalid and nothing here touches SwiftData again).
//
// Export is separate and safe: builds the document, writes a temp file,
// and vends a `ShareLink`. Both flows are user-initiated; nothing here
// runs at launch or in the background.

import CoreModel
import GoogleHealthClient
import HealthKit
import Secrets
import SyncKit
import SwiftData
import SwiftUI

struct WipeFlowView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .options
    @State private var includeHealthKit = true
    @State private var coordinator: WipeCoordinator?
    @State private var exportURL: URL?
    @State private var exportError: String?

    enum Phase {
        case options
        case running
        case done
    }

    /// True once the run finishes (success or partial): the store files
    /// are gone, so leaving this screen risks `@Query` fetches against a
    /// removed sqlite file plus stale in-memory singletons (gate caches,
    /// tier mirrors, insight prefs). F4 contains the done phase instead:
    /// no Back, no Close, no interactive dismiss — only relaunch exits.
    private var isDone: Bool { phase == .done }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ThemedHeader(title: "Disconnect & wipe") {
                if !isDone {
                    Button {
                        dismiss()
                    } label: {
                        Text("Close")
                            .font(Theme.font(15, .medium, relativeTo: .callout))
                            .foregroundStyle(Theme.accentDeep)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("wipe.close")
                }
            }
            .padding(.horizontal, 22)

            switch phase {
            case .options:
                optionsView
            case .running:
                stepLedger
            case .done:
                stepLedger
                doneView
            }
            Spacer(minLength: 0)
        }
        .background(Theme.canvas.ignoresSafeArea())
        .navigationBarBackButtonHidden(isDone)
        .interactiveDismissDisabled(isDone)
    }

    // MARK: - Options

    private var optionsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("This signs out of Google (revoking access), deletes saved keys, removes all app data, and resets settings. This cannot be undone.")
                .font(Theme.font(13, .regular, relativeTo: .footnote))
                .foregroundStyle(Theme.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 18)

            ThemedPanel {
                ThemedToggleRow(
                    title: "Also delete HealthKit samples",
                    accessibilityIdentifier: "wipe.includeHealthKit",
                    isOn: $includeHealthKit
                )
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)

            Text("Only samples HealthLoom itself wrote are removed — nothing from your watch or other apps.")
                .font(Theme.font(11.5, .regular, relativeTo: .caption))
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 10)

            Button {
                coordinator = WipeCoordinator(deps: liveDeps(), includeHealthKit: includeHealthKit)
                phase = .running
                Task {
                    await coordinator?.run()
                    // F9: in-memory singletons must match the wiped world
                    // (the store files and defaults are gone, but these
                    // caches still claim the old state). Consent mirrors
                    // re-read wiped defaults (all false); the gate cache
                    // drops to absent until the next refresh re-fills.
                    // This does NOT make post-wipe navigation safe in
                    // general — the open container is still invalid — which
                    // is why the done phase stays contained. But IF the
                    // user swipe-backs anyway (no public API disables the
                    // nav gesture; likelihood recalibrated down on an
                    // explicit restart screen), gates fail closed on
                    // keychain misses and rows render the true
                    // post-wipe state instead of stale presence: confusion
                    // risk contained, leak risk nil by construction.
                    appEnvironment.tierSettingsStore.resyncFromDefaults()
                    appEnvironment.gateCache.reset()
                    phase = .done
                }
            } label: {
                Text("Delete everything")
                    .font(Theme.font(15, .semibold, relativeTo: .callout))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.accent))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .accessibilityIdentifier("wipe.confirm")
        }
    }

    // MARK: - Progress + done

    /// The per-step ledger, visible during the run and kept on the
    /// completion screen — the user should see what happened, especially
    /// when a step failed.
    private var stepLedger: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(WipeCoordinator.Step.allCases, id: \.self) { step in
                HStack(spacing: 12) {
                    stepIcon(step)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title)
                            .font(Theme.font(14, .medium, relativeTo: .subheadline))
                            .foregroundStyle(Theme.ink)
                        Text(stepDetail(step))
                            .font(Theme.font(11.5, .regular, relativeTo: .caption))
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .accessibilityIdentifier("wipe.step.\(step.rawValue)")
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 18)
    }

    private func stepIcon(_ step: WipeCoordinator.Step) -> some View {
        // Decorative: the adjacent detail text carries the status.
        Group {
            switch coordinator?.states[step] {
            case .done:
                Image(systemName: "checkmark.circle").foregroundStyle(Theme.accent).accessibilityHidden(true)
            case .failed:
                Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.accent).accessibilityHidden(true)
            case .running:
                ProgressView().controlSize(.mini).tint(Theme.accent)
            default:
                Image(systemName: "circle").foregroundStyle(Theme.tertiary).accessibilityHidden(true)
            }
        }
        .font(.system(size: 16, weight: .light))
    }

    private func stepDetail(_ step: WipeCoordinator.Step) -> String {
        switch coordinator?.states[step] {
        case .done(let detail): return detail
        case .failed(let message): return "Failed: \(message)"
        case .running: return "Working…"
        default: return "Waiting"
        }
    }

    private var doneView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let coordinator, coordinator.failedSteps.isEmpty {
                Text("Everything is deleted.")
                    .font(Theme.font(17, .medium, relativeTo: .title3))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                    .accessibilityIdentifier("wipe.done")
            } else {
                Text("Finished with errors.")
                    .font(Theme.font(17, .medium, relativeTo: .title3))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                    .accessibilityIdentifier("wipe.donePartial")
                Text("Some steps failed (see above). What was deleted stays deleted — fix the cause and run again for the rest.")
                    .font(Theme.font(13, .regular, relativeTo: .footnote))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
            }
            Text("Restart HealthLoom now — the data store was removed while open.")
                .font(Theme.font(13, .regular, relativeTo: .footnote))
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 22)
                .padding(.top, 8)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Live dependencies (WP-35 file scope: this file only)

    private func liveDeps() -> WipeCoordinator.Dependencies {
        let authManager = appEnvironment.googleAuthManager
        let keys = appEnvironment.cloudKeys
        return WipeCoordinator.Dependencies(
            // Revocation failure is recorded in the ledger, never thrown
            // out: the keychain step clears the same secrets locally
            // (`GoogleAuthError` is log-safe by design).
            revokeGoogle: {
                try await authManager.revokeRefreshToken()
            },
            // F6: continue-all per key (the coordinator preaches it;
            // the loop practices it). First failure rethrown after the
            // loop so one transient can't strand the rest.
            deleteAllKeys: {
                var firstError: (any Error)?
                for key in SecretKey.allCases {
                    do {
                        try await keys.delete(key)
                    } catch {
                        if firstError == nil {
                            firstError = error
                        }
                    }
                }
                if let firstError {
                    throw firstError
                }
            },
            // N3: no copy loop — the deleter dict returns directly.
            deleteHealthKit: {
                let types = try HealthKitSourceDeleter.wipeableTypes().map { $0 as HKObjectType }
                // Round-4-sync item 9: server-side delete-by-source —
                // no unbounded fetch, no Swift-side bundle filter.
                return await HealthKitSourceDeleter.deleteAppWrittenLive(
                    types: types,
                    writer: HealthKitWriter(healthStore: HKHealthStore())
                )
            },
            deleteStore: {
                var removed = try StoreDeleter.deleteStoreFiles()
                // F3: staged export files are health data too — sweep
                // them with the store, and report the count.
                removed += try StoreDeleter.deleteExportFiles()
                return removed
            },
            resetDefaults: {
                if let domain = Bundle.main.bundleIdentifier {
                    UserDefaults.standard.removePersistentDomain(forName: domain)
                }
            }
        )
    }
}
