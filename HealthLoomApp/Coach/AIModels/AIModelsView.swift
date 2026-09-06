// AIModelsView.swift
//
// WP-29 (implementation-plan.md): Settings → AI Models. One section per
// `ModelTier` (all four rows render always -- non-live rows render their
// "Ships in a later update." status, so the screen documents the ladder,
// not just today's rung): display name, status line from
// `catalog.availability(for:)`, the row toggle, and per-tier extras --
// consent state + withdraw for consented off-device tiers, SecureField key
// entry + delete for key-gated tiers, quota line for PCC, model picker for
// keyed tiers.
//
// One `.sheet(item:)` on a single `AIModelsSheet` enum (never sibling
// same-typed sheets -- they conflict and neither presents). Sheets carry
// the WP-29 accessibility contract the UI tests drive:
// `aimodels.consent.*` (accept/decline), `aimodels.key.*` (field/save/
// cancel/error). The consent sheet renders `TierConsentCopy` verbatim
// (destination, data-leaves, privacy, forget-forward).
//
// Accessibility grouping (the `chat.screen` precedent): every element
// carrying an identifier that also parents identified children gets
// `.accessibilityElement(children: .contain)` FIRST -- without it the
// parent's identifier collapses the children's (every control in a row
// reported the row's identifier, and the sheets hid their copy/buttons).

import CoachKit
import SwiftUI

struct AIModelsView: View {
    // Non-optional `@State` (the `CoachChatView` precedent): the sheet
    // binding must observe the view model's mutations, and the factory
    // needs `AppEnvironment`, so the parent builds it --
    // `State(initialValue:)` keeps the first instance across re-renders,
    // and a fresh push builds a fresh view (no stale key drafts).
    @State private var viewModel: AIModelsViewModel

    init(viewModel: AIModelsViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        ThemedScreen(title: "AI Models", chrome: .pushed) {
            rows(viewModel: viewModel)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("aimodels.screen")
        .task {
            await viewModel.refresh()
        }
        .sheet(item: Binding(
            get: { viewModel.sheet },
            set: {
                if $0 == nil {
                    viewModel.dismissSheet()
                } else {
                    viewModel.sheet = $0
                }
            }
        )) { sheet in
            switch sheet {
            case .consent(let tier): consentSheet(for: tier)
            case .keyEntry(let tier): keySheet(for: tier)
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func rows(viewModel: AIModelsViewModel) -> some View {
        ForEach(viewModel.rows()) { row in
            ThemedSectionHeader(title: row.tier.displayName)
            ThemedPanel {
                ThemedToggleRow(
                    title: row.tier.displayName,
                    isBusy: viewModel.isValidating && viewModel.sheet == .keyEntry(row.tier),
                    accessibilityIdentifier: "aimodels.toggle.\(row.tier.rawValue)",
                    isOn: Binding(
                        get: { row.isTurnedOn },
                        set: { viewModel.setTurnedOn($0, for: row.tier) }
                    )
                )
                // WP-29 F3, decision (a): on-device has no toggle; non-live
                // rows keep their "Ships in a later update." status as ladder
                // documentation with the toggle disabled, so production never
                // walks the consent sheet for a tier whose gate is
                // unconditionally false. (Key entry is closed separately:
                // `beginKeyEntry` guards liveness and the extras section
                // hides the dead Enter-key button — WP-29 F9.)
                .disabled(row.tier == .onDevice || !row.isLive)
                statusLine(for: row)
                extras(for: row, viewModel: viewModel)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("aimodels.row.\(row.tier.rawValue)")
        }
        if let banner = viewModel.bannerMessage {
            ThemedErrorText(message: banner, accessibilityIdentifier: "aimodels.banner")
                .padding(.horizontal, 16)
        }
    }

    /// Status line: "On" when effectively serving, otherwise the catalog's
    /// blocker reason verbatim (consent/key/not-live/model-unavailable).
    private func statusLine(for row: AIModelsViewModel.TierRow) -> some View {
        let text: String
        if row.effectivelyOn {
            text = "On"
        } else if case .unavailable(let reason) = row.availability {
            text = row.isTurnedOn ? reason : "Off -- \(reason)"
        } else {
            text = "Off"
        }
        return Text(text)
            .font(Theme.font(12, .regular, relativeTo: .caption))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .accessibilityIdentifier("aimodels.status.\(row.tier.rawValue)")
    }

    @ViewBuilder
    private func extras(for row: AIModelsViewModel.TierRow, viewModel: AIModelsViewModel) -> some View {
        // PCC quota line (WP-29: "shows quota state and its availability").
        if row.tier == .privateCloudCompute, let quota = row.quota {
            ThemedRowDivider()
            Text(quotaLine(for: quota))
                .font(Theme.font(12, .regular, relativeTo: .caption))
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .accessibilityIdentifier("aimodels.quota.pcc")
        }
        // Consent state + withdraw for consented off-device tiers.
        if row.tier.requiresConsent, let date = row.consentDate {
            ThemedRowDivider()
            HStack {
                Text("Consented \(date.formatted(date: .abbreviated, time: .omitted))")
                    .font(Theme.font(12, .regular, relativeTo: .caption))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                Button("Withdraw") { viewModel.withdrawConsent(for: row.tier) }
                    .accessibilityIdentifier("aimodels.consent.withdraw.\(row.tier.rawValue)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
        // Key management for key-gated tiers. WP-29 F9: non-live rows hide
        // the Enter-key button (a dead control that would walk live-network
        // validation + Keychain storage for a tier that cannot serve); a
        // stored key on a non-live row still offers Delete so an inert
        // secret can be removed, otherwise the section stays hidden.
        if row.tier.requiresAPIKey, row.isLive || row.hasKey {
            ThemedRowDivider()
            HStack {
                Text(row.hasKey ? "Key stored" : "No key stored")
                    .font(Theme.font(12, .regular, relativeTo: .caption))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                if row.hasKey {
                    Button("Delete key") {
                        Task { await viewModel.deleteKey(for: row.tier) }
                    }
                    .accessibilityIdentifier("aimodels.key.delete.\(row.tier.rawValue)")
                } else if row.isLive {
                    Button("Enter key") { viewModel.beginKeyEntry(for: row.tier) }
                        .accessibilityIdentifier("aimodels.key.enter.\(row.tier.rawValue)")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
        // Model picker where applicable (keyed tiers only). Hidden for
        // non-live rows: preference-only (no network, no secret at rest),
        // but a dead control on a documentation row — F9 consistency call.
        if !row.modelOptions.isEmpty, let selected = row.modelID, row.isLive {
            ThemedRowDivider()
            HStack {
                Text("Model")
                    .font(Theme.font(12, .regular, relativeTo: .caption))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                Picker("Model", selection: Binding(
                    get: { selected },
                    set: { viewModel.setModel($0, for: row.tier) }
                )) {
                    ForEach(row.modelOptions, id: \.self) { option in
                        Text(shortModelName(option)).tag(option)
                    }
                }
                .accessibilityIdentifier("aimodels.model.\(row.tier.rawValue)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
    }

    private func quotaLine(for quota: PCCQuota) -> String {
        switch quota {
        case .ok:
            "Apple cloud -- included; daily limit tied to your iCloud account."
        case .nearLimit(let resetDate):
            if let resetDate {
                "Apple cloud -- near the daily limit tied to your iCloud account (resets \(resetDate.formatted(date: .abbreviated, time: .omitted)))."
            } else {
                "Apple cloud -- near the daily limit tied to your iCloud account."
            }
        case .exhausted(let resetDate):
            if let resetDate {
                "Apple cloud -- daily limit reached; resets \(resetDate.formatted(date: .abbreviated, time: .omitted))."
            } else {
                "Apple cloud -- daily limit reached."
            }
        }
    }

    /// Picker labels show the short family name (the full ID is the stored
    /// value, used verbatim by validation/dispatch).
    /// WP-29 F6: locale-insensitive matching — `lowercased().contains`
    /// breaks under tr/az locales (`I` folds to dotless `ı`).
    private func shortModelName(_ modelID: String) -> String {
        if modelID.range(of: "haiku", options: .caseInsensitive) != nil { return "Haiku" }
        if modelID.range(of: "sonnet", options: .caseInsensitive) != nil { return "Sonnet" }
        if modelID.range(of: "opus", options: .caseInsensitive) != nil { return "Opus" }
        if modelID.range(of: "pro", options: .caseInsensitive) != nil { return "Pro" }
        if modelID.range(of: "flash", options: .caseInsensitive) != nil { return "Flash" }
        return modelID
    }

    // MARK: - Consent sheet

    private func consentSheet(for tier: ModelTier) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if let copy = TierConsentCopy.forTier(tier) {
                    consentField(title: "Destination", value: copy.destination)
                    consentField(title: "What leaves your device", value: copy.dataLeaves)
                    consentField(title: "Privacy", value: copy.privacy)
                    consentField(title: "If you change your mind", value: copy.forgetNote)
                }
                Spacer()
                Button("Accept and continue") { viewModel.acceptConsent() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("aimodels.consent.accept")
                Button("Not now", role: .cancel) { viewModel.dismissSheet() }
                    .accessibilityIdentifier("aimodels.consent.decline")
            }
            .padding(20)
            .navigationTitle("Enable \(tier.displayName)?")
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("aimodels.consent.sheet")
        }
    }

    private func consentField(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.font(12, .medium, relativeTo: .caption))
                .foregroundStyle(Theme.secondary)
            Text(value)
                .font(Theme.font(14, .regular, relativeTo: .body))
                .foregroundStyle(Theme.ink)
        }
    }

    // MARK: - Key sheet

    private func keySheet(for tier: ModelTier) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Paste your API key. It's checked with a single 1-token request, then stored in the Keychain.")
                    .font(Theme.font(14, .regular, relativeTo: .body))
                    .foregroundStyle(Theme.secondary)
                SecureField("API key", text: Binding(
                    get: { viewModel.keyDraft },
                    set: { viewModel.keyDraft = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("aimodels.key.field")
                if let error = viewModel.keyError {
                    ThemedErrorText(message: error, accessibilityIdentifier: "aimodels.key.error")
                }
                Spacer()
                Button("Save key") {
                    Task { await viewModel.saveKey() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isValidating)
                .accessibilityIdentifier("aimodels.key.save")
                Button("Cancel", role: .cancel) { viewModel.dismissSheet() }
                    .accessibilityIdentifier("aimodels.key.cancel")
            }
            .padding(20)
            .navigationTitle("\(tier.displayName) key")
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("aimodels.key.sheet")
        }
    }
}
