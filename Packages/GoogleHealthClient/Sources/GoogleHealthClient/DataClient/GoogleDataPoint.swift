// GoogleDataPoint.swift
//
// WP-05 step 2 (implementation-plan.md): the flat shape every Google Health
// API data point decodes into, regardless of source data type. Decoding the
// wire format (`<data_type>.<field>` keys nested in a `value` object,
// base-knowledge.md §2) into this shape is `GoogleHealthClient`'s job (see
// `GoogleHealthClient.swift`'s `decodeDataPoint`).

import CoreModel
import Foundation

nonisolated public struct GoogleDataPoint: Sendable, Hashable {
    public var id: String
    public var dataType: GoogleDataType
    public var start: Date
    public var end: Date
    public var source: DataSource

    /// Scalar numeric fields, keyed by the *unqualified* field name (the
    /// `<data_type>.` prefix from the wire format is stripped -- e.g. wire
    /// key `"steps.count"` becomes `values["count"]`). Unit-normalized per
    /// `GoogleDataTypeSchema` (WP-51) before this struct is constructed.
    public var values: [String: Double]

    /// Raw re-serialized JSON of the wire format's `value` object, present
    /// only when at least one of its fields is a non-scalar structure (sleep
    /// stage segments, exercise sub-structures, ...). `TypeMapper` (SyncKit,
    /// WP-07/11/12) is responsible for interpreting this payload per data
    /// type; this package only preserves it verbatim.
    public var sessionPayload: Data?

    public init(
        id: String,
        dataType: GoogleDataType,
        start: Date,
        end: Date,
        source: DataSource,
        values: [String: Double],
        sessionPayload: Data? = nil
    ) {
        self.id = id
        self.dataType = dataType
        self.start = start
        self.end = end
        self.source = source
        self.values = values
        self.sessionPayload = sessionPayload
    }
}
