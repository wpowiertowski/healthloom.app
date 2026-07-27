// SyncLogView.swift
//
// WP-18 (implementation-plan.md): Settings -> "Sync log" viewer -- "list of
// recent runs (timestamp, type, status, count, error text), with an
// export-as-text button (share sheet) producing a plain-text dump suitable
// for user support -- counts and types only, never values."
//
// Talks to `AppEnvironment.syncLogStore` (SyncKit's `actor SyncLogStore`,
// `Packages/SyncKit/Sources/SyncKit/Diagnostics/SyncLogStore.swift`)
// exclusively through its `async` public API, matching this app target's
// established "actor-backed state -> poll on a `.task` loop" convention
// (`BackfillView.swift`, WP-15) rather than inventing a different pattern
// for this WP's own actor-backed store -- `SyncLogStore` isn't
// `@Observable`/SwiftData-backed (see that file's own header for why), so
// there is nothing here to `@Query`.
//
// Export text is produced by SyncKit's own `SyncLogTextExporter` (pure,
// package-level golden-tested) -- this view is a thin, untestable-by-nature
// SwiftUI wrapper around one already-verified function, exactly the split
// `SyncLogTextExporter.swift`'s own header describes.

import CoreModel
import SwiftUI
import SyncKit

struct SyncLogView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @State private var entries: [SyncLogEntry] = []
    @State private var hasLoadedOnce = false

    private var exportText: String {
        SyncLogTextExporter.export(entries)
    }

    // WP-33 follow-on (Shared/ThemedChrome.swift): Yacht club presentation.
    // Always pushed (from Settings), so it keeps the system navigation bar
    // for back/swipe; the toolbar's ShareLink moves into the themed header,
    // since a tab-root-style header replaces the bar's own content.
    var body: some View {
        ThemedScreen(title: "Sync Log", chrome: .pushed) {
            ShareLink(item: exportText, preview: SharePreview("HealthLoom Sync Log")) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(entries.isEmpty ? Theme.tertiary : Theme.ink)
                    .frame(width: 24, height: 24)
            }
            .accessibilityLabel("Export")
            .accessibilityIdentifier("synclog.export")
            .disabled(entries.isEmpty)
        } content: {
            Text("Recent sync activity, most recent first. Only counts, types, and timestamps are kept here -- never your health data or account credentials.")
                .font(Theme.font(13, .regular, relativeTo: .footnote))
                .foregroundStyle(Theme.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 18)
                .accessibilityIdentifier("synclog.disclaimer")

            if entries.isEmpty {
                Text(hasLoadedOnce ? "No sync runs recorded yet." : "Loading…")
                    .font(Theme.font(13, .regular, relativeTo: .footnote))
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 24)
                    .accessibilityIdentifier("synclog.empty")
            } else {
                ThemedSectionHeader(title: "Recent Runs")
                ThemedPanel {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { ThemedRowDivider() }
                        SyncLogRow(entry: entry)
                    }
                }
            }
        }
        .task {
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await refresh()
            }
        }
        .refreshable { await refresh() }
    }

    private func refresh() async {
        let store = appEnvironment.syncLogStore
        // `SyncLogStore.recentEntries()` returns oldest-first (that actor's
        // own doc comment); this viewer displays newest-first, matching
        // `SyncLogTextExporter`'s own ordering choice for the export text.
        entries = Array(await store.recentEntries().reversed())
        hasLoadedOnce = true
    }
}

#Preview {
    NavigationStack {
        SyncLogView()
    }
    .environment(AppEnvironment())
}
