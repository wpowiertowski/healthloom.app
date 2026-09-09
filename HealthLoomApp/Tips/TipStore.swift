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
// `countTipIfNew` (ID gate shared by listener, sweep, and purchase
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

/// Catalogue load posture (third-party round-2 item 12): one enum, not
/// an `isLoading`/`hasAttemptedLoad` bool pair — the pair's cross
/// product admitted unreachable states, and an offline failure read as
/// "coming soon" with no way back. `.failed` keeps previously loaded
/// products and offers a retry; `.idle` is the cancellable nothing-yet.
/// UI maps: idle/loading → spinner, loaded → tiers or coming-soon,
/// failed → error + retry.
enum TipLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed
}

/// UI-test catalogue stub (round-2 item 7): launch-arg-driven, consumed
/// FIFO — `-UITestTipsStub=failed,empty` fails the first load and settles
/// the retry, so multi-arm UI flows stay hermetic end to end (fix-round
/// F1: Retry must never touch the live fetch). Covers the settled UI
/// states that need no StoreKit session — coming-soon and failed+retry.
/// Tier buttons need real `Product` instances, which only a StoreKit
/// session can mint (see the F1 TODO in TipStoreTests); they stay
/// manual-QA until then.
enum TipUITestStub: Sendable {
    case emptyProducts
    case failed
}

@MainActor
@Observable
final class TipStore {
    private static let tipCountKey = "com.healthloom.tips.count"

    private let defaults: UserDefaults
    private var listener: Task<Void, Never>?

    // Single source of load truth: `products` holds content, `loadState`
    // holds fetch posture (round-2 item 12 enum — the bool pair is gone).
    private(set) var products: [Product] = []
    private(set) var loadState: TipLoadState = .idle
    private(set) var isPurchasing = false
    private(set) var lastResult: TipResult?
    private(set) var tipCount: Int
    /// Transaction IDs already counted this run (see `countTipIfNew`).
    /// In-memory is enough: finished transactions never re-present, so
    /// no run can see another run's counts.
    private var countedTransactionIDs = Set<UInt64>()

    /// Fetch seam (round-2 item 11: `let`, injected — the only seam; the
    /// purchase path stays seam-free pending F1). The live value is the
    /// real catalogue fetch. Tests inject suspenders/failures to pin the
    /// cancellation and offline arms deterministically.
    let fetchProducts: ([String]) async throws -> [Product]
    /// UI-test stub queue (round-2 item 7 + fix-round F1); empty in
    /// production.
    private var uiTestStubs: [TipUITestStub]

    init(
        defaults: UserDefaults = .standard,
        fetchProducts: (([String]) async throws -> [Product])? = nil,
        uiTestStubs: [TipUITestStub] = []
    ) {
        self.defaults = defaults
        self.fetchProducts = fetchProducts ?? { ids in try await Product.products(for: ids) }
        self.uiTestStubs = uiTestStubs
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

    /// Coalescing loader (round-2 item 4): concurrent callers JOIN the
    /// in-flight fetch instead of being dropped by an `isLoading` guard
    /// (the old shape stranded waiters: cancelled loader + dropped
    /// waiter = spinner forever). A caller cancelled while waiting
    /// unwinds without touching state; whoever remains refetches if the
    /// load died underneath them.
    func loadProducts() async {
        while loadState == .loading {
            await waitForSettle()
            // Cancelled while waiting: unwind (never start a fetch for
            // a dead caller); the remaining callers own the outcome.
            guard !Task.isCancelled else { return }
        }
        guard loadState != .loaded else { return }
        await performLoad()
    }

    /// Cancellable settle-wait: the loader owns the outcome; waiters
    /// only stop waiting when the state moves — or when THEY are
    /// cancelled, in which case they unwind silently.
    private func waitForSettle() async {
        while loadState == .loading {
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return
            }
        }
    }

    private func performLoad() async {
        // UI-test stub queue (round-2 item 7 + fix-round F1): apply the
        // head, consume it, return — never touching the network. Retry
        // consumes the NEXT value, so stubbed UI flows settle entirely
        // inside the stub sequence.
        if !uiTestStubs.isEmpty {
            switch uiTestStubs.removeFirst() {
            case .emptyProducts:
                products = []
                loadState = .loaded
            case .failed:
                loadState = .failed
            }
            return
        }
        loadState = .loading
        do {
            products = try await fetchProducts(TipProductID.allCases.map(\.rawValue))
            loadState = .loaded
        } catch {
            // Round-2 item 1: `Product.products` never throws
            // CancellationError — a cancelled live fetch surfaces
            // StoreKitError.networkError or URLError(.cancelled). The
            // error TYPE therefore cannot identify a cancel; only our
            // own task state can.
            if Task.isCancelled {
                loadState = .idle // pretend it never happened; retryable
            } else {
                // Genuine failure: previously loaded products stay (an
                // offline retry still shows tiers); the `.failed` arm
                // offers the retry affordance.
                loadState = .failed
            }
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
                    // Gated: the lifetime listener may have seen this
                    // transaction first — count exactly once. The product
                    // comes from our own catalogue, so its ID is known.
                    countTipIfNew(
                        transactionID: transaction.id,
                        productID: transaction.productID,
                        revocationDate: transaction.revocationDate
                    )
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

    /// Claims one counted tip for a verified, non-revoked tip
    /// transaction (round-2 item 8: a COMMAND name — the old `should…`
    /// name mutated under a query). Shared by the listener, the launch
    /// sweep, and the purchase path: a tip counts exactly once per run.
    /// All three paths run on the MainActor (this class is `@MainActor`),
    /// so check-and-insert is atomic: the listener counts a completion
    /// as it arrives; the sweep only ever sees transactions the listener
    /// did NOT finish (finished ones never re-present); the overlap (a
    /// transaction completing mid-sweep) resolves by the gate — whoever
    /// inserts the ID first counts, the other skips. No double-count AND
    /// no loss. Revoked (refunded) transactions never count: the user was
    /// un-charged, and there is no entitlement to remove — finishing is
    /// the whole handling.
    ///
    /// Internal (not private) so tests drive it through `tipCount`
    /// without a live transaction (pre-F1); production calls it only
    /// after `finish()` (see ordering invariant).
    @discardableResult
    func countTipIfNew(transactionID: UInt64, productID: String, revocationDate: Date?) -> Bool {
        guard revocationDate == nil,
              TipProductID(rawValue: productID) != nil,
              !countedTransactionIDs.contains(transactionID)
        else {
            return false
        }
        countedTransactionIDs.insert(transactionID)
        recordTip()
        return true
    }

    /// Banner decision for a verified, non-revoked transaction
    /// (round-2 item 3): known products raise success; FOREIGN IDs raise
    /// nothing (a foreign verified transaction still finishes — nothing
    /// lingers — but touches no counting and clears no banner). Pure so
    /// tests pin it without a live transaction.
    nonisolated static func banner(for productID: String) -> TipResult? {
        guard TipProductID(rawValue: productID) != nil else { return nil }
        return .succeeded(productID: productID)
    }

    /// Late-arriving updates (renewals don't exist for consumables;
    /// refunds do): finish so nothing lingers. Verified tips count
    /// through the gate (Ask-to-Buy approvals and re-deliveries land
    /// here, not in `purchase()`); verified refunds clear sticky UI;
    /// unverified stays unfinished (N2 posture: never acknowledge).
    /// Setting `lastResult` here clears the sticky pending state
    /// (round-1 item 8 — the sticky-`lastResult` fix; NOT round-2 item 8,
    /// which renamed the counting gate).
    private func handle(_ update: VerificationResult<Transaction>) async {
        switch update {
        case .verified(let transaction):
            await transaction.finish()
            if transaction.revocationDate != nil {
                lastResult = nil
            } else if let banner = Self.banner(for: transaction.productID) {
                // Known product only (round-2 item 3): foreign IDs fall
                // through with state untouched (finished above).
                countTipIfNew(
                    transactionID: transaction.id,
                    productID: transaction.productID,
                    revocationDate: transaction.revocationDate
                )
                lastResult = banner
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
                countTipIfNew(
                    transactionID: transaction.id,
                    productID: transaction.productID,
                    revocationDate: transaction.revocationDate
                )
            case .unverified:
                break // same N2 posture as `handle(_:)`: never acknowledge.
            }
        }
    }

    /// Records one completed tip. Internal (not private) so tests pin
    /// persistence without a purchase; production reaches it ONLY
    /// through `countTipIfNew` (which runs after `finish()` — see
    /// ordering invariant), never directly. Grows the PurchaseDriver
    /// seam (fast-follow F1) instead if that lands.
    func recordTip() {
        tipCount += 1
        defaults.set(tipCount, forKey: Self.tipCountKey)
    }
}
