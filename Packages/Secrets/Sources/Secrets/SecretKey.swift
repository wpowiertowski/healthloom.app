// SecretKey.swift
//
// WP-03 (implementation-plan.md): the closed set of things HealthLoom ever
// stores in the Keychain. Deliberately an enum (not a free-form String) so
// every call site is a compile-time-checked case — no typos, no accidental
// collisions with unrelated Keychain items.

/// Identifies a single secret value stored via `KeychainStore`.
///
/// Raw values are dot-namespaced by domain (`google.*`, `provider.*`) so that
/// `KeychainStore.deleteAll(matching:)` can select a whole domain by string
/// prefix — e.g. `"provider."` matches every cloud AI provider key and none
/// of the Google OAuth keys, and vice versa for `"google."`. Keep this
/// invariant (one dot-separated namespace segment per domain) if you add
/// cases later.
public enum SecretKey: String, Sendable, Hashable, CaseIterable {
    /// Google OAuth refresh token (long-lived; see GoogleAuthManager, WP-04).
    case googleRefreshToken = "google.refreshToken"
    /// Google OAuth access token (short-lived, cached between refreshes).
    case googleAccessToken = "google.accessToken"
    /// User-supplied Anthropic (Claude) API key (WP-28/29 — cloud opt-in).
    case claudeAPIKey = "provider.claude.apiKey"
    /// User-supplied OpenAI API key. Deferred with no tier (WP-27 review
    /// §9): architecture.md §7 Q6 + WP-28 ship no OpenAI row until an
    /// official/vetted `LanguageModel` conformance exists ("do not
    /// hand-roll"), so nothing maps here yet. Kept (not deleted) so the
    /// case exists when the tier lands.
    case openAIAPIKey = "provider.openai.apiKey"
    /// User-supplied Google Gemini API key (WP-28/29 — cloud opt-in).
    case geminiAPIKey = "provider.gemini.apiKey"
}
