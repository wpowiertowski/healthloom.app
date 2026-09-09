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
// Ordering invariant (no double-count): finish FIRST, then count through
// `shouldCountTip` (ID gate shared by listener, sweep, and purchase
// path). A crash between charge and finish recounts exactly once on
// relaunch; a crash after finish+count recounts never.
//
// Deliberately absent, by design:
// - NO server validation: tips unlock nothing server-side (there is no
//   server). On-device `.verified` checking is the whole story.
// - NO restore path: consumables never appear in
//   `Transaction.currentEntitlements`, so there is nothing to restore.
//   Pinned by `entitlementsEmpty` + `noRestoreSymbols`.
//
// Manual QA (StoreKit config attached — see TipProductID):
// - success / cancel / Ask-to-Buy approve / failure / refund per tier;
// - Ask-to-Buy DECLINE: no transaction exists, so nothing resolves —
//   `pendingApproval` sticks until the next attempt overwrites it (or
//   relaunch clears it; the state is in-memory only). Verified benign:
//   no charge, no count, self-heals. Confirm the sticky pending clears
//   on the next attempt.

import Foundation
import Observation
import StoreKit

/// Product IDs for the three tip tiers. The human creates these exact IDs
/// in App Store Connect; `HealthLoomTests/Fixtures/Tips.storekit`
/// mirrors them for dev/sandbox (wired into the scheme's run action via
/// project.yml — no manual attach step; the file deliberately lives
/// outside HealthLoomApp/ so it never ships in the app bundle).
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

    // Single source of load truth (third-party 3+13): `products` holds
    // content, `isLoading`/`hasAttemptedLoad` hold fetch posture — no
    // parallel `productsUnavailable` bool. UI: spinner while
    // `!hasAttemptedLoad || isLoading`, coming-soon when settled-empty.
    private(set) var products: [Product] = []
    private(set) var isLoading = false
    private(set) var hasAttemptedLoad = false
    private(set) var isPurchasing = false
    private(set) var lastResult: TipResult?
    private(set) var tipCount: Int
    /// Transaction IDs already counted this run (item 1 gate — see
    /// `shouldCountTip`). In-memory is enough: finished transactions
    /// never re-present, so no run can see another run's counts.
    private var countedTransactionIDs = Set<UInt64>()

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

    /// Fetch seam for the cancellation test ONLY (third-party item 2
    /// demands a cancelled-task test, which needs a suspension the test
    /// controls — `Product.products` ignores cancellation). Live value is
    /// the real fetch. This is NOT the purchase-path seam (fast-follow
    /// F1): purchases stay seam-free.
    var fetchProducts: ([String]) async throws -> [Product] = { ids in
        try await Product.products(for: ids)
    }

    func loadProducts() async {
        // Settings `.task` cancels on dismissal: a cancelled fetch must
        // NEVER wipe loaded products (third-party item 2) — only a real
        // failure resets to empty.
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            products = try await fetchProducts(TipProductID.allCases.map(\.rawValue))
            hasAttemptedLoad = true
        } catch is CancellationError {
            return // keep existing state (defer still clears isLoading)
        } catch {
            products = []
            hasAttemptedLoad = true
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
                    // Gated (item 1): the lifetime listener may have seen
                    // this transaction first — count exactly once.
                    if shouldCountTip(
                        transactionID: transaction.id,
                        productID: transaction.productID,
                        revocationDate: transaction.revocationDate
                    ) {
                        recordTip()
                    }
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

    /// Counting gate shared by the listener, the launch sweep, and the
    /// purchase path (third-party item 1): a tip transaction counts
    /// exactly once per run. All three paths run on the MainActor (this
    /// class is `@MainActor`), so check-and-insert is atomic:
    /// - the listener counts a completion as it arrives;
    /// - the sweep only ever sees transactions the listener did NOT
    ///   finish (finished ones never re-present);
    /// - the overlap (a transaction completing mid-sweep) resolves by
    ///   the gate: whoever inserts the ID first counts, the other skips.
    /// No double-count AND no loss. Revoked (refunded) transactions never
    /// count: the user was un-charged, and there is no entitlement to
    /// remove — finishing is the whole handling.
    func shouldCountTip(transactionID: UInt64, productID: String, revocationDate: Date?) -> Bool {
        guard revocationDate == nil,
              TipProductID(rawValue: productID) != nil,
              !countedTransactionIDs.contains(transactionID)
        else {
            return false
        }
        countedTransactionIDs.insert(transactionID)
        return true
    }

    /// Late-arriving updates (renewals don't exist for consumables;
    /// refunds do): finish so nothing lingers. Verified tips count
    /// through the gate (Ask-to-Buy approvals and re-deliveries land
    /// here, not in `purchase()`); verified refunds clear sticky UI;
    /// unverified stays unfinished (N2 posture: never acknowledge).
    /// Setting `lastResult` here clears the sticky pending state (item 8).
    private func handle(_ update: VerificationResult<Transaction>) async {
        switch update {
        case .verified(let transaction):
            await transaction.finish()
            if transaction.revocationDate != nil {
                lastResult = nil
            } else {
                if shouldCountTip(
                    transactionID: transaction.id,
                    productID: transaction.productID,
                    revocationDate: transaction.revocationDate
                ) {
                    recordTip()
                }
                lastResult = .succeeded(productID: transaction.productID)
            }
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
                if shouldCountTip(
                    transactionID: transaction.id,
                    productID: transaction.productID,
                    revocationDate: transaction.revocationDate
                ) {
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
