// HRVHealthKitMigration.swift
//
// WP-62: HRV moved from in-app rows to Apple Health. New points go
// straight there, and the incremental sync's lookback rewrites the last
// few days, but the history was imported as in-app rows only. This
// restarts HRV's history import (it runs while Data > Historical Backfill
// is open) so past nights reach Apple Health, and deletes the in-app HRV
// rows nothing reads any more. Once per install (`OneTimeTask`).

import CoreModel
import Foundation
import SwiftData

enum HRVHealthKitMigration {
    static let defaultsKey = "com.healthloom.repair.hrvToHealthKit"

    static func runIfNeeded(
        defaults: UserDefaults = .standard,
        restartHistory: () async throws -> Void,
        deleteLocalRows: () throws -> Int
    ) async {
        await OneTimeTask.runIfNeeded(key: defaultsKey, defaults: defaults) {
            try await restartHistory()
            let deleted = try deleteLocalRows()
            return "HRV history restarted, \(deleted) in-app rows removed"
        }
    }

    /// Deletes every in-app (`LocalSample`) HRV row; returns how many.
    static func deleteLocalRows(in container: ModelContainer) throws -> Int {
        let context = ModelContext(container)
        let key = GoogleDataType.heartRateVariability.rawValue
        let rows = try context.fetch(FetchDescriptor<LocalSample>(predicate: #Predicate { $0.dataType == key }))
        rows.forEach(context.delete)
        try context.save()
        return rows.count
    }
}
