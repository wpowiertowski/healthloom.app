// TipStoreTests.swift
//
// Tip jar test lane. Toolchain boundary, stated up front: Apple's
// StoreKitTest framework does not compile under this SDK — importing it
// fails the module build on a deprecated ObjC symbol with ZERO project
// flags set (proven, not a strictness artifact), so an SKTestSession
// purchase lane is impossible until Apple fixes the framework. What IS
// proven here, all live and hermetic:
// - the committed Tips.storekit config contracts the tier IDs, the
//   Consumable type, and the 0.99/2.99/6.99 prices (parsed from the file
//   in the test bundle) — PLUS one raw-literal canary (round-2 item 9)
//   so an enum+fixture drift that defeats every derived assertion still
//   fails here;
// - cancel/pending result mapping (constructible without a transaction);
// - the counting gate through `tipCount` (admits once; dupes, foreign
//   IDs, and revocations never count);
// - the banner decision (foreign IDs raise nothing);
// - the cancellation arm with a cancelled task driving the LIVE-shaped
//   error (URLError, never CancellationError — round-2 item 1), and the
//   same shape without a cancel settling as a real failure;
// - the load-state machine (idle → loading → loaded/failed/idle) and
//   load coalescing under a cancelled loader (round-2 item 4);
// - tip-count persistence round-trip; initial state;
// - lifetimeTerminates + entitlementsEmpty smokes (trivially true without
//   transactions — kept for shape, grow real arms with F1);
// - noRestoreSymbols grep-test (no restore API in code — the header's
//   no-restore claim, pinned);
// - privacy grep-test over the Tips directory.
// Live purchase/pending/failed/refund paths are covered by code structure
// (every arm terminates — review `purchase()`/`handle(_:)`) plus manual QA
// with the attached config (see TipProductID docs).
//
// Dropped, deliberately (round-2 item 6): the old `liveCancelNeverCorrupts`
// probe drove the LIVE `Product.products` from the unit bundle —
// outcome-free (asserts nothing StoreKit-dependent), network-dependent,
// and unfixable at this layer: xcodegen 2.46.0 does not emit a TestAction
// `storeKitConfiguration` (proven by regen byte-check), and hand-editing
// the generated scheme would trip the project-drift gate. The seam test
// pins OUR cancellation branch deterministically — the only code we own.
//
// TODO(SKTestSession) [fast-follow F1]: when `import StoreKitTest`
// compiles again under this SDK (fixed Apple framework — re-prove with a
// zero-flags build before relying on it), restore the session lane:
// success (finish + count once), unfinished-at-launch, ask-to-buy
// pending, simulated failure, refund-noop, and the PurchaseDriver seam
// so those arms run tested==shipped instead of reviewed.

import Foundation
import StoreKit
import Testing
@testable import HealthLoom

/// Structural store fixture (round-2 item 10): owns the store AND its
/// ephemeral suite together — no tuple to destructure, no holder to
/// remember. Tests bind `let fixture` plus a uniform
/// `defer { withExtendedLifetime(fixture) {} }` (the binding's whole job
/// is lifetime: an explicit use the optimizer cannot elide) and drive
/// `fixture.store`.
@MainActor
final class TipStoreFixture {
    let store: TipStore
    private let ephemeral: EphemeralDefaults

    init(
        fetchProducts: (([String]) async throws -> [Product])? = nil,
        uiTestStubs: [TipUITestStub] = []
    ) throws {
        let ephemeral = try EphemeralDefaults(prefix: "tips")
        self.ephemeral = ephemeral
        self.store = TipStore(defaults: ephemeral.defaults, fetchProducts: fetchProducts, uiTestStubs: uiTestStubs)
    }

    /// Same-suite access for the persistence round-trip (new store, same
    /// suite — proves the count survives instance turnover).
    var defaults: UserDefaults { ephemeral.defaults }
}

@Suite("TipStore", .serialized)
@MainActor
struct TipStoreTests {
    private var configURL: URL {
        get throws {
            // `Bundle(for:)` needs a class; the marker pins the test
            // bundle. The config lives in test resources ONLY (never the
            // app bundle) — a missing file fails loudly here, which is
            // the wiring proof.
            guard let url = Bundle(for: TipTestBundleMarker.self).url(forResource: "Tips", withExtension: "storekit") else {
                throw TipTestError.missingConfig
            }
            return url
        }
    }

    @Test("committed config contracts the tiers, type, and prices")
    func configContract() throws {
        // IDs come from the type, never re-typed literals (AGENTS.md
        // §2): the parsed file must match `TipProductID.allCases`.
        let data = try Data(contentsOf: try configURL)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let products = try #require(json["products"] as? [[String: Any]])
        #expect(products.count == TipProductID.allCases.count)
        var seen: [String: String] = [:]
        for product in products {
            let id = try #require(product["productID"] as? String)
            #expect(TipProductID(rawValue: id) != nil, "config ID not in TipProductID: \(id)")
            seen[id] = try #require(product["displayPrice"] as? String)
            #expect(product["type"] as? String == "Consumable")
        }
        #expect(Set(seen.keys) == Set(TipProductID.allCases.map(\.rawValue)))
        #expect(seen == [
            TipProductID.small.rawValue: "0.99",
            TipProductID.medium.rawValue: "2.99",
            TipProductID.large.rawValue: "6.99",
        ])
        #expect(TipProductID(rawValue: TipProductID.small.rawValue)?.shortName == "small")
        #expect(TipProductID(rawValue: TipProductID.medium.rawValue)?.shortName == "medium")
        #expect(TipProductID(rawValue: TipProductID.large.rawValue)?.shortName == "large")
        // EXTERNAL CONTRACT ANCHOR (round-2 item 9): exactly one place
        // re-types the ASC product IDs as raw literals — a deliberate,
        // documented exception to AGENTS.md §2. Every assertion above
        // derives from `TipProductID`, so a renamed enum + edited fixture
        // would stay green while production IDs mismatch App Store
        // Connect; this canary fails first. Touch these literals only
        // when ASC changes.
        #expect(Set(TipProductID.allCases.map(\.rawValue)) == [
            "app.healthloom.tip.small",
            "app.healthloom.tip.medium",
            "app.healthloom.tip.large",
        ])
    }

    @Test("initial state is unpurchased and idle")
    func initialState() throws {
        let fixture = try TipStoreFixture()
        defer { withExtendedLifetime(fixture) {} }
        #expect(fixture.store.tipCount == 0)
        #expect(fixture.store.products.isEmpty)
        #expect(fixture.store.loadState == .idle)
        #expect(!fixture.store.isPurchasing)
        #expect(fixture.store.lastResult == nil)
    }

    // Smoke, not coverage: with no transactions these terminate
    // trivially — the claim is only that the lifetime wiring runs
    // without hanging or throwing. Real arms arrive with F1.
    @Test("begin and unfinished-completion terminate with nothing pending")
    func lifetimeTerminates() async throws {
        let fixture = try TipStoreFixture()
        defer { withExtendedLifetime(fixture) {} }
        await fixture.store.begin()
        await fixture.store.finishUnfinished()
        var unfinished = 0
        for await _ in Transaction.unfinished { unfinished += 1 }
        #expect(unfinished == 0)
        // Re-entrant begin is a no-op (second call returns immediately).
        await fixture.store.begin()
    }

    @Test("cancel and pending map without a transaction")
    func resultMapping() {
        #expect(TipStore.result(for: .userCancelled) == .cancelled)
        #expect(TipStore.result(for: .pending) == .pendingApproval)
    }

    @Test("counting gate admits once, rejects dupes/unknowns/revoked")
    func countingGate() throws {
        let fixture = try TipStoreFixture()
        defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        // Tested through `tipCount` (round-2 item 8), not the Bool: the
        // observable state is what ships.
        #expect(store.countTipIfNew(transactionID: 1, productID: TipProductID.small.rawValue, revocationDate: nil))
        #expect(store.tipCount == 1)
        #expect(!store.countTipIfNew(transactionID: 1, productID: TipProductID.small.rawValue, revocationDate: nil))
        #expect(!store.countTipIfNew(transactionID: 2, productID: "com.example.other", revocationDate: nil))
        #expect(!store.countTipIfNew(transactionID: 3, productID: TipProductID.large.rawValue, revocationDate: Date()))
        #expect(store.tipCount == 1)
        #expect(store.countTipIfNew(transactionID: 4, productID: TipProductID.large.rawValue, revocationDate: nil))
        #expect(store.tipCount == 2)
    }

    @Test("foreign product IDs raise no banner and count nothing")
    func foreignIDsTouchNothing() throws {
        let fixture = try TipStoreFixture()
        defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        // The banner decision is pure (round-2 item 3): known products
        // raise success, foreign IDs raise nothing — so `handle(_:)`
        // finishes a foreign transaction while touching no counting and
        // clearing no banner.
        #expect(TipStore.banner(for: TipProductID.small.rawValue) == .succeeded(productID: TipProductID.small.rawValue))
        #expect(TipStore.banner(for: "com.example.other") == nil)
        store.countTipIfNew(transactionID: 9, productID: "com.example.other", revocationDate: nil)
        #expect(store.tipCount == 0)
        #expect(store.lastResult == nil)
    }

    @Test("cancelled fetch settles nothing and wipes nothing")
    func cancelledFetchKeepsState() async throws {
        // A cancelled task driving the LIVE-shaped error (round-2 item
        // 1): a cancelled StoreKit fetch surfaces as URLError (or
        // StoreKitError.networkError) — never CancellationError — so the
        // seam converts sleep-cancellation into URLError before throwing.
        // The store must read OUR task state, not the error type.
        let fixture = try TipStoreFixture(fetchProducts: { _ in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                throw URLError(.cancelled)
            }
            return []
        })
        defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        let task = Task { await store.loadProducts() }
        let start = Date.now
        while store.loadState != .loading {
            try await Task.sleep(for: .milliseconds(20))
            if Date.now.timeIntervalSince(start) > 5 {
                Issue.record("loadProducts never entered loading")
                break
            }
        }
        task.cancel()
        await task.value
        #expect(store.loadState == .idle)
        #expect(store.products.isEmpty)
    }

    @Test("cancelled-shaped error without a cancel is a real failure")
    func uncancelledLiveShapedErrorFails() async throws {
        // Companion to the cancel test: the SAME URLError shape arriving
        // on a live task is a genuine failure (offline, not a cancel) —
        // `.failed` with products preserved, retryable from the UI.
        let fixture = try TipStoreFixture(fetchProducts: { _ in throw URLError(.notConnectedToInternet) })
        defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        await store.loadProducts()
        #expect(store.loadState == .failed)
        #expect(store.products.isEmpty)
    }

    @Test("load moves idle to loading to loaded, failure to failed")
    func loadStates() async throws {
        final class Script {
            var calls = 0
            var finishNow = false
        }
        let script = Script()
        let fixture = try TipStoreFixture(fetchProducts: { _ in
            script.calls += 1
            if script.finishNow { return [] }
            try await Task.sleep(for: .seconds(30))
            return []
        })
        defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        #expect(store.loadState == .idle)
        // Suspend, observe loading, cancel back to idle.
        let stalled = Task { await store.loadProducts() }
        let start = Date.now
        while store.loadState != .loading {
            try await Task.sleep(for: .milliseconds(20))
            if Date.now.timeIntervalSince(start) > 5 {
                Issue.record("loadProducts never entered loading")
                break
            }
        }
        #expect(store.loadState == .loading)
        stalled.cancel()
        await stalled.value
        #expect(store.loadState == .idle)
        #expect(script.calls == 1)
        // Settle loaded with an instant fetch.
        script.finishNow = true
        await store.loadProducts()
        #expect(store.loadState == .loaded)
        #expect(script.calls == 2)
        // A settled store does not refetch.
        await store.loadProducts()
        #expect(script.calls == 2)
        // Genuine failure lands in `.failed` (fresh store — a loaded one
        // would short-circuit).
        let failing = try TipStoreFixture(fetchProducts: { _ in throw URLError(.notConnectedToInternet) })
        defer { withExtendedLifetime(failing) {} }
        await failing.store.loadProducts()
        #expect(failing.store.loadState == .failed)
    }

    @Test("concurrent loads coalesce; a cancelled loader hands off")
    func loadCoalescing() async throws {
        // Round-2 item 4: the old `guard !isLoading else return` dropped
        // the second caller; a cancelled first caller then meant spinner
        // forever. Now waiters join the in-flight fetch, and whoever
        // remains refetches if the load died underneath them.
        final class Script {
            var calls = 0
        }
        let script = Script()
        let fixture = try TipStoreFixture(fetchProducts: { _ in
            script.calls += 1
            if script.calls == 1 {
                try await Task.sleep(for: .seconds(30))
            }
            return []
        })
        defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        let first = Task { await store.loadProducts() }
        let start = Date.now
        while store.loadState != .loading {
            try await Task.sleep(for: .milliseconds(20))
            if Date.now.timeIntervalSince(start) > 5 {
                Issue.record("first load never started")
                break
            }
        }
        let second = Task { await store.loadProducts() }
        await Task.yield()
        first.cancel()
        await first.value
        await second.value
        // Deterministic under every interleaving: if `second` attached as
        // a waiter it refetched after the handoff; if it started late it
        // fetched its own. Either way two fetches, one settled store.
        #expect(script.calls == 2)
        #expect(store.loadState == .loaded)
    }

    @Test("stub sequence settles retry without the network")
    func stubSequence() async throws {
        // Fix-round F1: FIFO stub values — the failed first load and the
        // retry that settles it both resolve inside the sequence, so the
        // UI retry flow is hermetic end to end.
        let fixture = try TipStoreFixture(uiTestStubs: [.failed, .emptyProducts])
        defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        await store.loadProducts()
        #expect(store.loadState == .failed)
        await store.loadProducts()
        #expect(store.loadState == .loaded)
        #expect(store.products.isEmpty)
    }

    @Test("tip count persists across instances")
    func tipCountPersists() throws {
        let fixture = try TipStoreFixture()
        defer { withExtendedLifetime(fixture) {} }
        let first = TipStore(defaults: fixture.defaults)
        first.recordTip()
        first.recordTip()
        #expect(TipStore(defaults: fixture.defaults).tipCount == 2)
    }

    // Downgraded (third-party item 11): with no purchases this is
    // trivially empty — kept only to pin the query shape (tip IDs
    // filtered out of currentEntitlements). Grows a purchase-then-assert
    // arm with F1.
    @Test("entitlements surface empty with no purchases")
    func entitlementsEmpty() async {
        var entitled: [String] = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                entitled.append(transaction.productID)
            }
        }
        #expect(entitled.filter { TipProductID(rawValue: $0) != nil }.isEmpty)
    }

    @Test("no restore symbol exists in tip sources (grep-test)")
    func noRestoreSymbols() throws {
        // The header promises no restore path: any restore API
        // (AppStore.sync, restoreCompletedTransactions, a custom
        // `restore()` on the store) fails here. Comment-stripped like
        // the privacy grep — prose may discuss restore, code may not.
        let thisFile = URL(fileURLWithPath: #filePath)
        let tipsDir = thisFile
            .deletingLastPathComponent() // HealthLoomTests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("HealthLoomApp/Tips")
        var hits: [String] = []
        for file in try FileManager.default.contentsOfDirectory(at: tipsDir, includingPropertiesForKeys: nil) {
            guard file.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            let code = source
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
                .lowercased()
            if code.contains("restor") {
                hits.append(file.lastPathComponent)
            }
        }
        #expect(hits.isEmpty, "restore symbols in tip sources: \(hits)")
    }

    @Test("no health data near purchase code (grep-test)")
    func noHealthSymbolsInTipSources() throws {
        try assertNoHealthKitSymbols(in: "HealthLoomApp/Tips")
    }
}

enum TipTestError: Error {
    case missingConfig
}

private final class TipTestBundleMarker: NSObject {}
