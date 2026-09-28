// MockGoogleReconcileClient.swift
//
// WP-09 (implementation-plan.md) test support: a `GoogleReconcileClient`
// (SyncEngineTypes.swift) test double, playing the same role
// `MockHealthStore` (HealthKitWriter/MockHealthStore.swift) plays for
// `HealthKitWriter` -- no real networking, entirely scripted.
//
// Scripted **per (type, pageToken)** rather than as one flat per-type
// sequence: `SyncEngine` always starts a run's pagination at `pageToken: nil`
// and follows `nextPageToken` from there, so keying by the exact page token
// requested lets a test script "the very first page of a window" and "the
// page after it" independently, and -- critically for the "failure
// mid-pagination, retried next run" test -- lets a retried run's first page
// request (`pageToken: nil` again, since the cursor never advanced) return a
// *different* (successful) result than the failed run's did, without the
// mock needing to know anything about run boundaries itself. Each key's
// result list is consumed in order and the last entry repeats once
// exhausted, so a test that only cares about "always returns this one page"
// can supply a single-element list.
//
// Window-aware (WP-52): a scripted page returns only its points whose start
// falls inside the requested `since ..< until`, the way the real API's
// filter does. The engine walks a window one day at a time, so a canned page
// returned verbatim for every span would replay the same points once per
// day -- semantics the real server never has.
//
// Not an `actor`: this test target shares SyncKit's package-wide
// `.defaultIsolation(MainActor.self)` (Package.swift), same as
// `MockHealthStore`'s `@unchecked Sendable` class -- mirrored here for
// consistency, with an explicit `NSLock` (unlike `MockHealthStore`) because
// this mock's whole purpose in the concurrency tests is to be legitimately
// reachable while multiple `SyncEngine.sync(type:)` calls are genuinely
// in-flight at once.

import CoreModel
import Foundation
import GoogleHealthClient
@testable import SyncKit

final class MockGoogleReconcileClient: GoogleReconcileClient, @unchecked Sendable {
    struct RecordedCall: Sendable, Equatable {
        var type: GoogleDataType
        var since: Date
        var until: Date
        var pageToken: String?
    }

    private struct Key: Hashable {
        var type: GoogleDataType
        var pageToken: String?
    }

    private let lock = NSLock()
    private nonisolated(unsafe) var scripts: [Key: [Result<Page, GoogleHealthClientError>]] = [:]
    private nonisolated(unsafe) var callCounts: [Key: Int] = [:]
    private nonisolated(unsafe) var _calls: [RecordedCall] = []

    /// Optional rendezvous point: when set, every `reconcile` call suspends
    /// here (after being recorded, before returning its scripted result) --
    /// lets a test hold the *one* real network call open while it fires off
    /// additional concurrent `SyncEngine.sync(type:)` calls and proves they
    /// coalesce onto the same in-flight run rather than issuing their own.
    nonisolated(unsafe) var gate: AsyncGate?

    /// Runs on every `reconcile` call, after it's recorded -- lets a test
    /// change the world mid-run (e.g. latch a wipe during the first span).
    nonisolated(unsafe) var onReconcile: (@Sendable () -> Void)?

    /// How far before `since` a point may start and still be returned --
    /// a `.date` filter truncates `since` to its civil day, so the real API
    /// returns the day a span starts in to that span AND the one before it
    /// (WP-58). Zero (the default) is the strict start-in-window filter.
    nonisolated(unsafe) var leadingOverlap: TimeInterval = 0

    init() {}

    var calls: [RecordedCall] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    func callCount(type: GoogleDataType, pageToken: String?) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return callCounts[Key(type: type, pageToken: pageToken), default: 0]
    }

    /// Script the result(s) `reconcile` returns for `type` when called with
    /// exactly `pageToken`. Multiple results are consumed in call order (1st
    /// call to this exact key gets `results[0]`, 2nd gets `results[1]`, ...);
    /// once exhausted, the last result repeats forever.
    func setScript(type: GoogleDataType, pageToken: String?, results: [Result<Page, GoogleHealthClientError>]) {
        lock.lock()
        scripts[Key(type: type, pageToken: pageToken)] = results
        lock.unlock()
    }

    /// Convenience for the common "this exact page request always returns
    /// this one page" case.
    func setPage(type: GoogleDataType, pageToken: String?, page: Page) {
        setScript(type: type, pageToken: pageToken, results: [.success(page)])
    }

    nonisolated func reconcile(
        type: GoogleDataType,
        since: Date,
        until: Date,
        pageToken: String?
    ) async throws(GoogleHealthClientError) -> Page {
        // `NSLock.lock()`/`.unlock()` are unavailable from `async` contexts on
        // this toolchain (push toward async-safe scoped locking) -- `withLock`
        // is a synchronous closure, so it's used here purely to protect the
        // shared mutable state, entirely before the `await gate.enter()` below.
        let result: Result<Page, GoogleHealthClientError> = lock.withLock {
            _calls.append(RecordedCall(type: type, since: since, until: until, pageToken: pageToken))
            let key = Key(type: type, pageToken: pageToken)
            let count = callCounts[key, default: 0]
            callCounts[key] = count + 1
            let results = scripts[key] ?? [.success(Page(points: [], nextPageToken: nil))]
            return results[Swift.min(count, results.count - 1)]
        }

        onReconcile?()
        if let gate {
            await gate.enter()
        }

        switch result {
        case .success(let page):
            let from = since.addingTimeInterval(-leadingOverlap)
            let inWindow = page.points.filter { $0.start >= from && $0.start < until }
            return Page(points: inWindow, nextPageToken: page.nextPageToken)
        case .failure(let error):
            throw error
        }
    }
}

/// Minimal rendezvous primitive so a test can deterministically prove
/// `SyncEngine.sync(type:)` calls issued *while* another is genuinely
/// in-flight coalesce onto it, rather than relying on timing/`Task.sleep`
/// races. `enter()` (called by `MockGoogleReconcileClient.reconcile`) marks
/// itself "entered" -- releasing anyone awaiting `waitUntilEntered()` -- and
/// then suspends until `open()` is called; a test calls `waitUntilEntered()`
/// to know the one real network call has genuinely started (and is
/// currently held open) before spawning additional concurrent `sync(type:)`
/// callers, then calls `open()` once they've all been issued.
actor AsyncGate {
    private var isOpen = false
    private var hasEntered = false
    private var openContinuations: [CheckedContinuation<Void, Never>] = []
    private var enteredContinuations: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        hasEntered = true
        for continuation in enteredContinuations { continuation.resume() }
        enteredContinuations = []

        if isOpen { return }
        await withCheckedContinuation { continuation in
            openContinuations.append(continuation)
        }
    }

    func waitUntilEntered() async {
        if hasEntered { return }
        await withCheckedContinuation { continuation in
            enteredContinuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        for continuation in openContinuations { continuation.resume() }
        openContinuations = []
    }
}
