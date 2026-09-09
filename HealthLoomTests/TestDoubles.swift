// TestDoubles.swift
// HealthLoomTests
//
// Shared test doubles (WP-30 N3: moved — not widened — out of
// `CoachChatViewModelTests.swift` on the next touch that needed them
// cross-file, so reuse extends the shared file instead of widening more
// `private`s).

import CoachKit
import Foundation
import FoundationModels
import SyncKit
import Testing

/// Empty health data: every read returns nothing, so refreshes complete
/// instantly without touching HealthKit.
struct EmptyReadStore: HealthReadStore {
    func dailySteps(from start: Date, to end: Date) async -> [DailyQuantityValue] { [] }
    func dailyRestingHeartRate(from start: Date, to end: Date) async -> [QuantityReading] { [] }
    func dailyHeartRateVariability(from start: Date, to end: Date) async -> [QuantityReading] { [] }
    func sleepStageSegments(from start: Date, to end: Date) async -> [SleepStageSegment] { [] }
    func workouts(from start: Date, to end: Date) async -> [WorkoutRecord] { [] }
}

struct StreamBoom: Error {}

/// Controllable `CoachSession`: fixed chunks with an optional throw after
/// `failAfterChunks`, an optional never-yield mode (consumer cancel ends
/// iteration), and a per-chunk delay so tests can stop mid-stream.
final class TestCoachSession: CoachSession, @unchecked Sendable {
    let chunks: [String]
    let failAfterChunks: Int?
    let suspendForever: Bool
    let chunkDelay: Duration

    init(
        chunks: [String] = ["Hello ", "world."],
        failAfterChunks: Int? = nil,
        suspendForever: Bool = false,
        chunkDelay: Duration = .milliseconds(50)
    ) {
        self.chunks = chunks
        self.failAfterChunks = failAfterChunks
        self.suspendForever = suspendForever
        self.chunkDelay = chunkDelay
    }

    var isResponding: Bool { false }
    func prewarm() {}
    func respond(to prompt: String) async throws -> String { chunks.joined() }
    func respond<Content: Generable>(to prompt: String, generating type: Content.Type) async throws -> Content {
        throw StreamBoom()
    }
    func stream(to prompt: String) -> AsyncThrowingStream<String, Error> {
        let chunks = chunks
        let failAfterChunks = failAfterChunks
        let suspendForever = suspendForever
        let chunkDelay = chunkDelay
        return AsyncThrowingStream { continuation in
            if suspendForever { return }
            let task = Task {
                for (index, chunk) in chunks.enumerated() {
                    try? await Task.sleep(for: chunkDelay)
                    if Task.isCancelled { break }
                    if failAfterChunks == index {
                        continuation.finish(throwing: StreamBoom())
                        return
                    }
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Records `prewarm()` calls (WP-37 first-token-latency pin: `onAppear`
/// must warm the session so the first token doesn't pay cold-start).
/// Chat-shaped, never throws; lock-guarded counter, immutable otherwise.
final class PrewarmProbeSession: CoachSession, Sendable {
    private let lock = NSLock()
    private var _prewarmCount = 0

    var prewarmCount: Int { lock.withLock { _prewarmCount } }

    var isResponding: Bool { false }
    func prewarm() {
        lock.withLock { _prewarmCount += 1 }
    }
    func respond(to prompt: String) async throws -> String { "" }
    func respond<Content: Generable>(to prompt: String, generating type: Content.Type) async throws -> Content {
        throw StreamBoom()
    }
    func stream(to prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// Shared HealthKit-symbol ban (third-party item 9): the iCloud sync and
/// tip-jar directories must contain no HealthKit-sourced types or values
/// — structural proof that health data cannot cross into CloudKit records
/// or purchase code. One constant + one assertion; both privacy suites
/// call it instead of carrying verbatim copies (literal drift).
enum BannedHealthSymbols {
    static let all = [
        "HealthKit", "HKQuantity", "HKSample", "HKObject", "HKHealthStore",
        "HKWorkout", "LocalSample", "GoogleDataPoint", "HKUnit", "HKStatistics",
    ]
}

/// Asserts no banned symbol appears in the Swift SOURCES under `directory`
/// (repo-relative, e.g. `"HealthLoomApp/iCloud"`). `//` line comments are
/// skipped — prose documents the ban by naming it; code may not contain it.
///
/// `file`/`sourceLocation` default to the CALLER's (Swift evaluates
/// default arguments at the call site, and the repo root resolves
/// identically for every caller in this directory) — a failure attributes
/// to the test that caught the symbol, never to this file. The loop
/// variable is deliberately NOT named `file` (it used to shadow the
/// parameter; round-2 item 5).
func assertNoHealthKitSymbols(
    in directory: String,
    file: StaticString = #filePath,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let thisFile = URL(fileURLWithPath: String(describing: file))
    let dir = thisFile
        .deletingLastPathComponent() // HealthLoomTests
        .deletingLastPathComponent() // repo root
        .appendingPathComponent(directory)
    var hits: [String] = []
    for candidate in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
        guard candidate.pathExtension == "swift" else { continue }
        let source = try String(contentsOf: candidate, encoding: .utf8)
        let code = source
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        for symbol in BannedHealthSymbols.all where code.contains(symbol) {
            hits.append("\(candidate.lastPathComponent): \(symbol)")
        }
    }
    #expect(hits.isEmpty, "HealthKit symbols in \(directory): \(hits)", sourceLocation: sourceLocation)
}

/// Ephemeral `UserDefaults` suite that cleans up after itself
/// (third-party round-2 item 14: rolled out to EVERY suite site — no
/// half-migration). Three layers, because each alone has a hole:
/// - PRE-CLEAN at init: a fresh suite even if a same-named suite (e.g.
///   a `#function`-keyed one) survived a previous run in this process.
/// - POST-CLEAN at deinit: removes the domain when the holder drops.
///   Best-effort — Swift frees locals after their LAST USE, not at
///   scope end, so an early drop can precede later writes (which would
///   recreate the plist).
/// - `atexit` JANITOR backstop: every suite name ever minted is removed
///   again at process exit, so the plist leak is closed even where a
///   holder's lifetime ends early. The janitor is the guarantee; holder
///   lifetime (fixture ownership / `withExtendedLifetime` at
///   vacuity-sensitive assertions) is defense-in-depth.
/// Hold one per test, never share.
final class EphemeralDefaults {
    let defaults: UserDefaults
    /// The suite name (for call sites that must name their suite, e.g.
    /// a wipe-coordinator reset closure that removes its own domain).
    var suiteName: String { name }
    private let name: String

    init(prefix: String) throws {
        self.name = "\(prefix)-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            throw EphemeralDefaultsError.noSuite
        }
        self.defaults = defaults
        defaults.removePersistentDomain(forName: name) // pre-clean
        EphemeralDefaultsJanitor.track(name)
    }

    deinit {
        // Via a fresh instance: `deinit` is nonisolated and `defaults`
        // is non-Sendable. Domain-keyed, so this removes the same
        // persisted plist the held instance wrote.
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
    }
}

/// Process-exit backstop for ephemeral suites (see `EphemeralDefaults`).
/// Test-support only — never ships. File-scope globals (not type
/// members): the `atexit` handler is a context-free C function and can
/// only touch globals.
nonisolated(unsafe) private var janitorNames: [String] = []
nonisolated(unsafe) private var janitorArmed = false
private let janitorLock = NSLock()

enum EphemeralDefaultsJanitor {
    static func track(_ name: String) {
        janitorLock.withLock {
            janitorNames.append(name)
            if !janitorArmed {
                janitorArmed = true
                Darwin.atexit {
                    let pending = janitorLock.withLock { janitorNames }
                    for name in pending {
                        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
                    }
                }
            }
        }
    }
}

enum EphemeralDefaultsError: Error {
    case noSuite
}
