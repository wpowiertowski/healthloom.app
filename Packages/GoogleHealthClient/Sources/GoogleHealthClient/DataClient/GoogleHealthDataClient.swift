// GoogleHealthClient.swift (DataClient)
//
// WP-05 (implementation-plan.md): paged, resilient, normalized reads from
// `health.googleapis.com/v4/`. Named to match architecture.md §2's module
// map ("Key types: ... `GoogleHealthClient`, `GoogleDataPoint`") -- yes, the
// same name as the package/module itself; Swift permits this (see
// progress.md's WP-05 note if this ever needs revisiting).
//
// WP-51: requests and responses follow the published v4 reference -- see
// `GoogleDataTypeSchema.swift`, which holds every per-type fact (read
// method, filter field, response fields, units). Reads are
// `GET users/me/dataTypes/{kebab-type}/dataPoints:reconcile` (or plain
// `dataPoints` for the few non-reconcilable types) with an AIP-160 `filter`
// time window and an empty body.
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

    /// `reconcile` — the merged, de-duplicated read path (architecture.md D1).
    /// The **only** read this app uses for device data. A type that isn't
    /// reconcilable is listed instead (`GoogleDataTypeSchema.endpoint`); a
    /// type that isn't readable as data points at all throws
    /// `.notAvailableFromGoogle`.
    @concurrent
    public func reconcile(type: GoogleDataType, since: Date, until: Date, pageToken: String? = nil) async throws(GoogleHealthClientError) -> Page {
        guard let schema = GoogleDataTypeSchema.schema(for: type) else { throw .notAvailableFromGoogle }
        let page = try await fetchPage(schema: schema, since: since, until: until, pageToken: pageToken)
        return schema.holdingToWindow(page, until: until)
    }

    // MARK: - Fetch + resilience (WP-05 step 5)

    private func fetchPage(
        schema: GoogleDataTypeSchema,
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
        let endpointName = await schema.type.endpointName

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

            let request = buildRequest(endpointName: endpointName, schema: schema, since: since, until: until, pageToken: pageToken, bearerToken: token)

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
                return try decodePage(data, schema: schema)

            case 403:
                throw .permissionDenied

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
        schema: GoogleDataTypeSchema,
        since: Date,
        until: Date,
        pageToken: String?,
        bearerToken: String
    ) -> URLRequest {
        var components = URLComponents(
            string: config.baseURL + "users/me/dataTypes/\(endpointName)/dataPoints\(schema.endpoint.rawValue)"
        )!
        var items = [
            URLQueryItem(name: "filter", value: schema.filter(since: since, until: until, timeZone: config.civilTimeZone)),
            URLQueryItem(name: "pageSize", value: String(schema.pageSize)),
        ]
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: - Decoding

    /// `decodePage` for a type, looking up its schema (tests decode fixtures
    /// by type).
    func decodePage(_ data: Data, type: GoogleDataType) throws(GoogleHealthClientError) -> Page {
        guard let schema = GoogleDataTypeSchema.schema(for: type) else { throw .notAvailableFromGoogle }
        return try decodePage(data, schema: schema)
    }

    /// Failures name the type and the missing field -- never a value -- so a
    /// schema mismatch shows up in the Sync Log as a readable reason.
    func decodePage(_ data: Data, schema: GoogleDataTypeSchema) throws(GoogleHealthClientError) -> Page {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw .decodingFailed("invalid JSON")
        }
        guard let dict = object as? [String: Any] else {
            throw .decodingFailed("expected a top-level JSON object")
        }
        let nextPageToken = (dict["nextPageToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let rawPoints = (dict["dataPoints"] as? [[String: Any]]) ?? []
        var points: [GoogleDataPoint] = []
        points.reserveCapacity(rawPoints.count)
        for rawPoint in rawPoints {
            points.append(try decodeDataPoint(rawPoint, schema: schema))
        }
        return Page(points: points, nextPageToken: nextPageToken)
    }

    private func decodeDataPoint(_ raw: [String: Any], schema: GoogleDataTypeSchema) throws(GoogleHealthClientError) -> GoogleDataPoint {
        let label = schema.type.rawValue
        guard let body = raw[schema.unionKey] as? [String: Any] else {
            throw .decodingFailed("\(label): missing \(schema.unionKey)")
        }
        let (start, end) = try times(of: body, schema: schema)

        var values: [String: Double] = [:]
        for rule in schema.values {
            if let number = GoogleValueReader.read(rule.source, in: body) {
                values[rule.outKey] = number * rule.scale
            }
        }
        // A type that should carry values but resolved none has fields we
        // don't recognise -- say which, rather than writing empty samples.
        if !schema.values.isEmpty, values.isEmpty {
            throw .decodingFailed("\(label): none of \(schema.values.map(\.outKey).joined(separator: ", ")) found")
        }

        let sessionPayload = schema.keepsPayload
            ? try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            : nil

        return GoogleDataPoint(
            id: Self.pointID(raw: raw, body: body, schema: schema, start: start, end: end),
            dataType: schema.type,
            start: start,
            end: end,
            source: Self.source(from: raw),
            values: values,
            sessionPayload: sessionPayload,
            utcOffset: Self.utcOffset(of: body, schema: schema)
        )
    }

    /// `sampleTime.utcOffset` in seconds (a protobuf Duration, e.g.
    /// "-25200s"), or `nil` when the type has no sample time, the field is
    /// absent, or it isn't a plausible offset (beyond ±14 h).
    static func utcOffset(of body: [String: Any], schema: GoogleDataTypeSchema) -> TimeInterval? {
        guard schema.time == .sampleTime,
              let sample = body["sampleTime"] as? [String: Any],
              let text = sample["utcOffset"] as? String,
              text.hasSuffix("s"),
              let seconds = Double(text.dropLast()),
              seconds.isFinite, abs(seconds) <= 14 * 3600
        else { return nil }
        return seconds
    }

    private func times(of body: [String: Any], schema: GoogleDataTypeSchema) throws(GoogleHealthClientError) -> (Date, Date) {
        let label = schema.type.rawValue
        switch schema.time {
        case .observationInterval, .session, .sleepSession, .ecgSession:
            guard let interval = body["interval"] as? [String: Any],
                  let start = (interval["startTime"] as? String).flatMap(ISO8601Formatting.date(from:)),
                  let end = (interval["endTime"] as? String).flatMap(ISO8601Formatting.date(from:))
            else { throw .decodingFailed("\(label): missing interval.startTime/endTime") }
            return (start, end)
        case .sampleTime:
            guard let sample = body["sampleTime"] as? [String: Any],
                  let time = (sample["physicalTime"] as? String).flatMap(ISO8601Formatting.date(from:))
            else { throw .decodingFailed("\(label): missing sampleTime.physicalTime") }
            return (time, time)
        case .date:
            guard let date = body["date"] as? [String: Any],
                  let year = date["year"] as? Int, let month = date["month"] as? Int, let day = date["day"] as? Int
            else { throw .decodingFailed("\(label): missing date") }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = config.civilTimeZone
            guard let start = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                  let end = calendar.date(byAdding: .day, value: 1, to: start)
            else { throw .decodingFailed("\(label): invalid date") }
            // A daily summary spans its civil day.
            return (start, end)
        }
    }

    /// Stable across syncs, which is what the pipeline's "already written"
    /// check keys on: the API's own name when it gives one (only some types
    /// do), else type + interval (+ the discriminator, e.g. the heart-rate
    /// zone). Reconciled points never overlap within a type, so that's unique.
    static func pointID(raw: [String: Any], body: [String: Any], schema: GoogleDataTypeSchema, start: Date, end: Date) -> String {
        for key in ["dataPointName", "name"] {
            if let name = raw[key] as? String, !name.isEmpty { return name }
        }
        var id = "\(schema.type.rawValue)/\(Int64(start.timeIntervalSince1970 * 1000))-\(Int64(end.timeIntervalSince1970 * 1000))"
        if let key = schema.idDiscriminator, let part = body[key].map({ "\($0)" }) {
            id += "/\(part)"
        }
        return id
    }

    /// Listed points carry `dataSource`; reconciled points don't (the merge
    /// has no single source), so they're labelled as Google Health.
    static func source(from raw: [String: Any]) -> DataSource {
        guard let dict = raw["dataSource"] as? [String: Any] else {
            return DataSource(platform: "Google Health", deviceDisplayName: nil, recordingMethod: nil)
        }
        let device = dict["device"] as? [String: Any]
        return DataSource(
            platform: dict["platform"] as? String,
            deviceDisplayName: device?["displayName"] as? String,
            recordingMethod: dict["recordingMethod"] as? String
        )
    }
}

/// Reads numbers out of a union object: JSON numbers or int64-as-string
/// (the API sends `count`, `beatsPerMinute` ... as strings). Booleans are
/// never numbers here.
nonisolated enum GoogleValueReader {
    static func read(_ source: GoogleValueRule.Source, in body: [String: Any]) -> Double? {
        switch source {
        case .path(let path):
            var node: Any? = body
            for key in path { node = (node as? [String: Any])?[key] }
            return number(node)
        case .nutrient(let name):
            let nutrients = body["nutrients"] as? [[String: Any]] ?? []
            guard let match = nutrients.first(where: { ($0["nutrient"] as? String) == name }) else { return nil }
            return number((match["quantity"] as? [String: Any])?["grams"])
        case .sum(let array, let field):
            let items = body[array] as? [[String: Any]] ?? []
            let parts = items.compactMap { number($0[field]) }
            return parts.isEmpty ? nil : parts.reduce(0, +)
        }
    }

    static func number(_ value: Any?) -> Double? {
        if let string = value as? String { return Double(string) }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.doubleValue
        }
        return nil
    }
}
