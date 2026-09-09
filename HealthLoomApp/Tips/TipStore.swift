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
enum TipUITestStub: Sendable, Equatable {
    case emptyProducts
    case failed
}

/// Tip-section slot decision (round-4 item 3): pure, so the
/// refresh-keeps-tiers rule is pinned without rendering. TIERS whenever
/// a catalogue exists — INCLUDING `.loading` (a refresh-from-settled
/// must not blank working tiers into a spinner) and `.idle` (a
/// populated store never un-populates); the spinner is for the
/// genuinely-empty loading path only; `.failed`-with-tiers rides the
/// error + retry UNDER the tiers (the View keys that block on
/// `loadState == .failed` separately).
enum TipSectionSlot: Equatable, Sendable {
    case tiers
    case spinner
    case comingSoon
    case errorAlone
}

/// One-shot settlement for the fetch/timeout race (round-4 item 2):
/// whichever arm finishes first wins; the loser finds `settled == true`
/// and drops its result. An actor because the two racer tasks are
/// unstructured (the race exists precisely because the flight is
/// unstructured) — the flag needs real isolation, not MainActor
/// inheritance. The failure arm carries no error: every load error —
/// fetch throw or timeout — settles `.failed`, so the error's identity
/// is unneeded past this point.
enum LoadRaceOutcome: Sendable {
    case fetched([Product])
    case fetchFailed
    case timedOut
}

private actor LoadSettler {
    private var settled = false
    private let continuation: CheckedContinuation<[Product], Error>

    init(_ continuation: CheckedContinuation<[Product], Error>) {
        self.continuation = continuation
    }

    func settle(_ outcome: LoadRaceOutcome) {
        guard !settled else { return }
        settled = true
        switch outcome {
        case .fetched(let products):
            continuation.resume(returning: products)
        case .fetchFailed:
            continuation.resume(throwing: LoadSettleError.fetchFailed)
        case .timedOut:
            continuation.resume(throwing: LoadSettleError.timedOut)
        }
    }
}

private enum LoadSettleError: Error {
    case fetchFailed
    case timedOut
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
    /// production. STICKY (round-3 item 1): a session constructed WITH
    /// stubs never falls through to the live fetch — once the queue
    /// drains, the last value replays. Without stickiness a stubbed
    /// Retry (or a second `.task` fire) would hit `Product.products`.
    private var uiTestStubs: [TipUITestStub]
    // Round-4 item 9: no `stubbedSession` bool — `lastStub != nil` IS
    // the stubbed-session predicate (a stub is set only from the queue,
    // and the queue is non-empty only for stubbed sessions). The
    // bool-pair shape round-2 item 12 killed stays dead.
    private var lastStub: TipUITestStub?
    /// Wedge bound (round-4 item 2): a catalogue fetch that outlives
    /// this settles `.failed` instead of wedging the section forever.
    /// 30 seconds bounds a hung StoreKit request without false-
    /// positiving slow networks (a false positive heals via Retry —
    /// `.failed` is always recoverable, `.loading`-forever is not).
    private let loadTimeout: Duration

    init(
        defaults: UserDefaults = .standard,
        fetchProducts: (([String]) async throws -> [Product])? = nil,
        uiTestStubs: [TipUITestStub] = [],
        loadTimeout: Duration = .seconds(30)
    ) {
        self.defaults = defaults
        self.fetchProducts = fetchProducts ?? { ids in try await Product.products(for: ids) }
        self.uiTestStubs = uiTestStubs
        self.loadTimeout = loadTimeout
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

    /// In-flight flight handle (round-3 item 7 + fix-round N1): the TRUE
    /// invariants, stated exactly —
    /// - SINGLE-LAUNCHER: only the `inFlight == nil` branch creates a
    ///   flight, and the check-and-set is suspension-free on the
    ///   MainActor, so at most one flight exists. Ever.
    /// - CLEARED-BY-FLIGHT (round-4 item 7): the slot is nilled INSIDE
    ///   the flight's tail, BEFORE publishing, with no suspension
    ///   between — and waiters wake only after the whole tail. A caller
    ///   can therefore never observe a finished-but-uncleared slot:
    ///   pre-completion arrivals join and adopt; post-completion
    ///   arrivals see nil and launch fresh. The swallowed-Retry window
    ///   (join a settled flight, return without fetching) is closed by
    ///   construction, not by timing.
    /// - UNSTRUCTURED-BUT-OUTCOME-EQUIVALENT: `Task {}` propagates no
    ///   cancellation, which is precisely why settlement always arrives
    ///   (empirically proven: `cancelledLoaderStillSettles` pins a
    ///   cancelled loader still settling, and the probe pins
    ///   awaiting another task's value as non-unwinding) — and no
    ///   caller consumes a return value, so shared settlement is
    ///   behaviorally identical to blocking.
    /// Concurrent callers join (`await inFlight?.value`) instead of
    /// duplicating the fetch or spinning on the MainActor (the 50Hz
    /// `waitForSettle` poll is deleted). A cancelled joiner lingers
    /// until settlement, then adopts it like everyone else: no spinner
    /// strands, ever.
    private var inFlight: Task<Void, Never>?

    /// - SELF-SETTLING (round-4 item 2): the flight body always
    ///   terminates — stubs settle instantly, the live fetch races a
    ///   timeout — so the slot ALWAYS clears. No hung fetch wedges the
    ///   section: at most one orphaned task leaks per wedge, and it
    ///   can publish nothing (see `fetchWithTimeout`).
    /// Coalescing loader (round-3 items 7+8+14, reshaped by round-4
    /// items 2+7+10): straight line, no loops. A second call made
    /// mid-flight joins the flight and adopts its outcome (no caller
    /// consumes a return value, so joining by shared settlement is
    /// behaviorally identical to blocking). A caller cancelled BEFORE
    /// starting issues nothing (guard); a caller cancelled MID-flight
    /// lingers harmlessly and adopts the settlement like everyone else.
    /// The launcher only joins — clearing moved into the flight (item
    /// 7), so there is no launcher continuation to strand.
    func loadProducts() async {
        if let running = inFlight {
            await running.value
            return
        }
        // Round-3 item 8: a cancelled caller never issues a fetch and
        // never flips shared state.
        guard !Task.isCancelled else { return }
        // Round-4 item 10: THE owner of the idle→loading transition —
        // single, synchronous, before the flight is parked. Any caller
        // observing a non-nil `inFlight` has already passed this line
        // (program order, same actor), so `loadCoalescing`'s
        // determinism argument rests HERE, not in the flight body.
        loadState = .loading
        inFlight = Task { await self.runLoad() }
        await inFlight?.value
    }

    private func runLoad() async {
        // UI-test stub queue (round-2 item 7 + fix-round F1 + round-3
        // item 1 sticky): apply the head, else replay the last value —
        // never touching the network. Stubs settle instantly, so the
        // timeout below does not apply (hermetic by construction).
        if !uiTestStubs.isEmpty {
            lastStub = uiTestStubs.removeFirst()
        }
        if let stub = lastStub {
            inFlight = nil
            switch stub {
            case .emptyProducts:
                products = []
                loadState = .loaded
            case .failed:
                loadState = .failed
            }
            return
        }
        let fetched: [Product]?
        do {
            fetched = try await fetchWithTimeout(TipProductID.allCases.map(\.rawValue))
        } catch {
            fetched = nil
        }
        // Round-4 item 7: clear FIRST, then publish, suspension-free
        // (see the slot invariant above). Round-3 items 7+8 SUPERSEDE
        // the round-2 cancel→idle arm (deleted): the flight is
        // unstructured, so caller cancellation never reaches it — there
        // is no cancel state left to read, and a cancelled live fetch
        // surfaces as URLError / StoreKitError.networkError / timeout,
        // indistinguishable from offline. EVERY error therefore settles
        // `.failed` with previously loaded products preserved
        // (assignment happens only on success — structural, see item
        // 6); Retry heals all. Cancel-before-start (guard above) is the
        // only path that preserves `.idle`.
        inFlight = nil
        if let fetched {
            products = fetched
            loadState = .loaded
        } else {
            loadState = .failed
        }
    }

    /// Live fetch with a wedge bound (round-4 item 2). The chosen
    /// primitive is a COOPERATIVE TIMEOUT + abandon, justified against
    /// the alternatives: CANCELLATION-THAT-ACTUALLY-CANCELS is
    /// impossible — StoreKit's request is non-cooperative (cancelling
    /// the awaiting task does not unwind it; proven by probe), so no
    /// primitive exists that aborts a hung `Product.products`.
    /// STALE-FLIGHT-DISCARD-ON-NEW-LOAD is subsumed: the race below
    /// IS the discard — the timeout arm wins, the fetch arm's late
    /// result is dropped at the settlement point, and no generation
    /// counter is needed (a stale publisher cannot exist: the flight
    /// always settles itself, and the orphaned fetch publishes
    /// nothing). First finisher resumes the continuation via the
    /// one-shot settler; the loser is cancelled best-effort and drops
    /// its result. Cost per wedge: one leaked task, bounded by the
    /// request's own lifetime; the STORE heals in ≤ `loadTimeout`.
    private func fetchWithTimeout(_ ids: [String]) async throws -> [Product] {
        try await withCheckedThrowingContinuation { continuation in
            let settler = LoadSettler(continuation)
            Task { @MainActor in
                do {
                    await settler.settle(.fetched(try await self.fetchProducts(ids)))
                } catch {
                    await settler.settle(.fetchFailed)
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: self.loadTimeout)
                await settler.settle(.timedOut)
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
                    // Round-4 item 5: routed through the ONE decision
                    // point (see `applyVerifiedTransaction`) — a
                    // verified-but-revoked transaction here must behave
                    // exactly as `handle(_:)` treats it (no success
                    // banner), not set one unconditionally.
                    applyVerifiedTransaction(
                        transactionID: transaction.id,
                        productID: transaction.productID,
                        revocationDate: transaction.revocationDate
                    )
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

    /// Shared verified-transaction interpreter (round-4 item 5): the
    /// ONE decision point for every path that finishes-then-reacts —
    /// `purchase()` and `handle(_:)` both call it (AGENTS.md §2: one
    /// decision point, not two parallel arms). Internal so tests drive
    /// the full decision — including the revoked-via-purchase row,
    /// which needs no live transaction at this layer — through
    /// `tipCount`/`lastResult`.
    func applyVerifiedTransaction(transactionID: UInt64, productID: String, revocationDate: Date?) {
        switch Self.actionForVerified(productID: productID, revocationDate: revocationDate) {
        case .ignore:
            break // foreign: finished by the caller, state untouched.
        case .clearBanner:
            lastResult = nil
        case .countAndSucceed:
            // Round-4 item 11: the arm PROVED revocationDate nil (that
            // is what `countAndSucceed` means), so the gate gets a
            // literal nil — not a forwarded maybe. And the banner
            // constructs directly: the arm proved the product known, so
            // the `banner(for:)` optionality scaffolding is gone here.
            // (Gated: the lifetime listener may have seen this
            // transaction first — count exactly once.)
            countTipIfNew(transactionID: transactionID, productID: productID, revocationDate: nil)
            lastResult = .succeeded(productID: productID)
        }
    }

    /// Slot decision for the tip section (round-4 item 3 — the pure
    /// half of the rule; the View renders the slot, then the
    /// `.failed` error + retry block underneath when tiers persist).
    nonisolated static func slot(productCount: Int, loadState: TipLoadState) -> TipSectionSlot {
        if productCount > 0 { return .tiers }
        switch loadState {
        case .loaded: return .comingSoon
        case .failed: return .errorAlone
        case .idle, .loading: return .spinner
        }
    }

    /// Banner decision for a verified, non-revoked transaction
    /// (round-2 item 3): known products raise success; FOREIGN IDs raise
    /// nothing. Pure so tests pin it without a live transaction.
    /// Production arms construct `.succeeded` directly (each arm proves
    /// the product known before reaching for it — see item 11); this
    /// stays as the pinned invariant mapper.
    nonisolated static func banner(for productID: String) -> TipResult? {
        guard TipProductID(rawValue: productID) != nil else { return nil }
        return .succeeded(productID: productID)
    }

    /// Resolved handling for one VERIFIED transaction (round-3 item 2):
    /// the FULL decision table — including the revocation arm — as pure
    /// data, so tests drive `handle(_:)`'s logic without a live
    /// transaction (a `VerificationResult<Transaction>` is
    /// unconstructible pre-SKTestSession). `handle(_:)` itself is a thin
    /// interpreter: finish, then apply the action.
    enum VerifiedTipAction: Equatable, Sendable {
        case countAndSucceed // own, non-revoked: count via gate + banner
        case clearBanner // own, revoked: sticky UI clears, nothing counts
        case ignore // foreign (any revocation state): finished, untouched
    }

    nonisolated static func actionForVerified(productID: String, revocationDate: Date?) -> VerifiedTipAction {
        // Foreign FIRST (round-3 item 2): a foreign REVOKED transaction
        // must not clear our banner — the old code gated only the
        // non-revoked arm, contradicting `banner(for:)`'s invariant.
        guard TipProductID(rawValue: productID) != nil else { return .ignore }
        return revocationDate != nil ? .clearBanner : .countAndSucceed
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
            // Round-4 item 5: the same interpreter `purchase()` uses —
            // one decision point.
            applyVerifiedTransaction(
                transactionID: transaction.id,
                productID: transaction.productID,
                revocationDate: transaction.revocationDate
            )
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
