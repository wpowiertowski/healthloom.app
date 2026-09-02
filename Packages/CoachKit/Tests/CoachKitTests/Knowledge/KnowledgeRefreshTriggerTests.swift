// KnowledgeRefreshTriggerTests.swift
//
// WP-19 step 3: "throttled to at most hourly" -- pins the pure throttle
// function only (see KnowledgeRefreshTrigger.swift's header for why the
// `HistoryObserver`-wired half has no test seam).

@testable import CoachKit
import Foundation
import Testing

@Suite("KnowledgeRefreshThrottle.shouldFire")
struct KnowledgeRefreshTriggerTests {
    @Test("never fired before ⇒ fires")
    func neverFired() {
        #expect(KnowledgeRefreshThrottle.shouldFire(lastFiredAt: nil, now: .now, minimumInterval: 3600))
    }

    @Test("fired 30 minutes ago ⇒ does not fire again")
    func tooSoon() {
        let last = Date(timeIntervalSince1970: 0)
        let now = last.addingTimeInterval(1800)
        #expect(!KnowledgeRefreshThrottle.shouldFire(lastFiredAt: last, now: now, minimumInterval: 3600))
    }

    @Test("fired exactly one interval ago ⇒ fires")
    func exactlyAtBoundary() {
        let last = Date(timeIntervalSince1970: 0)
        let now = last.addingTimeInterval(3600)
        #expect(KnowledgeRefreshThrottle.shouldFire(lastFiredAt: last, now: now, minimumInterval: 3600))
    }

    @Test("fired over an hour ago ⇒ fires")
    func longAgo() {
        let last = Date(timeIntervalSince1970: 0)
        let now = last.addingTimeInterval(7200)
        #expect(KnowledgeRefreshThrottle.shouldFire(lastFiredAt: last, now: now, minimumInterval: 3600))
    }
}
