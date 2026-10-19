// swift-tools-version: 6.4
// Tools version 6.4 (WP-83): local dev and every CI job build with Xcode 27
// (implementation-plan.md "Toolchain note"). iOS platform is 27.0 -- the app
// target requires it; macOS stays 26.0 because the `xcode-27` CI image is a
// macOS 26 host and `swift test` runs there.
import PackageDescription

// CoachKit: provider abstraction, prompt/knowledge/context layers, readiness.
// Depends on CoreModel, Secrets, and (as of WP-19) SyncKit -- reuses
// `HealthKitAuth.requestRead(_:)` (WP-06) for KnowledgeStore's own read
// authorization and `isClinicalType` (WP-14's `Routing/ClinicalClassification
// .swift`, whose header explicitly asks WP-19 to call it rather than
// re-deriving the ECG/IRN list). Module map ordering (architecture.md §2)
// allows this: SyncKit sits above CoachKit, so CoachKit may depend on it.
// Reads health data only through KnowledgeStore (HealthKit queries +
// LocalSample) -- never through GoogleHealthClient. See architecture.md §2
// (module map) and §3 (concurrency model).

let package = Package(
    name: "CoachKit",
    platforms: [.iOS("27.0"), .macOS("26.0")],
    products: [
        .library(name: "CoachKit", targets: ["CoachKit"]),
    ],
    // NOTE: CoachEval ships no product — the nightly model-in-the-loop lane
    // links it directly when the SDK provides the Evaluations module
    // (WP-31). Keeping it target-only avoids new public package surface.
    dependencies: [
        .package(path: "../CoreModel"),
        .package(path: "../Secrets"),
        .package(path: "../SyncKit"),
    ],
    targets: [
        .target(
            name: "CoachKit",
            dependencies: ["CoreModel", "Secrets", "SyncKit"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
        .testTarget(
            name: "CoachKitTests",
            dependencies: ["CoachKit", "SyncKit"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
        // WP-31: eval sets + deterministic scorers + nightly runner seam.
        // Runs in CI with canned outputs (no model); the model-in-the-loop
        // half needs a macOS 27 host or designated device (test plan §11).
        .target(
            name: "CoachEval",
            dependencies: ["CoachKit", "CoreModel"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
        .testTarget(
            name: "CoachEvalTests",
            dependencies: ["CoachEval", "CoachKit", "CoreModel"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
    ]
)
