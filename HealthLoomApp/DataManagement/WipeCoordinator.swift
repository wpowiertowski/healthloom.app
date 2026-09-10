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
// all-keys counterpart), HealthKit third (needs no secrets), iCloud
// fourth (server records before local watermarks — round-6 item 1),
// store files fifth (the open container is invalid afterwards — the UI
// gates on completion and asks for relaunch), UserDefaults last (kills
// the onboarding flag, so relaunch starts clean).
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
        case cloudKit
        case store
        case defaults

        var id: String { rawValue }

        var title: String {
            switch self {
            case .revokeGoogle: return "Revoking Google access"
            case .keychain: return "Deleting saved keys"
            case .healthKit: return "Deleting HealthKit samples"
            case .cloudKit: return "Deleting iCloud data"
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
        let revokeGoogle: () async throws -> RevocationOutcome
        /// Deletes every SecretKey (idempotent-when-absent per contract).
        let deleteAllKeys: () async throws -> Void
        /// App-written HealthKit deletion (live or stubbed deleter).
        /// Skipped entirely when the user opts out. Throws when the wipe
        /// set itself can't be derived (unknown mapping) — failing the
        /// step loudly instead of wiping an unknown subset.
        let deleteHealthKit: () async throws -> [HKObjectType: Result<Int, Error>]
        /// iCloud private-DB deletion (round-6 item 1): server records
        /// go BEFORE local watermarks reset (the engine orders it) so a
        /// relaunch cannot repull wiped data. Returns the deleted-record
        /// count for the ledger.
        let deleteCloudKit: () async throws -> Int
        /// Removes the store files. Returns removed URLs for the ledger.
        let deleteStore: () throws -> [URL]
        /// Resets persisted preferences.
        let resetDefaults: () -> Void
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
                let outcomes = try await self.deps.deleteHealthKit()
                let deleted = outcomes.values.compactMap { try? $0.get() }.reduce(0, +)
                let failedNames = outcomes.compactMap { type, result -> String? in
                    guard (try? result.get()) == nil else { return nil }
                    return HealthKitSourceDeleter.displayName(for: type)
                }
                if !failedNames.isEmpty {
                    throw WipeError.healthKitPartial(deleted: deleted, failedTypeNames: failedNames)
                }
                return "\(deleted) sample(s) deleted"
            }
        } else {
            states[.healthKit] = .done(detail: "skipped by user")
        }

        // 4. iCloud (round-6 item 1): server records, then watermarks
        // (the engine's `deleteAllCloudData` orders it) — without this
        // the wiped transcript/settings pull straight back on relaunch,
        // breaking the alert's "cannot be undone" promise.
        await perform(.cloudKit) {
            let deleted = try await self.deps.deleteCloudKit()
            return "\(deleted) iCloud record(s) deleted"
        }

        // 5. Store files (container invalid afterwards by design).
        await perform(.store) {
            let removed = try self.deps.deleteStore()
            return "\(removed.count) file(s) removed"
        }

        // 6. Defaults last (kills onboarding + toggles for the relaunch).
        await perform(.defaults) {
            self.deps.resetDefaults()
            return "settings reset"
        }
    }

    private func perform(_ step: Step, work: () async throws -> String) async {
        states[step] = .running
        do {
            states[step] = .done(detail: try await work())
        } catch let wipeError as WipeError {
            // Human retry guidance, never enum-debug (F5).
            states[step] = .failed(wipeError.stepDetail)
        } catch {
            states[step] = .failed(String(describing: error))
        }
    }
}

/// Wipe-local errors. Log-safe by construction (counts and type display
/// names only, never payloads or tokens). The partial case renders
/// directly into the step row — human retry guidance, never enum-debug.
enum WipeError: Error, Equatable {
    case healthKitPartial(deleted: Int, failedTypeNames: [String])

    var stepDetail: String {
        switch self {
        case .healthKitPartial(let deleted, let names):
            let listed = names.prefix(3).joined(separator: ", ")
            let more = names.count > 3 ? " and \(names.count - 3) more" : ""
            return "Deleted \(deleted) sample(s); couldn't verify \(listed)\(more) — re-enable HealthKit access and run again."
        }
    }
}
