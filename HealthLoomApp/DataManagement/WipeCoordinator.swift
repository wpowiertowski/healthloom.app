// WipeCoordinator.swift
//
// WP-35 (implementation-plan.md): Settings → "Disconnect & wipe".
// Ordered steps, every step attempted even after a failure (a wipe that
// stops at the first error strands half-deleted state with no report —
// privacy prefers best-effort-complete plus an honest per-step ledger).
//
// Order is load-bearing: revoke FIRST (it needs the token), keychain
// second (kills the token and every provider key — WP-29's per-provider
// removal already exists in AI Models for single keys; this is the
// all-keys counterpart), HealthKit third (needs no secrets), store files
// fourth (the open container is invalid afterwards — the UI gates on
// completion and asks for relaunch), UserDefaults last (kills the
// onboarding flag, so relaunch starts clean).
//
// `@Observable` drives the progress UI; every I/O boundary is an
// injected closure (AGENTS.md §2), so the full wipe runs in tests against
// scripted doubles — including the real Keychain, which can't run in the
// unsigned test process (WP-03 note), via `InMemoryCloudKeyStore`.

import CoreModel
import Foundation
import GoogleHealthClient
import HealthKit
import Secrets

@MainActor
@Observable
final class WipeCoordinator {
    enum Step: String, CaseIterable, Identifiable {
        case revokeGoogle
        case keychain
        case healthKit
        case store
        case defaults

        var id: String { rawValue }

        var title: String {
            switch self {
            case .revokeGoogle: return "Revoking Google access"
            case .keychain: return "Deleting saved keys"
            case .healthKit: return "Deleting HealthKit samples"
            case .store: return "Deleting app data"
            case .defaults: return "Resetting settings"
            }
        }
    }

    enum StepState: Equatable {
        case pending
        case running
        case done(detail: String)
        case failed(String)
    }

    struct Dependencies {
        /// Google token revocation. Throws on transport/endpoint failure;
        /// `.nothingStored` is success (never consented / already wiped).
        var revokeGoogle: () async throws -> RevocationOutcome
        /// Deletes every SecretKey (idempotent-when-absent per contract).
        var deleteAllKeys: () async throws -> Void
        /// App-written HealthKit deletion (live or stubbed deleter).
        /// Skipped entirely when the user opts out.
        var deleteHealthKit: () async -> [HKObjectType: Result<Int, Error>]
        /// Removes the store files. Returns removed URLs for the ledger.
        var deleteStore: () throws -> [URL]
        /// Resets persisted preferences.
        var resetDefaults: () -> Void
    }

    private(set) var states: [Step: StepState] = Dictionary(
        uniqueKeysWithValues: Step.allCases.map { ($0, .pending) }
    )
    private(set) var isRunning = false
    private(set) var isFinished = false

    var failedSteps: [Step] {
        Step.allCases.filter {
            if case .failed = states[$0] { return true }
            return false
        }
    }

    private let deps: Dependencies
    private let includeHealthKit: Bool

    init(deps: Dependencies, includeHealthKit: Bool = true) {
        self.deps = deps
        self.includeHealthKit = includeHealthKit
    }

    /// Runs every step, recording each outcome. Never throws — failure is
    /// data (per-step rows), not control flow.
    func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer {
            isRunning = false
            isFinished = true
        }

        // 1. Revoke first: the only step that needs a live secret.
        await perform(.revokeGoogle) {
            let outcome = try await self.deps.revokeGoogle()
            return outcome == .revoked ? "access revoked" : "nothing stored"
        }

        // 2. Keychain: Google tokens + every provider key (WP-29 rows
        // cover single-key removal; this clears all of them).
        await perform(.keychain) {
            try await self.deps.deleteAllKeys()
            return "all keys deleted"
        }

        // 3. HealthKit (optional): app-written samples only.
        if includeHealthKit {
            await perform(.healthKit) {
                let outcomes = await self.deps.deleteHealthKit()
                let deleted = outcomes.values.compactMap { try? $0.get() }.reduce(0, +)
                let failures = outcomes.count - outcomes.values.filter { (try? $0.get()) != nil }.count
                if failures > 0 {
                    throw WipeError.healthKitPartial(deleted: deleted, failedTypes: failures)
                }
                return "\(deleted) sample(s) deleted"
            }
        } else {
            states[.healthKit] = .done(detail: "skipped by user")
        }

        // 4. Store files (container invalid afterwards by design).
        await perform(.store) {
            let removed = try self.deps.deleteStore()
            return "\(removed.count) file(s) removed"
        }

        // 5. Defaults last (kills onboarding + toggles for the relaunch).
        await perform(.defaults) {
            self.deps.resetDefaults()
            return "settings reset"
        }
    }

    private func perform(_ step: Step, work: () async throws -> String) async {
        states[step] = .running
        do {
            states[step] = .done(detail: try await work())
        } catch {
            states[step] = .failed(String(describing: error))
        }
    }
}

/// Wipe-local errors. Log-safe by construction (counts only, never
/// payloads or tokens).
enum WipeError: Error, Equatable {
    case healthKitPartial(deleted: Int, failedTypes: Int)
}
