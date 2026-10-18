// swift-tools-version: 6.4
// Tools version 6.4 (WP-83): local dev and every CI job build with Xcode 27
// (implementation-plan.md "Toolchain note"). iOS platform is 27.0 -- the app
// target requires it; macOS stays 26.0 because the `xcode-27` CI image is a
// macOS 26 host and `swift test` runs there.
import PackageDescription

// Secrets: Keychain wrapper. No dependencies on other HealthLoom packages.
// See architecture.md §2 (module map) and §3 (concurrency model).

let package = Package(
    name: "Secrets",
    platforms: [.iOS("27.0"), .macOS("26.0")],
    products: [
        .library(name: "Secrets", targets: ["Secrets"]),
    ],
    targets: [
        .target(
            name: "Secrets",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
        .testTarget(
            name: "SecretsTests",
            dependencies: ["Secrets"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
    ]
)
