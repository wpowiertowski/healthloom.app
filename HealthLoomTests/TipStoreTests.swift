// TipStoreTests.swift
//
// Tip jar test lane. Toolchain boundary, stated up front: Apple's
// StoreKitTest framework does not compile under this SDK — importing it
// fails the module build on a deprecated ObjC symbol with ZERO project
// flags set (proven, not a strictness artifact), so an SKTestSession
// purchase lane is impossible until Apple fixes the framework. What IS
// proven here, all live and hermetic:
// - product IDs + short names are exactly the contracted tiers;
// - the committed Tips.storekit config contracts those same IDs, the
//   Consumable type, and the 0.99/2.99/6.99 prices (parsed from the file
//   in the test bundle — ID/price drift fails here);
// - cancel/pending result mapping (constructible without a transaction);
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

@Suite("TipStore", .serialized)
@MainActor
struct TipStoreTests {
    // The holder must stay bound for the whole test (deinit removes
    // the domain) — call sites keep `ephemeral` alive to the last line.
    private func freshStore() throws -> (TipStore, EphemeralDefaults) {
        let ephemeral = try EphemeralDefaults(prefix: "tips")
        return (TipStore(defaults: ephemeral.defaults), ephemeral)
    }

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
    }

    @Test("initial state is unpurchased and idle")
    func initialState() throws {
        let (store, ephemeral) = try freshStore()
        defer { _ = ephemeral }
        #expect(store.tipCount == 0)
        #expect(store.products.isEmpty)
        #expect(!store.isPurchasing)
        #expect(store.lastResult == nil)
    }

    // Smoke, not coverage: with no transactions these terminate
    // trivially — the claim is only that the lifetime wiring runs
    // without hanging or throwing. Real arms arrive with F1.
    @Test("begin and unfinished-completion terminate with nothing pending")
    func lifetimeTerminates() async throws {
        let (store, ephemeral) = try freshStore()
        defer { _ = ephemeral }
        await store.begin()
        await store.finishUnfinished()
        var unfinished = 0
        for await _ in Transaction.unfinished { unfinished += 1 }
        #expect(unfinished == 0)
        // Re-entrant begin is a no-op (second call returns immediately).
        await store.begin()
    }

    @Test("cancel and pending map without a transaction")
    func resultMapping() {
        #expect(TipStore.result(for: .userCancelled) == .cancelled)
        #expect(TipStore.result(for: .pending) == .pendingApproval)
    }

    @Test("counting gate admits once, rejects dupes/unknowns/revoked")
    func countingGate() throws {
        let (store, ephemeral) = try freshStore()
        defer { _ = ephemeral }
        #expect(store.shouldCountTip(transactionID: 1, productID: TipProductID.small.rawValue, revocationDate: nil))
        #expect(!store.shouldCountTip(transactionID: 1, productID: TipProductID.small.rawValue, revocationDate: nil))
        #expect(!store.shouldCountTip(transactionID: 2, productID: "com.example.other", revocationDate: nil))
        #expect(!store.shouldCountTip(transactionID: 3, productID: TipProductID.large.rawValue, revocationDate: Date()))
        #expect(store.shouldCountTip(transactionID: 4, productID: TipProductID.large.rawValue, revocationDate: nil))
    }

    @Test("cancelled fetch settles nothing and wipes nothing")
    func cancelledFetchKeepsState() async throws {
        let (store, ephemeral) = try freshStore()
        defer { _ = ephemeral }
        // The live fetch ignores cancellation (proven: cancel-then-run
        // still settles), so the test drives a suspender through the
        // fetch seam. Cancel mid-flight: no settle flags, no wipe. The
        // old code set productsUnavailable=true on this path.
        store.fetchProducts = { _ in
            try await Task.sleep(for: .seconds(30))
            return []
        }
        let task = Task { await store.loadProducts() }
        while !store.isLoading {
            await Task.yield()
        }
        task.cancel()
        await task.value
        #expect(!store.isLoading)
        #expect(!store.hasAttemptedLoad)
        #expect(store.products.isEmpty)
    }

    @Test("load moves idle to loading to settled")
    func loadStates() async throws {
        let (store, ephemeral) = try freshStore()
        defer { _ = ephemeral }
        #expect(!store.isLoading && !store.hasAttemptedLoad) // idle
        // Deterministic via the seam (no network timing): suspend, observe
        // loading, cancel back to idle, then settle with an empty fetch.
        store.fetchProducts = { _ in
            try await Task.sleep(for: .seconds(30))
            return []
        }
        let stalled = Task { await store.loadProducts() }
        let start = Date.now // loading: poll, don't assume scheduling
        while !store.isLoading {
            try await Task.sleep(for: .milliseconds(20))
            if Date.now.timeIntervalSince(start) > 5 {
                Issue.record("loadProducts never entered loading")
                break
            }
        }
        #expect(store.isLoading)
        stalled.cancel()
        await stalled.value
        #expect(!store.isLoading && !store.hasAttemptedLoad)
        store.fetchProducts = { _ in [] }
        await store.loadProducts()
        #expect(!store.isLoading && store.hasAttemptedLoad) // settled
    }

    @Test("tip count persists across instances")
    func tipCountPersists() throws {
        let ephemeral = try EphemeralDefaults(prefix: "tips-persist")
        defer { _ = ephemeral }
        let defaults = ephemeral.defaults
        let first = TipStore(defaults: defaults)
        first.recordTip()
        first.recordTip()
        #expect(TipStore(defaults: defaults).tipCount == 2)
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
