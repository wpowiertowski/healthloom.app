// InsightNotificationContent.swift
//
// WP-34 (implementation-plan.md): "headline only — no health values on the
// lock screen by default; toggle for full text." Redaction happens here,
// at construction (AGENTS.md §2: redact at construction), not in the
// notifier — the `UNNotificationContent` below can only ever carry what
// this builder produced.
//
// - Headline-only (default): fixed non-health title + the headline with
//   every numeric token replaced by "•". Headlines routinely carry values
//   ("down 4 bpm", "8,240 steps"), so showing the raw headline would break
//   the "no health values" promise this mode makes.
// - Full text (opt-in toggle): headline + suggestions verbatim.
// Single source: `redacted(_:)` is the one definition both the builder
// and its tests reference — tests assert *which* redaction, never
// re-type the expected strings by hand where avoidable.

import Foundation

enum InsightNotificationContent {
    struct Built: Equatable {
        var title: String
        var body: String
    }

    /// Replaces every numeric token (commas stripped first, so "8,240" is
    /// one token, not two) with a bullet. Decimals survive as one token.
    static func redacted(_ text: String) -> String {
        let stripped = text.replacingOccurrences(of: ",", with: "")
        guard let regex = try? NSRegularExpression(pattern: #"[0-9]+(?:\.[0-9]+)?"#) else { return text }
        let range = NSRange(stripped.startIndex..., in: stripped)
        return regex.stringByReplacingMatches(in: stripped, range: range, withTemplate: "•")
    }

    static func make(headline: String, suggestions: [String], fullText: Bool) -> Built {
        if fullText {
            return Built(
                title: "Your morning insight",
                body: ([headline] + suggestions).joined(separator: "\n")
            )
        }
        return Built(title: "Your morning insight is ready", body: redacted(headline))
    }
}
