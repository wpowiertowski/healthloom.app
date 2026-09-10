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

    /// Replaces every numeric token with a bullet. A comma joins the
    /// token ONLY between digits ("8,240" redacts as one bullet; a
    /// prose comma after a bare number — "down 4, rest well" —
    /// survives, since the comma isn't followed by a digit).
    /// Round-6 item 15: the old strip-all-commas-first mangled
    /// lock-screen copy ("Good morning, it's time" lost its comma).
    /// Decimals survive as one token.
    static func redacted(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"[0-9]+(?:,[0-9]+)*(?:\.[0-9]+)?"#) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "•")
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
