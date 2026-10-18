// swift-tools-version: 6.4
// Tools version 6.4 (WP-83): local dev and every CI job build with Xcode 27
// (implementation-plan.md "Toolchain note"). iOS platform is 27.0 -- the app
// target requires it; macOS stays 26.0 because the `xcode-27` CI image is a
// macOS 26 host and `swift test` runs there.
import PackageDescription

// CoreModel: SwiftData models + shared value types. No I/O, no HealthKit import.
// See architecture.md §2 (module map) and §3 (concurrency model).

let package = Package(
    name: "CoreModel",
    platforms: [.iOS("27.0"), .macOS("26.0")],
    products: [
        .library(name: "CoreModel", targets: ["CoreModel"]),
    ],
    targets: [
        .target(
            name: "CoreModel",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
        .testTarget(
            name: "CoreModelTests",
            dependencies: ["CoreModel"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
    ]
)
