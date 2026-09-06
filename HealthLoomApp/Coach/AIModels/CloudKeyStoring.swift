// CloudKeyStoring.swift
//
// WP-29 (implementation-plan.md): the seam between `AIModelsViewModel` and
// the Keychain. `Secrets.KeychainStore`'s own test seam (`KeychainBackend`)
// is intentionally internal to that package, so the app defines its own
// protocol here: production conforms the real actor via an empty extension,
// unit tests inject the in-memory fake below, and the AI Models UI-test
// scenario wires the same in-memory fake (WP-29 F8: an earlier header
// claimed the UI-test launch used the real Keychain with provider keys
// scrubbed at launch — it never did; `AppEnvironment` wires
// `InMemoryCloudKeyStore()` under `-UITestAIModels` and only tier
// preferences are scrubbed via `TierSettingsStore.resetAll`, see
// `LaunchConfiguration.aiModelsScenario`).

import Foundation
import Secrets

/// Async Keychain surface the AI-models screen needs. Matches
/// `KeychainStore`'s signatures exactly so the conformance is empty.
protocol CloudKeyStoring: Sendable {
    func get(_ key: SecretKey) async throws -> String?
    func set(_ value: String, for key: SecretKey) async throws
    func delete(_ key: SecretKey) async throws
}

extension KeychainStore: CloudKeyStoring {}

/// In-memory fake for `AIModelsViewModelTests`: no Keychain, no entitlements,
/// fully deterministic key presence per test.
final class InMemoryCloudKeyStore: CloudKeyStoring, Sendable {
    private let lock = NSLock()
    private var values: [SecretKey: String] = [:]

    init(values: [SecretKey: String] = [:]) {
        self.values = values
    }

    func get(_ key: SecretKey) async throws -> String? {
        lock.withLock { values[key] }
    }

    func set(_ value: String, for key: SecretKey) async throws {
        lock.withLock { values[key] = value }
    }

    func delete(_ key: SecretKey) async throws {
        lock.withLock { values[key] = nil }
    }
}
