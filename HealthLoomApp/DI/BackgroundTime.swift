// BackgroundTime.swift
//
// WP-71: the UIKit background-task assertion, one adapter for its two
// users -- the iCloud flush when the app backgrounds, and a Sync Now run
// the user leaves mid-way (without it, the types in flight were cut off
// and waited for the next sync). Thin: iOS decides how long the time
// lasts; callers pass what to stop when it runs out.

import UIKit

/// Asks iOS to keep the app running for a while after it leaves the
/// screen. `begin` returns the function that ends the assertion (safe to
/// call more than once); `expired` runs if time runs out first, and the
/// assertion is ended right after it.
struct BackgroundTime {
    let begin: @MainActor (_ name: String, _ expired: @escaping @MainActor @Sendable () -> Void) -> @MainActor () -> Void

    static let system = BackgroundTime { name, expired in
        let token = BackgroundTaskToken()
        token.id = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated {
                expired()
                token.end()
            }
        }
        return { token.end() }
    }
}

/// Holds the assertion's identifier so both the expiration handler and
/// the completion can end it exactly once.
@MainActor
private final class BackgroundTaskToken {
    var id: UIBackgroundTaskIdentifier = .invalid

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
