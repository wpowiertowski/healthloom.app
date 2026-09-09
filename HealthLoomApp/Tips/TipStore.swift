// TipStore.swift
//
// Consumable tip jar (StoreKit 2). Three tiers; product IDs below must be
// created in App Store Connect with matching tiers once the app record
// exists (human step):
//   app.healthloom.tip.small  — Small Tip  ($0.99)
//   app.healthloom.tip.medium — Medium Tip ($2.99)
//   app.healthloom.tip.large  — Large Tip  ($6.99)
//
// Lifetime shape: `begin()` (called once at app launch) starts the
// `Transaction.updates` listener AND finishes any unfinished transactions
// left by a previous run (crash between charge and finish). Every
// purchase path terminates: success finishes + counts, cancel/pending/
// failed update status without finishing (nothing to finish), revoked
// (refunded) finishes with no state change — a consumable grants no
// entitlement, so there is nothing to take back.
//
// Ordering invariant (no double-count): finish FIRST, then count. A crash
// between charge and finish recounts exactly once on relaunch; a crash
// after finish+count recounts never.
//
// Deliberately absent, by design:
// - NO server validation: tips unlock nothing server-side (there is no
//   server). On-device `.verified` checking is the whole story.
// - NO restore path: consumables never appear in
//   `Transaction.currentEntitlements`, so there is nothing to restore.
//   Pinned by test (`tipsLeaveNoEntitlements`).

import Foundation
import Observation
import StoreKit

/// Product IDs for the three tip tiers. The human creates these exact IDs
/// in App Store Connect; `Tips.storekit` mirrors them for dev/sandbox.
///
/// Dev/sandbox attachment (manual — Xcode has no CLI for this): Product →
/// Scheme → Edit Scheme → Run → StoreKit Configuration → Tips.storekit.
/// The committed file is also the test bundle's contract source (see
/// TipStoreTests' config-contract test).
enum TipProductID: String, CaseIterable, Sendable {
    case small = "app.healthloom.tip.small"
    case medium = "app.healthloom.tip.medium"
    case large = "app.healthloom.tip.large"

    /// Short tier name for accessibility identifiers
    /// (`settings.tips.small` rather than the full product ID).
    var shortName: String {
        switch self {
        case .small: "small"
        case .medium: "medium"
        case .large: "large"
        }
    }
}

/// Outcome of one purchase attempt (UI state, not persistence).
enum TipResult: Equatable, Sendable {
    case succeeded(productID: String)
    case cancelled
    case pendingApproval
    case failed(message: String)
}

@MainActor
@Observable
final class TipStore {
    private static let tipCountKey = "com.healthloom.tips.count"

    private let defaults: UserDefaults
    private var listener: Task<Void, Never>?

    var products: [Product] = []
    var productsUnavailable = false
    var isPurchasing = false
    var lastResult: TipResult?
    private(set) var tipCount: Int

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.tipCount = defaults.integer(forKey: Self.tipCountKey)
    }

    /// App-lifetime wiring: transaction listener + unfinished completion.
    /// Safe to call once at launch; re-entrancy is a no-op.
    func begin() async {
        guard listener == nil else { return }
        listener = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
        await finishUnfinished()
    }

    func loadProducts() async {
        do {
            products = try await Product.products(for: TipProductID.allCases.map(\.rawValue))
            productsUnavailable = products.isEmpty
        } catch {
            products = []
            productsUnavailable = true
        }
    }

    /// Purchases `product`, terminating every path (see file header).
    func purchase(_ product: Product) async {
        guard !isPurchasing else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    recordTip()
                    lastResult = .succeeded(productID: product.id)
                case .unverified:
                    lastResult = .failed(message: "Purchase could not be verified.")
                }
            case .userCancelled, .pending:
                // Routed through the pure mapper (third-party F2): the
                // arms the unit tests pin are the arms that ship.
                lastResult = Self.result(for: result)
            @unknown default:
                lastResult = Self.result(for: result)
            }
        } catch {
            lastResult = .failed(message: "Purchase failed: \(error.localizedDescription)")
        }
    }

    /// Pure mapping of the non-transaction arms, pinned directly
    /// (a cancelled/pending `Product.PurchaseResult` is constructible
    /// without a transaction; `.success` arms go through the live
    /// SKTestSession lane instead).
    nonisolated static func result(
        for purchaseResult: Product.PurchaseResult
    ) -> TipResult {
        switch purchaseResult {
        case .success:
            // Transaction-bearing: handled inline in `purchase()` (finish
            // + count ordering matters there). Unreachable here in tests.
            .failed(message: "Unexpected success without transaction handling.")
        case .userCancelled:
            .cancelled
        case .pending:
            .pendingApproval
        @unknown default:
            .failed(message: "Purchase returned an unknown result.")
        }
    }

    // MARK: - Private

    /// Late-arriving updates (renewals don't exist for consumables;
    /// refunds do): finish so nothing lingers, change no state.
    /// Unverified updates are deliberately left unfinished (third-party
    /// N2): finishing would acknowledge a possibly-tampered transaction
    /// and destroy the evidence; leaving it re-presents a value this
    /// handler ignores — no state change, no UI, no grant, forever.
    private func handle(_ update: VerificationResult<Transaction>) async {
        switch update {
        case .verified(let transaction):
            await transaction.finish()
        case .unverified:
            break
        }
    }

    /// Charges that completed without a finish (crash between charge and
    /// `finish()`): finish + count exactly once (see ordering invariant).
    func finishUnfinished() async {
        for await result in Transaction.unfinished {
            switch result {
            case .verified(let transaction):
                await transaction.finish()
                // Count only tip products — unfinished transactions from
                // any other (future) product must not inflate the tally.
                if TipProductID(rawValue: transaction.productID) != nil {
                    recordTip()
                }
            case .unverified:
                break // same N2 posture as `handle(_:)`: never acknowledge.
            }
        }
    }

    /// Records one completed tip. Internal (not private) so tests pin
    /// persistence without a purchase; production calls it only after
    /// `finish()` (see ordering invariant). Grows the PurchaseDriver seam
    /// (fast-follow F1) instead if that lands.
    func recordTip() {
        tipCount += 1
        defaults.set(tipCount, forKey: Self.tipCountKey)
    }
}
