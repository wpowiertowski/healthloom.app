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
// - begin()/finishUnfinished() terminate with no transactions pending;
// - no entitlements surface and no restore symbol exists (consumables
//   never restore — the header's claim, pinned);
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
    private func freshStore() throws -> TipStore {
        let defaults = try #require(UserDefaults(suiteName: "tips-\(UUID().uuidString)"))
        return TipStore(defaults: defaults)
    }

    private var configURL: URL {
        get throws {
            // `Bundle(for:)` needs a class; the marker pins the test
            // bundle. Falls back to the host app bundle: xcodegen routes
            // the shared Tips.storekit into the app target's resources
            // (it lives under HealthLoomApp/), and app-hosted tests run
            // with Bundle.main == HealthLoom.app. Either way the content
            // asserted is the single committed file.
            let bundles = [Bundle(for: TipTestBundleMarker.self), Bundle.main]
            for bundle in bundles {
                if let url = bundle.url(forResource: "Tips", withExtension: "storekit") {
                    return url
                }
            }
            throw TipTestError.missingConfig
        }
    }

    @Test("product IDs are exactly the contracted tiers")
    func productIDs() {
        #expect(TipProductID.small.rawValue == "app.healthloom.tip.small")
        #expect(TipProductID.medium.rawValue == "app.healthloom.tip.medium")
        #expect(TipProductID.large.rawValue == "app.healthloom.tip.large")
        #expect(TipProductID(rawValue: "app.healthloom.tip.small")?.shortName == "small")
        #expect(TipProductID(rawValue: "app.healthloom.tip.medium")?.shortName == "medium")
        #expect(TipProductID(rawValue: "app.healthloom.tip.large")?.shortName == "large")
    }

    @Test("committed config contracts the tiers, type, and prices")
    func configContract() throws {
        let data = try Data(contentsOf: try configURL)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let products = try #require(json["products"] as? [[String: Any]])
        #expect(products.count == 3)
        var seen: [String: String] = [:]
        for product in products {
            let id = try #require(product["productID"] as? String)
            seen[id] = try #require(product["displayPrice"] as? String)
            #expect(product["type"] as? String == "Consumable")
        }
        #expect(seen == [
            "app.healthloom.tip.small": "0.99",
            "app.healthloom.tip.medium": "2.99",
            "app.healthloom.tip.large": "6.99",
        ])
    }

    @Test("initial state is unpurchased and idle")
    func initialState() throws {
        let store = try freshStore()
        #expect(store.tipCount == 0)
        #expect(store.products.isEmpty)
        #expect(!store.isPurchasing)
        #expect(store.lastResult == nil)
    }

    @Test("begin and unfinished-completion terminate with nothing pending")
    func lifetimeSmoke() async throws {
        let store = try freshStore()
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

    @Test("tip count persists across instances")
    func tipCountPersists() throws {
        let defaults = try #require(UserDefaults(suiteName: "tips-persist-\(UUID().uuidString)"))
        let first = TipStore(defaults: defaults)
        first.recordTip()
        first.recordTip()
        #expect(TipStore(defaults: defaults).tipCount == 2)
    }

    @Test("no entitlements surface for tips (nothing restores)")
    func noTipEntitlements() async {
        // With no purchases, trivially empty — the point is the shape:
        // consumables never enter currentEntitlements, so no restore
        // path can exist. Grows a purchase-then-assert arm with F1.
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
        let thisFile = URL(fileURLWithPath: #filePath)
        let tipsDir = thisFile
            .deletingLastPathComponent() // HealthLoomTests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("HealthLoomApp/Tips")
        let banned = [
            "HealthKit", "HKQuantity", "HKSample", "HKObject", "HKHealthStore",
            "HKWorkout", "LocalSample", "GoogleDataPoint", "HKUnit", "HKStatistics",
        ]
        var hits: [String] = []
        for file in try FileManager.default.contentsOfDirectory(at: tipsDir, includingPropertiesForKeys: nil) {
            guard file.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            let code = source
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for symbol in banned where code.contains(symbol) {
                hits.append("\(file.lastPathComponent): \(symbol)")
            }
        }
        #expect(hits.isEmpty, "HealthKit symbols in tip sources: \(hits)")
    }
}

enum TipTestError: Error {
    case missingConfig
}

private final class TipTestBundleMarker: NSObject {}
