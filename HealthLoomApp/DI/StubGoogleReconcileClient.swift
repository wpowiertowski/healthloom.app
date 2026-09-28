// StubGoogleReconcileClient.swift
//
// WP-10 (implementation-plan.md): used only when the app launches with
// `-UITestStubGoogle` (see LaunchConfiguration.swift) so onboarding's "first
// sync" step (FirstSyncView -> SyncEngine.syncAll) never makes a real
// network call to Google -- it returns an immediately-successful, empty
// page for every type. `SyncEngine` (Packages/SyncKit/Sources/SyncKit/
// SyncEngine/SyncEngine.swift) treats an empty page as a fully-successful
// zero-item run (cursor still advances, `lastStatus` still becomes "ok"),
// so the dashboard the onboarding flow lands on shows real "ok" states, not
// fabricated ones.
//
// Real API discovered here (progress.md's WP-09 entry, `SyncEngineTypes
// .swift`): `GoogleReconcileClient`'s one requirement is
// `nonisolated func reconcile(type:since:until:pageToken:) async
// throws(GoogleHealthClientError) -> Page` -- matches the real
// `GoogleHealthClient`'s own signature exactly (SyncKit conforms it via
// `GoogleHealthClient+SyncEngine.swift` with zero additional code), so this
// stub only has to match that same shape.

import CoreModel
import Foundation
import GoogleHealthClient
import SwiftData
import SyncKit

nonisolated struct StubGoogleReconcileClient: GoogleReconcileClient {
    /// WP-69: realistic volume instead of empty pages (see `LaunchConfiguration
    /// .stubGoogleVolume`). Empty pages otherwise.
    var volume = false

    /// Per-minute Active Minutes and 5-minute Zone Minutes -- the local-only
    /// streams that land in the store -- for any requested window.
    static let volumeStreams: [(type: GoogleDataType, every: TimeInterval)] = [
        (.activeMinutes, 60), (.activeZoneMinutes, 300),
    ]

    nonisolated func reconcile(
        type: GoogleDataType,
        since: Date,
        until: Date,
        pageToken: String?
    ) async throws(GoogleHealthClientError) -> Page {
        guard volume, let stream = Self.volumeStreams.first(where: { $0.type == type }) else {
            return Page(points: [], nextPageToken: nil)
        }
        // A network round trip's worth of latency, so the sync lasts.
        try? await Task.sleep(for: .milliseconds(150))
        return Page(points: Self.points(type, every: stream.every, from: since, to: until), nextPageToken: nil)
    }

    static func points(_ type: GoogleDataType, every step: TimeInterval, from start: Date, to end: Date) -> [GoogleDataPoint] {
        let first = (start.timeIntervalSince1970 / step).rounded(.up) * step
        return stride(from: first, to: end.timeIntervalSince1970, by: step).map { time in
            GoogleDataPoint(
                id: "\(type.rawValue)/\(Int(time))",
                dataType: type,
                start: Date(timeIntervalSince1970: time),
                end: Date(timeIntervalSince1970: time + step),
                source: DataSource(platform: "IOS", deviceDisplayName: "Fitbit Air", recordingMethod: "AUTOMATICALLY_RECORDED"),
                values: ["minutes": 1]
            )
        }
    }

    /// 60 days of the volume streams already in the store, as a user a
    /// couple of months in has.
    @MainActor
    static func seedHistory(in container: ModelContainer, now: Date = Date()) {
        let context = ModelContext(container)
        let start = now.addingTimeInterval(-60 * 86_400)
        for stream in volumeStreams {
            for point in points(stream.type, every: stream.every, from: start, to: now.addingTimeInterval(-4 * 86_400)) {
                context.insert(LocalSample(
                    externalID: point.id,
                    dataType: point.dataType.rawValue,
                    payloadJSON: Data(#"{"values":{"minutes":1}}"#.utf8),
                    start: point.start,
                    end: point.end,
                    source: "Fitbit Air"
                ))
            }
        }
        try? context.save()
    }
}
