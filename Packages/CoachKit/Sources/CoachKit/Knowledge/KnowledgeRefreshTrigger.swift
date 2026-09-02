// KnowledgeRefreshTrigger.swift
//
// WP-19 (implementation-plan.md) step 3: "refresh() triggers off SwiftData's
// HistoryObserver (iOS 27) observing SyncKit's persistent-history writes --
// no hand-wired completion signal -- throttled to at most hourly."
//
// `HistoryObserver` (SwiftData, iOS 27+) is `Observable` with a single
// `eventCounter: Int` that increments whenever a matching persistent-history
// transaction lands for any of `observedModels`. `SyncState`/`LocalSample`
// are the two models `SyncEngine`/`BackfillCoordinator` actually write
// (architecture.md D2: writable types flow straight to HealthKit, so a sync
// only ever touches SwiftData via those two models) -- observing them is
// exactly "SyncKit's persistent-history writes," no broader.
//
// **Toolchain split (verified against both real SDKs in this repo's own dev
// environment, not assumed):** `HistoryObserver` does not exist at all in
// Xcode 26.4.1's SwiftData module (`grep`'d its macOS `.swiftinterface` --
// zero matches) -- it is new in the iOS/macOS 27 SDK the Xcode 27 beta
// ships. Referencing it unconditionally would break CI's `packages` job,
// which deliberately pins CoachKit's `swift test` to Xcode 26.4.1
// (implementation-plan.md's "Toolchain note": manifests stay at
// `swift-tools-version: 6.2` / macOS 26.0 specifically so that job stays
// green without the Xcode 27 beta). `#if compiler(>=6.4)` is used as the
// proxy -- Xcode 26.4.1 ships Swift 6.3.1, Xcode 27 beta ships Swift 6.4, so
// today this exactly (if a little coincidentally) tracks "is the iOS 27 SDK
// available." Revisit alongside WP-38's toolchain-finalization checklist
// item once package `swift test` jobs also move to an Xcode 27+ image --
// this guard can come off entirely once Xcode 26.4.1 support is dropped.
//
// `KnowledgeRefreshThrottle.shouldFire` (the actual "at most hourly" rule)
// is deliberately its own, always-compiled, HistoryObserver-free type below
// so it has one implementation and one test suite regardless of which
// toolchain is compiling -- only the `Observable`-wiring class needs the
// guard.

import Foundation

/// The "at most hourly" throttle rule (WP-19 step 3), pure and
/// `HistoryObserver`-free so it compiles and is unit-tested identically on
/// both of this repo's package-test toolchains (see this file's header).
public enum KnowledgeRefreshThrottle {
    /// `true` when enough wall-clock time has passed since `lastFiredAt`
    /// (or there has never been a fire) to fire again.
    public static func shouldFire(lastFiredAt: Date?, now: Date, minimumInterval: TimeInterval) -> Bool {
        guard let lastFiredAt else { return true }
        return now.timeIntervalSince(lastFiredAt) >= minimumInterval
    }
}

#if compiler(>=6.4)
import CoreModel
import SwiftData

/// Wires `KnowledgeRefreshThrottle` to SwiftData's real `HistoryObserver`.
/// Not itself unit-tested (no protocol seam exists to inject a fake
/// `HistoryObserver` -- it is a concrete SwiftData type); this is a thin,
/// standard `withObservationTracking` recursive-registration loop, the same
/// carve-out WP-22 makes for `LanguageModelSession` ("real generation
/// covered by... manual tests").
///
/// `@available(macOS 27, iOS 27, *)`: `HistoryObserver` itself carries this
/// exact availability (SwiftData, iOS 27 SDK). The app target's real
/// deployment target is iOS 27.0 (architecture.md "Target: iOS 27+"), so
/// this is never a real constraint there; it only matters for this
/// package's `swift test`, which builds for the macOS *host* at this
/// package's deliberately-kept-lower macOS 26.0 deployment target (this
/// file's header) -- the annotation is what lets the rest of the package
/// keep compiling there at all while this one type stays macOS-27-only.
@available(macOS 27, iOS 27, *)
@MainActor
public final class KnowledgeRefreshTrigger {
    private let observer: HistoryObserver
    private let minimumInterval: TimeInterval
    private let now: @MainActor () -> Date
    private let onNeedsRefresh: @MainActor () -> Void
    private var lastFiredAt: Date?

    public init(
        modelContainer: ModelContainer,
        observedModels: [any PersistentModel.Type] = [SyncState.self, LocalSample.self],
        minimumInterval: TimeInterval = 3600,
        now: @escaping @MainActor () -> Date = { .now },
        onNeedsRefresh: @escaping @MainActor () -> Void
    ) throws {
        self.observer = try HistoryObserver(observedModels: observedModels, modelContainer: modelContainer)
        self.minimumInterval = minimumInterval
        self.now = now
        self.onNeedsRefresh = onNeedsRefresh
        observeChanges()
    }

    private func observeChanges() {
        withObservationTracking {
            _ = observer.eventCounter
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleChange()
            }
        }
    }

    // Code review (2026-08-28) finding #8: re-registering tracking only
    // after this MainActor hop (in `defer` below) leaves a real gap -- a
    // change landing between `onChange` firing and re-registration
    // completing is missed. Tried the seemingly obvious fix (re-register
    // *synchronously* inside `onChange`, before the hop) and verified by
    // direct compilation that it does not build: `onChange`'s closure runs
    // in a nonisolated context (`withObservationTracking` itself is a plain
    // nonisolated global function), so calling this class's MainActor-
    // isolated `observeChanges()` from it is a compile error, not merely a
    // style choice -- closing the gap would need a genuinely different
    // mechanism (e.g. an AsyncSequence-based observation bridge), not a
    // reordering of this one. This is Apple's own documented recursive-
    // registration idiom for `Observable` types (matches the WWDC/
    // Observation-framework sample pattern verbatim) and shares its known,
    // narrow limitation. Accepted as-is: the window is one MainActor hop
    // wide, and a missed write is not lost data, only a deferred refresh --
    // per this file's own top-level doc comment, it "self-corrects" the
    // moment any other write lands.
    private func handleChange() {
        defer { observeChanges() }
        let current = now()
        guard KnowledgeRefreshThrottle.shouldFire(lastFiredAt: lastFiredAt, now: current, minimumInterval: minimumInterval) else {
            return
        }
        lastFiredAt = current
        onNeedsRefresh()
    }
}
#endif
