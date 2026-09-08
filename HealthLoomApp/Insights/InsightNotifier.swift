// InsightNotifier.swift
//
// WP-34: the UserNotifications seam. One protocol, two implementations —
// live (`UNUserNotificationCenter`) and stub (UI tests + previews).
// Thin adapter by design (AGENTS.md §2: seams at I/O boundaries only):
// content redaction lives in `InsightNotificationContent`, scheduling
// policy in `MorningInsightRunner`; this file only talks to the system.
//
// Authorization is surfaced as this module's own four-case enum (not
// `UNAuthorizationStatus`) so the runner's `switch` is exhaustive over
// exactly the states it handles, with a deliberate `@unknown`-style
// fallback mapping inside `LiveInsightNotifier` (fail-closed toward
// guidance, never toward assuming access).

import Foundation
import UserNotifications

/// Authorization posture for morning insights.
enum InsightAuthStatus: Equatable {
    case authorized
    case denied
    case notDetermined
    /// Restricted provisional/ephemeral states: treat like authorized for
    /// delivery (the system will show them), the runner re-checks anyway.
    case provisional
}

protocol InsightNotifying: Sendable {
    func authorizationStatus() async -> InsightAuthStatus
    /// Requests access. Call only from a user action (the insights toggle),
    /// never at launch or from the background runner.
    func requestAuthorization() async -> Bool
    func schedule(title: String, body: String) async throws
}

/// Production: `UNUserNotificationCenter.current()`.
struct LiveInsightNotifier: InsightNotifying {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationStatus() async -> InsightAuthStatus {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        case .provisional, .ephemeral: return .provisional
        @unknown default: return .denied
        }
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func schedule(title: String, body: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: "com.healthloom.insight.morning",
            content: content,
            // Immediate delivery: generation just finished, the insight is
            // now. Replacing any pending twin keeps one notification max.
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        try await center.add(request)
    }
}

/// UI-test double (`-UITestStubNotifications`): scripted status, records
/// requests and scheduled content for assertions.
final class StubInsightNotifier: InsightNotifying, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: InsightAuthStatus
    private var _requestCount = 0
    private var _scheduled: [(title: String, body: String)] = []

    init(status: InsightAuthStatus = .notDetermined) {
        self._status = status
    }

    var requestCount: Int { lock.withLock { _requestCount } }
    var scheduled: [(title: String, body: String)] { lock.withLock { _scheduled } }

    func authorizationStatus() async -> InsightAuthStatus {
        lock.withLock { _status }
    }

    func requestAuthorization() async -> Bool {
        lock.withLock {
            _requestCount += 1
            // Mirrors the system: only `.notDetermined` prompts (and
            // grants, in this stub); any other status answers immediately
            // without changing anything.
            guard _status == .notDetermined else {
                return _status == .authorized
            }
            _status = .authorized
            return true
        }
    }

    func schedule(title: String, body: String) async throws {
        lock.withLock { _scheduled.append((title, body)) }
    }
}
