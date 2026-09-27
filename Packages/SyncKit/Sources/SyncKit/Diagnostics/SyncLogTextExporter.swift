// SyncLogTextExporter.swift
//
// WP-18 (implementation-plan.md): "export-as-text for support ... a
// plain-text dump suitable for user support -- counts and types only, never
// values." Pure, testable formatting kept in SyncKit (not the app target)
// so the exact text shape has package-level golden tests, and so the app's
// `SyncLogView`/share-sheet button (HealthLoomApp/Diagnostics/) is a thin,
// untestable-by-nature SwiftUI wrapper around one already-verified
// function.
import Foundation

nonisolated public enum SyncLogTextExporter {
    /// Renders `entries` (any order -- this function sorts newest-first
    /// itself, so callers don't have to agree on a convention) as one
    /// plain-text block: a header naming the export time and entry count,
    /// then one line per entry -- ISO-8601 timestamp, data type, status,
    /// item count, and (only when present) the already-redacted error
    /// text. Every field here traces back to `SyncLogEntry`'s own
    /// structurally-safe shape (architecture.md D11) -- nothing new is
    /// interpolated that wasn't already safe to log.
    public static func export(_ entries: [SyncLogEntry], generatedAt: Date = Date()) -> String {
        let sorted = entries.sorted { $0.timestamp > $1.timestamp }
        var lines = [
            "HealthLoom Sync Log Export",
            "Generated: \(iso8601.string(from: generatedAt))",
            "Entries: \(sorted.count)",
            "",
        ]
        lines.append(contentsOf: sorted.map(line(for:)))
        return lines.joined(separator: "\n")
    }

    private static func line(for entry: SyncLogEntry) -> String {
        let timestamp = iso8601.string(from: entry.timestamp)
        let type = entry.dataType.rawValue
        let status = entry.status.rawValue
        var line = "\(timestamp)  \(type)  \(status)  \(entry.itemCount) item(s)"
        if let deferred = entry.deferredText {
            // WP-12b (test-plan.md §2.3's bookkeeping row): still a count,
            // never a value -- same D11 posture as every other field here.
            line += "  \u{00B7} \(deferred)"
        }
        if let errorMessage = entry.errorMessage {
            line += "  \u{2014} \(errorMessage)"
        }
        return line
    }

    // `nonisolated(unsafe)`: configured once below and never mutated again --
    // same documented pattern GoogleHealthClient's own
    // `ISO8601Formatting.swift` uses for the identical type.
    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
