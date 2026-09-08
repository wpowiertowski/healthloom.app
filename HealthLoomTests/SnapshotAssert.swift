// SnapshotAssert.swift
//
// Local snapshot helper (HealthLoomTests). Owner directive: strict
// warnings-as-errors everywhere, with no carve-outs — so instead of the
// remote swift-snapshot-testing package (whose own source carries iOS-15
// deprecation warnings under the Xcode 27 SDK), snapshots render through
// SwiftUI's `ImageRenderer` and byte-compare PNG data against checked-in
// references next to the calling test file.
//
// Contract: deterministic inputs give deterministic bytes on the same
// simulator runtime (explicit renderer scale, fixed subject width, no
// live dates in subjects). To regenerate: set `SNAPSHOT_RECORD=1` in the
// test scheme's environment (Xcode: scheme → Test → Arguments →
// Environment Variables — `xcodebuild test` CLI does NOT forward shell
// env into the simulator test host, so a shell-prefixed run compares
// instead of recording). Recording writes the reference and fails loudly
// so a record pass can never go green unnoticed; commit the PNGs; CI
// compares bytes.

import SwiftUI
import Testing

enum SnapshotAssert {
    /// Renders `view` at a fixed 390pt width under the given appearance
    /// and compares PNG bytes with the checked-in reference
    /// `__Snapshots/<TestFileName>/<name>.png` next to the caller.
    @MainActor
    static func assert(
        _ view: some View,
        named name: String,
        colorScheme: ColorScheme,
        sizeCategory: ContentSizeCategory,
        file: StaticString = #filePath
    ) {
        let configured = AnyView(view
            .environment(\.colorScheme, colorScheme)
            .environment(\.sizeCategory, sizeCategory)
            .frame(width: 390))
        let renderer = ImageRenderer(content: configured)
        // Explicit scale: the simulator model's screen scale must not leak
        // into reference bytes (CI picks its own device).
        renderer.scale = 2
        guard let data = renderer.uiImage?.pngData() else {
            Issue.record("Snapshot '\(name)': render produced no image")
            return
        }
        let url = referenceURL(name: name, callerFile: file)
        if ProcessInfo.processInfo.environment["SNAPSHOT_RECORD"] == "1" {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url)
            } catch {
                Issue.record("Snapshot '\(name)': record write failed: \(error)")
                return
            }
            Issue.record("Snapshot '\(name)' recorded — re-run without SNAPSHOT_RECORD=1")
            return
        }
        guard let reference = try? Data(contentsOf: url) else {
            Issue.record("Snapshot '\(name)': missing reference — re-run with SNAPSHOT_RECORD=1")
            return
        }
        if reference != data {
            Issue.record("Snapshot '\(name)' mismatch: got \(data.count) bytes, reference \(reference.count)")
        }
    }

    private static func referenceURL(name: String, callerFile: StaticString) -> URL {
        let caller = URL(fileURLWithPath: "\(callerFile)")
        let suite = caller.deletingPathExtension().lastPathComponent
        return caller
            .deletingLastPathComponent()
            .appendingPathComponent("__Snapshots__", isDirectory: true)
            .appendingPathComponent(suite, isDirectory: true)
            .appendingPathComponent("\(name).png")
    }
}
