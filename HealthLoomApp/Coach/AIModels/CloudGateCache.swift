// CloudGateCache.swift
//
// WP-29 (implementation-plan.md): the sync/`Sendable` bridge between the
// app's `MainActor`-isolated tier state and `ModelCatalog`'s gating
// closures (`hasConsent`/`hasKey` are `@Sendable (ModelTier) -> Bool` --
// they cannot hop to `MainActor`, and neither `TierSettingsStore` nor
// `KeychainStore` is synchronously readable).
//
// The cache holds plain bools behind a lock; `AppEnvironment` owns one
// instance, wires its readers into the catalog, and fills it at launch
// (WP-29 F8: an earlier header named this `refreshCloudGates()` — no such
// symbol ever existed; consent is seeded inline in `init` and Keychain
// presence via `AppEnvironment.fillKeyPresence`, with `AIModelsViewModel`
// keeping its own observable key-presence mirror per mutation).
// `AIModelsViewModel` updates the cache after every consent/key mutation,
// so the catalog gate and the rows it renders can never disagree within
// the settings screen. Staleness invariant: the ONLY writers of the
// underlying state are this screen's flows (plus the launch fill), so a
// refresh after each mutation is complete -- no polling, no observation.
//
// Deliberately NOT `@Observable`: the settings screen observes its view
// model (which mirrors key presence and re-reads after every mutation)
// and the shared `TierSettingsStore` mirrors; the chat slot reads the
// gate through `CoachChatViewModel.enabledTierNames` (its own view model,
// not the settings one).

import CoachKit
import Foundation

/// Lock-guarded consent/key presence snapshot for the catalog gate.
final class CloudGateCache: Sendable {
    // Every member `nonisolated`: this type's whole job is synchronous
    // reads from `ModelCatalog`'s `@Sendable` closures, and the project
    // default (`SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`) would otherwise
    // isolate it. The lock makes the manual isolation sound.
    private nonisolated let lock = NSLock()
    private nonisolated(unsafe) var consent: [ModelTier: Bool] = [:]
    private nonisolated(unsafe) var keyPresent: [ModelTier: Bool] = [:]

    nonisolated func hasConsent(_ tier: ModelTier) -> Bool {
        lock.withLock { consent[tier] ?? false }
    }

    nonisolated func hasKey(_ tier: ModelTier) -> Bool {
        lock.withLock { keyPresent[tier] ?? false }
    }

    nonisolated func setConsent(_ consented: Bool, for tier: ModelTier) {
        lock.withLock { consent[tier] = consented }
    }

    nonisolated func setKeyPresent(_ present: Bool, for tier: ModelTier) {
        lock.withLock { keyPresent[tier] = present }
    }
}
