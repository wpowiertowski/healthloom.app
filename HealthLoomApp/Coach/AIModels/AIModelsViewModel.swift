// AIModelsViewModel.swift
//
// WP-29 (implementation-plan.md): Settings → AI Models. One row per
// `ModelTier` (status from `catalog.availability(for:)`), with the enable
// flows the plan mandates:
//
//   - Every off-device tier requires the consent sheet before first enable
//     (decline = stays off). Consent records per tier with timestamp in
//     `TierSettingsStore`.
//   - Key-gated tiers (Claude/Gemini) require a validated key after consent:
//     SecureField → 1-token ping → Keychain. A rejected key or a transport
//     failure never stores; cancel leaves the tier off.
//   - The row toggle is a preference, NOT the gate: a tier is effectively
//     on only when the toggle is on AND `catalog.isEnabled` passes. Turning
//     a row off keeps consent + key (cheap re-enable); deleting a key or
//     withdrawing consent drops the effective state while the toggle stays
//     put, and the row renders the blocker's reason.
//   - PCC rows show quota state (`pccQuota`, refreshed on appear); keyed
//     rows show the model picker (`CloudModelOptions`).
//
// The catalog's `hasConsent`/`hasKey` closures read `CloudGateCache` (sync
// bridge -- see that file); this view model is the cache's writer on this
// screen (`refresh()` fills both maps from source, every mutation updates
// its own entry), so gate and rows agree after every action.

import CoachKit
import Foundation
import Observation
import Secrets

/// Consent-screen copy per off-device tier (WP-29: name the destination,
/// state what data leaves, state the privacy properties, note prior turns
/// can't be recalled). Single edit point -- the sheet renders these fields
/// verbatim, tests assert which tier maps to which destination.
struct TierConsentCopy: Sendable, Equatable {
    var destination: String
    var dataLeaves: String
    var privacy: String
    var forgetNote: String

    static func forTier(_ tier: ModelTier) -> TierConsentCopy? {
        switch tier {
        case .onDevice:
            nil
        case .privateCloudCompute:
            TierConsentCopy(
                destination: "Apple Private Cloud Compute",
                dataLeaves: "Your profile fields and messages needed for the reply.",
                privacy: "Apple does not store your requests and does not use them for training.",
                forgetNote: "Withdrawing consent stops future use. Turns already sent can't be recalled."
            )
        case .claude:
            TierConsentCopy(
                destination: "Anthropic's API (your key)",
                dataLeaves: "Your profile fields and messages needed for the reply.",
                privacy: "Anthropic's commercial terms apply to what you send.",
                forgetNote: "Deleting your key or withdrawing consent stops future use. Turns already sent can't be recalled."
            )
        case .gemini:
            TierConsentCopy(
                destination: "Google's Gemini API (your key)",
                dataLeaves: "Your profile fields and messages needed for the reply.",
                privacy: "Google's API terms apply to what you send.",
                forgetNote: "Deleting your key or withdrawing consent stops future use. Turns already sent can't be recalled."
            )
        }
    }
}

/// Key-sheet copy: the title, the intro, and one message per failed key
/// check. Single edit point -- the sheet and `saveKey` render these
/// verbatim, tests assert which function a result maps to. Every failure
/// says what is likely wrong and where to fix it, in the issuer's own
/// console.
enum KeyCheckCopy {
    /// Who issues a key-gated tier's keys, and where the user manages them.
    struct Provider: Sendable, Equatable {
        var name: String
        var console: String
        var keyName: String

        static let anthropic = Provider(name: "Anthropic", console: "the Anthropic Console", keyName: "Anthropic API key")
        static let google = Provider(name: "Google", console: "Google AI Studio", keyName: "Gemini API key")
    }

    static let emptyDraft = "Enter a key first."
    static let notStored = "Your key was not stored."

    static func provider(for tier: ModelTier) -> Provider? {
        switch tier {
        case .claude: .anthropic
        case .gemini: .google
        case .onDevice, .privateCloudCompute: nil
        }
    }

    static func title(for tier: ModelTier) -> String {
        provider(for: tier)?.keyName ?? "\(tier.displayName) key"
    }

    static func intro(for tier: ModelTier) -> String {
        let source = provider(for: tier).map { " from \($0.console)" } ?? ""
        return "Paste an API key\(source). It's checked with a single 1-token request, then stored in the Keychain."
    }

    static func invalidKey(_ provider: Provider) -> String {
        "\(provider.name) rejected that key. Check that you copied all of it and that it hasn't been revoked in \(provider.console)."
    }

    /// The provider answered but refused the check: a hint for the reason,
    /// then the provider's own message, so an unclassified refusal still
    /// says something specific.
    static func refused(_ refusal: KeyCheckRefusal, _ provider: Provider) -> String {
        let source = refusal.detail.map { "\(provider.name)'s message (HTTP \(refusal.statusCode)): \($0)" }
            ?? "\(provider.name) answered with HTTP \(refusal.statusCode)."
        return [hint(for: refusal.reason, provider), source, notStored].joined(separator: "\n")
    }

    static func hint(for reason: KeyCheckRefusal.Reason, _ provider: Provider) -> String {
        switch reason {
        case .billing:
            "Your \(provider.name) account is out of credit. Add credits or a payment method in \(provider.console), then try again."
        case .permission:
            "This key's account isn't allowed to make this request. Check the key's workspace and access settings in \(provider.console)."
        case .modelUnavailable:
            "This key's account can't use the model the check runs on. Check model access in \(provider.console)."
        case .rateLimited:
            "\(provider.name) is limiting requests from this key. Wait a minute, then try again."
        case .providerOutage:
            "\(provider.name) is having problems right now. Try again in a few minutes."
        case .other:
            "\(provider.name) couldn't check the key."
        }
    }

    /// No answer at all: the system's description (it carries its own
    /// punctuation) on its own line.
    static func unreachable(_ description: String, _ provider: Provider) -> String {
        [
            "Couldn't reach \(provider.name). Check your internet connection, then try again.",
            description,
            notStored,
        ].joined(separator: "\n")
    }
}

/// The settings screen's one presented sheet. A single enum (not two
/// sibling `ModelTier?` optionals): two `.sheet(item:)` modifiers of the
/// same bound type on one view conflict and neither presents -- one typed
/// item keeps presentation unambiguous.
enum AIModelsSheet: Identifiable, Equatable {
    case consent(ModelTier)
    case keyEntry(ModelTier)

    var id: String {
        switch self {
        case .consent(let tier): "consent.\(tier.rawValue)"
        case .keyEntry(let tier): "key.\(tier.rawValue)"
        }
    }

    var tier: ModelTier {
        switch self {
        case .consent(let tier), .keyEntry(let tier): tier
        }
    }
}

@MainActor
@Observable
final class AIModelsViewModel {
    struct Dependencies {
        var catalog: ModelCatalog
        var settings: TierSettingsStore
        var gates: CloudGateCache
        var keys: any CloudKeyStoring
        var validator: any CloudKeyValidating
    }

    /// One rendered row. `effectivelyOn` (toggle AND gate) is the source of
    /// truth for "on"; `availability` explains every off state.
    struct TierRow: Identifiable {
        let tier: ModelTier
        let isTurnedOn: Bool
        let effectivelyOn: Bool
        /// WP-29 F3 (decision (a)): the view disables toggles for non-live
        /// rows so they ladder-document without collecting consent/keys.
        let isLive: Bool
        let availability: TierAvailability
        let hasKey: Bool
        let consentDate: Date?
        let modelID: String?
        let modelOptions: [String]
        /// PCC only (nil for every other tier): the quota line under the row.
        let quota: PCCQuota?
        var id: ModelTier { tier }
    }

    private let deps: Dependencies
    private var cachedQuota: PCCQuota?
    /// Render truth for key presence (WP-29 F1). `CloudGateCache` is
    /// deliberately not `@Observable` (it serves `@Sendable` catalog
    /// closures), so every `gates.setKeyPresent` call site updates this
    /// mirror alongside it and `rows()` reads the mirror — key mutations
    /// publish instead of going stale until leave-and-return.
    private var keyPresence: [ModelTier: Bool] = [:]

    /// Presented sheet (single item -- see `AIModelsSheet`).
    var sheet: AIModelsSheet?
    var keyDraft = ""
    /// Entry-sheet error (invalid key, transport failure, Keychain failure).
    var keyError: String?
    var isValidating = false
    /// Row-level failure with no sheet to host it (key delete, refresh).
    var bannerMessage: String?

    init(deps: Dependencies) {
        self.deps = deps
        for tier in ModelTier.allCases {
            keyPresence[tier] = deps.gates.hasKey(tier)
        }
    }

    // MARK: - Rows

    func rows() -> [TierRow] {
        ModelTier.allCases.map { tier in
            let turnedOn = deps.settings.isTurnedOn(tier)
            return TierRow(
                tier: tier,
                isTurnedOn: turnedOn,
                effectivelyOn: turnedOn && deps.catalog.isEnabled(tier),
                isLive: deps.catalog.isLive(tier),
                availability: deps.catalog.availability(for: tier),
                hasKey: !tier.requiresAPIKey || (keyPresence[tier] ?? false),
                consentDate: deps.settings.consentDate(for: tier),
                modelID: CloudModelOptions.resolvedModelID(
                    stored: deps.settings.modelOverride(for: tier),
                    for: tier
                ),
                modelOptions: CloudModelOptions.options(for: tier),
                quota: tier == .privateCloudCompute ? cachedQuota : nil
            )
        }
    }

    /// Fills the gate cache from source (Keychain presence, live quota) --
    /// the launch fill covers first render; views call this on appear, so
    /// cache and catalog agree. (WP-29 F8: sheet presentation does not
    /// destroy the parent view, so `.task` does not re-fire on sheet
    /// dismiss — the guarded `cachedQuota` write below is still correct,
    /// it just guards appear-time re-runs, not sheet churn.)
    func refresh() async {
        // WP-29 F4: a transient Keychain failure banners, but a later
        // successful refresh must clear it instead of leaving it stale.
        bannerMessage = nil
        for tier in ModelTier.allCases {
            deps.gates.setConsent(deps.settings.hasConsent(for: tier), for: tier)
        }
        for tier in ModelTier.allCases where tier.requiresAPIKey {
            guard let secretKey = tier.secretKey else { continue }
            do {
                let value = try await deps.keys.get(secretKey)
                deps.gates.setKeyPresent(value != nil, for: tier)
                keyPresence[tier] = value != nil
            } catch {
                bannerMessage = "Couldn't read stored keys: \(error.localizedDescription)"
            }
        }
        let quota = deps.catalog.pccQuota()
        // Guarded (not unconditional): notifying with an unchanged value
        // would still regenerate the accessibility tree under settling
        // UI-test snapshots.
        if cachedQuota != quota {
            cachedQuota = quota
        }
    }

    // MARK: - Enable flow

    /// Row toggle. Turning off is unconditional (consent + key are kept).
    /// Turning on walks the blockers in gate order -- consent first, then
    /// key -- presenting sheets instead of flipping when one is missing,
    /// which is exactly the "blocked without consent/key" behavior the
    /// WP-29 tests assert.
    func setTurnedOn(_ turnedOn: Bool, for tier: ModelTier) {
        guard turnedOn else {
            deps.settings.setTurnedOn(false, for: tier)
            return
        }
        // WP-29 F3, decision (a): non-live rows are ladder documentation —
        // the view disables their toggles, and this guard holds the line
        // for programmatic callers so no consent sheet, network ping, or
        // Keychain write can ever start for a tier that cannot serve.
        guard deps.catalog.isLive(tier) else { return }
        if tier.requiresConsent && !deps.settings.hasConsent(for: tier) {
            sheet = .consent(tier)
            return
        }
        if tier.requiresAPIKey && !deps.gates.hasKey(tier) {
            beginKeyEntry(for: tier)
            return
        }
        deps.settings.setTurnedOn(true, for: tier)
    }

    func acceptConsent() {
        guard case .consent(let tier) = sheet else { return }
        deps.settings.recordConsent(for: tier)
        deps.gates.setConsent(true, for: tier)
        // Continue the interrupted enable WITHOUT an intermediate nil:
        // `.consent` -> `nil` -> `.keyEntry` in one transaction morphs the
        // sheet (dismiss + present in flight), churning the presentation
        // tree for seconds afterward. A direct item swap keeps one live
        // sheet whose content changes; a clean dismiss only when no key
        // step follows.
        if tier.requiresAPIKey && !deps.gates.hasKey(tier) {
            keyDraft = ""
            keyError = nil
            sheet = .keyEntry(tier)
        } else {
            sheet = nil
            deps.settings.setTurnedOn(true, for: tier)
        }
    }

    /// Swipe-to-dismiss (or programmatic nil): consent dismissal is a
    /// decline; key dismissal clears the draft like cancel.
    func dismissSheet() {
        if case .keyEntry = sheet {
            keyDraft = ""
            keyError = nil
        }
        sheet = nil
    }

    func withdrawConsent(for tier: ModelTier) {
        deps.settings.withdrawConsent(for: tier)
        deps.gates.setConsent(false, for: tier)
    }

    // MARK: - Key entry

    /// Opens the key sheet. WP-29 F9: the single choke point for key entry
    /// (row-toggle path via `setTurnedOn` + Enter-key button path) — guarded
    /// on liveness so no sheet, network ping, or Keychain write can start
    /// for a tier that cannot serve. `saveKey` needs no duplicate guard:
    /// it requires `sheet == .keyEntry`, which is only reachable through
    /// this function and the (already liveness-guarded) consent flow.
    func beginKeyEntry(for tier: ModelTier) {
        guard deps.catalog.isLive(tier) else { return }
        keyDraft = ""
        keyError = nil
        sheet = .keyEntry(tier)
    }

    /// Validates the draft with a 1-token ping, then stores. Only `.valid`
    /// stores: every other result surfaces its `KeyCheckCopy` and leaves
    /// the Keychain (and the toggle) untouched.
    func saveKey() async {
        guard case .keyEntry(let tier) = sheet,
              let secretKey = tier.secretKey,
              let provider = KeyCheckCopy.provider(for: tier) else { return }
        let draft = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else {
            keyError = KeyCheckCopy.emptyDraft
            return
        }
        isValidating = true
        defer { isValidating = false }
        switch await deps.validator.validate(key: draft, for: tier) {
        case .valid:
            do {
                try await deps.keys.set(draft, for: secretKey)
            } catch {
                keyError = "Couldn't store the key: \(error.localizedDescription)"
                return
            }
            deps.gates.setKeyPresent(true, for: tier)
            keyPresence[tier] = true
            sheet = nil
            keyDraft = ""
            keyError = nil
            deps.settings.setTurnedOn(true, for: tier)
        case .invalidKey:
            keyError = KeyCheckCopy.invalidKey(provider)
        case .refused(let refusal):
            keyError = KeyCheckCopy.refused(refusal, provider)
        case .transportError(let description):
            keyError = KeyCheckCopy.unreachable(description, provider)
        }
    }

    /// Key deletion drops the effective state through the gate (the toggle
    /// preference stays, so re-entering a key re-enables without
    /// re-consenting) -- the "key delete disables tier" test asserts the
    /// row goes off, not that preferences reset.
    func deleteKey(for tier: ModelTier) async {
        guard let secretKey = tier.secretKey else { return }
        do {
            try await deps.keys.delete(secretKey)
        } catch {
            bannerMessage = "Couldn't delete the key: \(error.localizedDescription)"
            return
        }
        deps.gates.setKeyPresent(false, for: tier)
        keyPresence[tier] = false
    }

    // MARK: - Model picker

    func setModel(_ modelID: String, for tier: ModelTier) {
        deps.settings.setModelOverride(modelID, for: tier)
    }
}
