// swift-tools-version: 6.4
// Tools version 6.4 (WP-83): local dev and every CI job build with Xcode 27
// (implementation-plan.md "Toolchain note"). iOS platform is 27.0 -- the app
// target requires it; macOS stays 26.0 because the `xcode-27` CI image is a
// macOS 26 host and `swift test` runs there.
import PackageDescription

// SyncKit: pull -> map -> resolve conflicts -> write pipeline + scheduling.
// Depends on CoreModel, Secrets, and GoogleHealthClient.
// See architecture.md §2 (module map) and §3 (concurrency model).

let package = Package(
    name: "SyncKit",
    platforms: [.iOS("27.0"), .macOS("26.0")],
    products: [
        .library(name: "SyncKit", targets: ["SyncKit"]),
    ],
    dependencies: [
        .package(path: "../CoreModel"),
        .package(path: "../Secrets"),
        .package(path: "../GoogleHealthClient"),
    ],
    targets: [
        .target(
            name: "SyncKit",
            dependencies: ["CoreModel", "Secrets", "GoogleHealthClient"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
        .testTarget(
            name: "SyncKitTests",
            dependencies: ["SyncKit"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
    ]
)
