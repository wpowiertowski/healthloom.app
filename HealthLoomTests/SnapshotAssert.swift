// SnapshotAssert.swift
//
// Local snapshot helper (HealthLoomTests). Owner directive: strict
// warnings-as-errors everywhere, with no carve-outs — so instead of the
// remote swift-snapshot-testing package (whose own source carries iOS-15
// deprecation warnings under the Xcode 27 SDK), snapshots render through
// SwiftUI's `ImageRenderer` and compare per-pixel against checked-in
// references next to the calling test file.
//
// Contract: deterministic inputs give deterministic bytes on the same
// machine (explicit renderer scale, fixed subject width, no live dates
// in subjects) — but NOT byte-identical bytes across GPU implementations:
// CI runners vs local Metal pipelines rasterize antialiased edges a few
// LSBs apart (measured: identical run-to-run locally, 3–13 file bytes
// apart cross-machine, AXXXL only). Comparison is therefore per-pixel
// with a named tolerance (`matchesPixelwise`), not byte equality: GPU
// shimmer passes, any visible change fails. To regenerate: set
// `SNAPSHOT_RECORD=1` in the test scheme's environment (Xcode: scheme →
// Test → Arguments → Environment Variables — `xcodebuild test` CLI does
// NOT forward shell env into the simulator test host, so a shell-prefixed
// run compares instead of recording). Recording writes the reference and
// fails loudly so a record pass can never go green unnoticed; commit the
// PNGs; CI compares pixels.

import SwiftUI
import Testing
import UIKit

enum SnapshotAssert {
    /// Renders `view` at a fixed 390pt width under the given appearance
    /// and compares against the checked-in reference
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
        recordOrCompare(data: data, name: name, url: url)
    }

    /// Window-hosted variant (third-party F-A): `ImageRenderer` renders
    /// `ScrollView` content empty — it has no intrinsic size for the
    /// renderer to lay out against — so the welcome refs pinned blank
    /// canvas. Hosting in a live window and drawing the hierarchy renders
    /// real pixels; sizing comes from `sizeThatFits` so full scroll
    /// content (taller than any screen at AXXXL) is captured, not just
    /// the viewport. Compare/record semantics identical to `assert`.
    @MainActor
    static func assertHosted(
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
        let hosting = UIHostingController(rootView: configured)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            Issue.record("Snapshot '\(name)': no window scene — test bundle must be app-hosted")
            return
        }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        let target = hosting.view.sizeThatFits(CGSize(width: 390, height: CGFloat.greatestFiniteMagnitude))
        hosting.view.frame = CGRect(origin: .zero, size: target)
        hosting.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2 // match `assert`'s explicit scale (CI picks its own device)
        // 8-bit SDR: the default `.automatic` range follows the display
        // into 16-bit output, which loads with a runtime libpng depth
        // warning and doubles ref size for zero test value.
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            hosting.view.drawHierarchy(in: CGRect(origin: .zero, size: target), afterScreenUpdates: true)
        }
        guard let data = image.pngData() else {
            Issue.record("Snapshot '\(name)': hosted render produced no image")
            return
        }
        let url = referenceURL(name: name, callerFile: file)
        recordOrCompare(data: data, name: name, url: url)
    }

    /// Shared record-or-compare tail for both render paths.
    @MainActor
    private static func recordOrCompare(data: Data, name: String, url: URL) {
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
        // Fast path: identical bytes (same-machine re-runs) skip decode.
        if reference == data {
            return
        }
        switch matchesPixelwise(reference: reference, candidate: data) {
        case .match:
            return
        case .decodeFailure(let side):
            Issue.record("Snapshot '\(name)': \(side) PNG undecodable — re-record after reviewing")
        case .sizeMismatch(let referenceSize, let candidateSize):
            Issue.record(
                "Snapshot '\(name)' size changed \(referenceSize) → \(candidateSize): layout regression"
            )
        case .pixelsDiffer(let count, let worst):
            Issue.record("Snapshot '\(name)' differs in \(count) pixels (worst \(worst)): visible change")
        }
    }

    /// Pixel comparison outcome. Thresholds (`channelTolerance`,
    /// `maxDifferingPixels`) are calibrated below: GPU shimmer is
    /// single-LSB edge noise on a handful of pixels; the smallest
    /// meaningful content change (one digit) moves thousands.
    enum PixelMatch: Equatable {
        case match
        case decodeFailure(side: String)
        case sizeMismatch(reference: String, candidate: String)
        case pixelsDiffer(count: Int, worstDelta: Int)
    }

    /// Per-channel tolerance: antialiased-edge shimmer between Metal
    /// implementations stays in single digits; a wrong color or glyph
    /// differs by tens-to-hundreds per channel.
    static let channelTolerance = 16

    /// Cap on shimmer pixels: CI-vs-local diffs touch a handful (3–13
    /// file bytes); the 82→83 digit mutation moves 1247 (XS) to 3836
    /// (AXXXL) pixels with worst-delta ~200 (measured M2 run). Fixed
    /// count, not fraction: image sizes vary by subject, and a fraction
    /// would let large subjects absorb real changes.
    static let maxDifferingPixels = 256

    static func matchesPixelwise(reference: Data, candidate: Data) -> PixelMatch {
        guard let ref = rgbaPixels(reference) else { return .decodeFailure(side: "reference") }
        guard let cand = rgbaPixels(candidate) else { return .decodeFailure(side: "candidate") }
        guard ref.width == cand.width, ref.height == cand.height else {
            return .sizeMismatch(
                reference: "\(ref.width)x\(ref.height)",
                candidate: "\(cand.width)x\(cand.height)"
            )
        }
        var differing = 0
        var worst = 0
        for i in stride(from: 0, to: ref.pixels.count, by: 4) {
            var pixelWorst = 0
            for channel in 0..<4 {
                let delta = abs(Int(ref.pixels[i + channel]) - Int(cand.pixels[i + channel]))
                pixelWorst = max(pixelWorst, delta)
            }
            if pixelWorst > channelTolerance {
                differing += 1
                worst = max(worst, pixelWorst)
            }
        }
        if differing > maxDifferingPixels {
            return .pixelsDiffer(count: differing, worstDelta: worst)
        }
        return .match
    }

    /// Decodes PNG bytes to straight RGBA8888 via a bitmap context (one
    /// canonical pipeline for both sides, so premultiplication and color
    /// matching cannot disagree between reference and candidate).
    /// Nonisolated: pure CoreGraphics, no UI state.
    nonisolated static func rgbaPixels(_ data: Data) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let result = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard result else { return nil }
        return (pixels, width, height)
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
