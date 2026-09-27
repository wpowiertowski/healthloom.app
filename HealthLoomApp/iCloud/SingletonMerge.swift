// SingletonMerge.swift
//
// WP-59: the three-way merge `CloudSyncEngine` runs when the server's
// settings or insight prefs changed since this device last saw them (see
// the conflict model in CloudSyncEngine.swift's header), plus the one
// definition of "same content" every push/pull comparison uses.

import Foundation

/// Three-way merge of a singleton the server changed since we last saw it
/// (WP-59). `base` is the content both sides last agreed on: a field this
/// device changed since then and the server didn't keeps the local value;
/// everything else takes the server's. Disabled types merge per type, so
/// one device disabling Sleep and another disabling Steps leaves both off.
/// Only a field both sides changed goes to the server (the convergence
/// tradeoff, now limited to a true same-field conflict). No clocks
/// compared, so skew can't pick the winner.
nonisolated enum SingletonMerge {
    static func settings(base: SyncSettingsSnapshot, local: SyncSettingsSnapshot, server: SyncSettingsSnapshot) -> SyncSettingsSnapshot {
        let baseSet = Set(base.disabledTypeRawValues)
        let localSet = Set(local.disabledTypeRawValues)
        let disabled = Set(server.disabledTypeRawValues)
            .union(localSet.subtracting(baseSet))
            .subtracting(baseSet.subtracting(localSet))
        return SyncSettingsSnapshot(
            disabledTypeRawValues: disabled.sorted(),
            preferAppleWatch: field(\.preferAppleWatch, base, local, server),
            updatedAt: server.updatedAt
        )
    }

    static func prefs(base: InsightPrefsSnapshot, local: InsightPrefsSnapshot, server: InsightPrefsSnapshot) -> InsightPrefsSnapshot {
        InsightPrefsSnapshot(
            morningInsightsEnabled: field(\.morningInsightsEnabled, base, local, server),
            lockScreenDetails: field(\.lockScreenDetails, base, local, server),
            insightsViaCloud: field(\.insightsViaCloud, base, local, server),
            lastRun: field(\.lastRun, base, local, server),
            updatedAt: server.updatedAt
        )
    }

    /// Equal synced content, ignoring `updatedAt` stamps.
    static func sameContent(_ lhs: SyncSettingsSnapshot, _ rhs: SyncSettingsSnapshot) -> Bool {
        lhs.disabledTypeRawValues.sorted() == rhs.disabledTypeRawValues.sorted()
            && lhs.preferAppleWatch == rhs.preferAppleWatch
    }

    static func sameContent(_ lhs: InsightPrefsSnapshot, _ rhs: InsightPrefsSnapshot) -> Bool {
        lhs.morningInsightsEnabled == rhs.morningInsightsEnabled
            && lhs.lockScreenDetails == rhs.lockScreenDetails
            && lhs.insightsViaCloud == rhs.insightsViaCloud
            && lhs.lastRun == rhs.lastRun
    }

    private static func field<Snapshot, Value: Equatable>(
        _ keyPath: KeyPath<Snapshot, Value>, _ base: Snapshot, _ local: Snapshot, _ server: Snapshot
    ) -> Value {
        let changedHere = local[keyPath: keyPath] != base[keyPath: keyPath]
        let changedThere = server[keyPath: keyPath] != base[keyPath: keyPath]
        return changedHere && !changedThere ? local[keyPath: keyPath] : server[keyPath: keyPath]
    }
}
