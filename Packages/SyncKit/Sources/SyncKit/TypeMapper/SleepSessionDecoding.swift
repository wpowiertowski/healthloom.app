// SleepSessionDecoding.swift
//
// WP-07 step 3 (implementation-plan.md): decodes a Google sleep session's
// stage breakdown from `GoogleDataPoint.sessionPayload`, which carries the
// API's typed `sleep` object verbatim. WP-51: the real v4 shape (published
// reference) is `stages: [{startTime, endTime, type}]` with `type` one of
// AWAKE / LIGHT / DEEP / REM (staged sleep) or ASLEEP / RESTLESS (classic
// sleep). The pre-WP-51 assumption (`"sleep.segment"`, lowercase `stage`)
// never matched a real response.
//
// Deliberately its own file / HealthKit-free, same rationale as
// GoogleHealthClient's `ISO8601Formatting.swift` (which this mirrors but
// cannot reuse directly -- that type is package-internal, not `public`):
// two `ISO8601DateFormatter`s (with/without fractional seconds) because
// fixtures or real responses may or may not include them.

import Foundation

nonisolated struct SleepSessionWire: Decodable {
    nonisolated struct Segment: Decodable {
        let startTime: Date
        let endTime: Date
        let stage: String

        private enum CodingKeys: String, CodingKey {
            case startTime, endTime
            case stage = "type"
        }
    }

    let segments: [Segment]

    private enum CodingKeys: String, CodingKey {
        case segments = "stages"
    }

    /// A session without a stage breakdown (a short nap, some classic
    /// sleeps) decodes to no segments rather than failing.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        segments = try container.decodeIfPresent([Segment].self, forKey: .segments) ?? []
    }
}

nonisolated enum SleepSessionDecoding {
    // `nonisolated(unsafe)`: each formatter is configured once at first
    // access and never mutated afterward; only its (read-only, thread-safe
    // in practice) `date(from:)` method is called after that -- same
    // rationale/precedent as GoogleHealthClient's `ISO8601Formatting.swift`.
    nonisolated(unsafe) private static let basicFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func date(from string: String) -> Date? {
        basicFormatter.date(from: string) ?? fractionalFormatter.date(from: string)
    }

    /// Decodes `payload` into `SleepSessionWire`, returning `nil` (never
    /// throwing) on any malformed shape -- callers treat that identically to
    /// "no session data," i.e. `.skip` (WP-07 step 5: never crash).
    static func decode(_ payload: Data) -> SleepSessionWire? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder throws -> Date in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = SleepSessionDecoding.date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unparseable ISO 8601 date: \"\(string)\""
                )
            }
            return date
        }
        return try? decoder.decode(SleepSessionWire.self, from: payload)
    }
}
