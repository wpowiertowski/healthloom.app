// GoogleHealthClient.swift (DataClient)
//
// WP-05 (implementation-plan.md): paged, resilient, normalized reads from
// `health.googleapis.com/v4/`. Named to match architecture.md §2's module
// map ("Key types: ... `GoogleHealthClient`, `GoogleDataPoint`") -- yes, the
// same name as the package/module itself; Swift permits this (see
// progress.md's WP-05 note if this ever needs revisiting).
//
// Resource pattern (base-knowledge.md §2): `users/me/dataTypes/{dataType}/dataPoints`,
// with the read method as a colon-suffixed custom-method suffix
// (`:reconcile`, `:dailyRollup`) per Google API convention for custom RPC-style
// methods. base-knowledge.md doesn't pin down the exact request verb/body
// shape for `reconcile`/`dailyRollup` (the doc is explicit that intraday
// endpoints were still rolling out as of its "last verified" date) -- POST
// with a JSON body (`startTime`/`endTime`/`pageToken`) was chosen as the most
// plausible shape for a paginated, windowed custom method; this is flagged in
// progress.md as an assumption to reconcile once real API docs/access exist.
//
// Concurrency: WP-05 step 6 ("All calls @concurrent/nonisolated"). This
// package's default isolation is `MainActor` (Package.swift), so without an
// explicit override, an `async` method on this struct would hop to the main
// actor before running -- wrong for network I/O. `@concurrent` forces
// execution on the concurrent thread pool regardless of the caller's
// isolation, matching architecture.md §3 ("networking ... is `@concurrent`").

import CoreModel
import Foundation

nonisolated public struct GoogleHealthClient: Sendable {
    public enum Method: String, Sendable {
        case reconcile
        case dailyRollup
    }

    private let config: GoogleHealthClientConfig
    private let httpSession: any HTTPSession
    private let auth: GoogleAuthManager
    private let sleeper: any BackoffSleeper
    private let jitter: any JitterSource

    public init(
        config: GoogleHealthClientConfig = .init(),
        httpSession: any HTTPSession,
        auth: GoogleAuthManager,
        sleeper: any BackoffSleeper = SystemSleeper(),
        jitter: any JitterSource = SystemJitterSource()
    ) {
        self.config = config
        self.httpSession = httpSession
        self.auth = auth
        self.sleeper = sleeper
        self.jitter = jitter
    }

    /// `reconcile` — the merged, de-duplicated read path (architecture.md D1;
    /// base-knowledge.md §2). The **only** path this app uses for device
    /// sample data.
    @concurrent
    public func reconcile(type: GoogleDataType, since: Date, until: Date, pageToken: String? = nil) async throws(GoogleHealthClientError) -> Page {
        try await fetchPage(type: type, method: .reconcile, since: since, until: until, pageToken: pageToken)
    }

    /// `dailyRollup` — server-stitched daily aggregates, used additionally
    /// for daily-summary types since it composes correctly across DST/
    /// timezone travel (architecture.md D1).
    @concurrent
    public func dailyRollup(type: GoogleDataType, since: Date, until: Date, pageToken: String? = nil) async throws(GoogleHealthClientError) -> Page {
        try await fetchPage(type: type, method: .dailyRollup, since: since, until: until, pageToken: pageToken)
    }

    // MARK: - Fetch + resilience (WP-05 step 5)

    private func fetchPage(
        type: GoogleDataType,
        method: Method,
        since: Date,
        until: Date,
        pageToken: String?
    ) async throws(GoogleHealthClientError) -> Page {
        var attempt = 1
        var retriedAfter401 = false
        // `type.endpointName` is a user-declared computed property in
        // CoreModel, which -- like this package -- opts into
        // `.defaultIsolation(MainActor.self)` (architecture.md §3), so
        // reading it requires an actor hop; resolved once here rather than
        // on every retry through the loop below.
        let endpointName = await type.endpointName

        while true {
            // Cooperative probe: a cancel landing anywhere except the
            // backoff sleep below (the dominant window is the in-flight
            // request, not the sleep) must surface as `.cancelled`, not
            // ride the next await into a `.transport` error row.
            guard !Task.isCancelled else { throw .cancelled }

            let token: String
            do {
                token = try await auth.validAccessToken()
            } catch {
                throw .unauthorized
            }

            let request = buildRequest(endpointName: endpointName, method: method, since: since, until: until, pageToken: pageToken, bearerToken: token)

            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await httpSession.send(request)
            } catch is CancellationError {
                throw .cancelled
            } catch let urlError as URLError where urlError.code == .cancelled {
                // URLSession reports cancellation as a value, not a throw
                // of `CancellationError` -- without this arm every
                // expiration-handler cancel during a live request becomes a
                // red dashboard row.
                throw .cancelled
            } catch {
                throw .transport(String(describing: Swift.type(of: error)))
            }

            switch response.statusCode {
            case 200..<300:
                return try decodePage(data, type: type)

            case 401:
                guard !retriedAfter401 else { throw .unauthorized }
                retriedAfter401 = true
                do { _ = try await auth.forceRefresh() } catch { throw .unauthorized }
                continue

            case 429, 500...599:
                guard attempt < config.backoff.maxAttempts else {
                    throw response.statusCode == 429 ? .rateLimited : .server(status: response.statusCode)
                }
                let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                let delay = config.backoff.delay(forAttempt: attempt, retryAfter: retryAfter, jitterFraction: jitter.nextFraction())
                do {
                    try await sleeper.sleep(seconds: delay)
                } catch is CancellationError {
                    // Never `try?` a backoff sleep: swallowing cancellation
                    // burns the remaining attempts back-to-back with no
                    // delay, against a server that just rate-limited us,
                    // in the exact window the system is winding us down.
                    throw GoogleHealthClientError.cancelled
                } catch {
                    throw .transport(String(describing: Swift.type(of: error)))
                }
                attempt += 1
                continue

            default:
                throw .server(status: response.statusCode)
            }
        }
    }

    // MARK: - Request building

    func buildRequest(
        endpointName: String,
        method: Method,
        since: Date,
        until: Date,
        pageToken: String?,
        bearerToken: String
    ) -> URLRequest {
        let urlString = config.baseURL + "users/me/dataTypes/\(endpointName)/dataPoints:\(method.rawValue)"
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "startTime": ISO8601Formatting.string(from: since),
            "endTime": ISO8601Formatting.string(from: until),
        ]
        if let pageToken { body["pageToken"] = pageToken }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    // MARK: - Decoding (WP-05 step 2/3)

    func decodePage(_ data: Data, type: GoogleDataType) throws(GoogleHealthClientError) -> Page {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw .decodingFailed("invalid JSON")
        }
        guard let dict = object as? [String: Any] else {
            throw .decodingFailed("expected a top-level JSON object")
        }
        let nextPageToken = dict["nextPageToken"] as? String
        let rawPoints = (dict["point"] as? [[String: Any]]) ?? []
        var points: [GoogleDataPoint] = []
        points.reserveCapacity(rawPoints.count)
        for rawPoint in rawPoints {
            points.append(try decodeDataPoint(rawPoint, type: type))
        }
        return Page(points: points, nextPageToken: nextPageToken)
    }

    private func decodeDataPoint(_ dict: [String: Any], type: GoogleDataType) throws(GoogleHealthClientError) -> GoogleDataPoint {
        guard
            let id = dict["dataPointId"] as? String,
            let startString = dict["startTime"] as? String,
            let endString = dict["endTime"] as? String,
            let start = ISO8601Formatting.date(from: startString),
            let end = ISO8601Formatting.date(from: endString)
        else {
            throw .decodingFailed("missing/invalid required data point fields")
        }

        let sourceDict = dict["dataSource"] as? [String: Any]
        let deviceDict = sourceDict?["device"] as? [String: Any]
        let source = DataSource(
            platform: sourceDict?["platform"] as? String,
            deviceDisplayName: deviceDict?["displayName"] as? String,
            recordingMethod: sourceDict?["recordingMethod"] as? String
        )

        var values: [String: Double] = [:]
        var hasNestedFields = false
        let valueDict = dict["value"] as? [String: Any] ?? [:]
        for (key, raw) in valueDict {
            let field = stripDataTypePrefix(key, dataType: type)
            if let number = raw as? NSNumber, !isBoolNSNumber(number) {
                values[field] = UnitNormalizer.normalize(dataType: type, field: field, rawValue: number.doubleValue)
            } else {
                hasNestedFields = true
            }
        }

        var sessionPayload: Data?
        if hasNestedFields {
            sessionPayload = try? JSONSerialization.data(withJSONObject: valueDict, options: [.sortedKeys])
        }

        return GoogleDataPoint(
            id: id,
            dataType: type,
            start: start,
            end: end,
            source: source,
            values: values,
            sessionPayload: sessionPayload
        )
    }

    /// Uses `dataType.rawValue` (== `filterName`) directly rather than the
    /// `filterName` computed property -- see `UnitNormalizer.normalize`'s
    /// doc comment for why.
    private func stripDataTypePrefix(_ key: String, dataType: GoogleDataType) -> String {
        let prefix = dataType.rawValue + "."
        guard key.hasPrefix(prefix) else { return key }
        return String(key.dropFirst(prefix.count))
    }

    /// `NSNumber` boxes both real numbers and Objective-C-bridged `Bool`
    /// (`kCFBooleanTrue`/`False` decode from `JSONSerialization` as
    /// `NSNumber` too). Google Health API scalar fields are never booleans,
    /// so treat a boolean-boxed `NSNumber` as a nested/non-scalar field
    /// rather than silently coercing `true`/`false` to `1.0`/`0.0`.
    private func isBoolNSNumber(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
