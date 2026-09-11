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
import SyncKit

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
        /// Quiesces every writer trigger for the wipe duration AND after
        /// (round-10 item 1: one-way latch — background/foreground work
        /// must not resurrect cleared records or write through the
        /// unlinked store handle). Runs FIRST, before revoke. Defaulted
        /// no-op so scripted test doubles that don't probe ordering keep
        /// compiling. (No property-level default: this struct carries an
        /// explicit init — see below — and a default in both places is a
        /// double-initialization error. The default lives on the init
        /// parameter.)
        let quiesceWriters: () -> Void
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

        /// Explicit init (round-10 item 1 toolchain note): this
        /// toolchain's memberwise initializer EXCLUDES defaulted
        /// properties (probe-proven), so the defaulted `quiesceWriters`
        /// needs a hand-written init to stay both defaulted and
        /// passable.
        init(
            quiesceWriters: @escaping () -> Void = {},
            revokeGoogle: @escaping () async throws -> RevocationOutcome,
            deleteAllKeys: @escaping () async throws -> Void,
            deleteHealthKit: @escaping () async throws -> [HKObjectType: Result<Int, Error>],
            deleteCloudKit: @escaping () async throws -> Int,
            deleteStore: @escaping () throws -> [URL],
            resetDefaults: @escaping () -> Void
        ) {
            self.quiesceWriters = quiesceWriters
            self.revokeGoogle = revokeGoogle
            self.deleteAllKeys = deleteAllKeys
            self.deleteHealthKit = deleteHealthKit
            self.deleteCloudKit = deleteCloudKit
            self.deleteStore = deleteStore
            self.resetDefaults = resetDefaults
        }
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

        // 0. Quiesce first of all (round-10 item 1): from here until
        // relaunch, no trigger may write — racing writers would
        // resurrect records mid-wipe and write through the unlinked
        // store handle after it.
        deps.quiesceWriters()

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
        // "Cleared", not "deleted" (fix-round N2): the count is
        // attempted names, each ending absent (deleted or already
        // missing) — the function cannot tell which.
        await perform(.cloudKit) {
            let cleared = try await self.deps.deleteCloudKit()
            return "\(cleared) iCloud record(s) cleared"
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
            // Round-10 item 6: redacted (D11) — a raw
            // `String(describing:)` can carry bearer tokens or
            // authenticated URLs into the step ledger (same surface
            // SyncEngine redacts at its catch).
            states[step] = .failed(SyncLogRedactor.redact(String(describing: error)))
        }
    }
}

/// Wipe-local errors. Log-safe by construction (counts and type display
/// names only, never payloads or tokens). The partial case renders
/// directly into the step row — human retry guidance, never enum-debug.
/// One-way wipe latch (round-10 item 1): set when a wipe STARTS, never
/// cleared except by relaunch. Every writer trigger (foreground syncNow,
/// insight runner, backfill loop, BG handler) checks it and no-ops —
/// otherwise background+foreground work recreates iCloud records,
/// defaults markers, and store rows WITHOUT relaunch, or writes through
/// the SQLite handle on the unlinked store file. Lock-guarded statics
/// (the `EphemeralDefaultsJanitor` precedent): readable from any
/// isolation, including the nonisolated BG launch handler that cannot
/// capture `AppEnvironment`. Production closures read it; tests inject
/// scripted closures and never touch the static (plus `resetForTesting`
/// for the latch's own unit test).

enum WipeQuiesce {
    // `nonisolated` throughout (the `BackgroundSync` precedent): this
    // latch is read from nonisolated contexts (notably the BG launch
    // handler), and this target defaults to MainActor isolation.
    nonisolated private static let lock = NSLock()
    // `nonisolated(unsafe)` + lock discipline (the janitor precedent):
    // the compiler can't see the locking, so the unsafety is stated
    // and the discipline is reviewed, not inferred.
    nonisolated(unsafe) private static var latched = false

    nonisolated static func latch() {
        lock.withLock { latched = true }
    }

    nonisolated static var isLatched: Bool {
        lock.withLock { latched }
    }

    /// Test-only reset (the latch's own unit test; production never
    /// clears — only relaunch does).
    nonisolated static func resetForTesting() {
        lock.withLock { latched = false }
    }
}

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
