// LocalKnowledgeReader.swift
//
// WP-70: the in-app (`LocalSample`) half of `KnowledgeStore.refresh()`, on a
// background context. The refresh used to fetch every local sample in its
// window on the main actor and decode their payloads there -- a month of
// per-minute Active Minutes is tens of thousands of rows (0.4 s on the
// simulator, more on a phone), felt as a stutter whenever the hourly
// refresh fired. The reader returns plain values; the store keeps the
// merge and the save on its own actor.

import CoreModel
import Foundation
import SwiftData

@ModelActor
actor LocalKnowledgeReader {
    struct Result: Sendable {
        /// Fitbit exercise sessions in the workouts window.
        var exerciseSupplements: [ExerciseSupplement]
        /// One field per local-only type with samples in its window.
        var localOnlyFields: [ProfileField]
    }

    /// Fetch failures propagate: reading "no samples" on a failed fetch
    /// would erase the previously derived local-only fields on save.
    func read(
        exerciseSince: Date,
        localOnlySince: Date,
        now: Date,
        localOnlyTypes: [GoogleDataType],
        windowDays: Int
    ) throws -> Result {
        let exercise = GoogleDataType.exercise.rawValue
        let sessions = try modelContext.fetch(FetchDescriptor<LocalSample>(
            predicate: #Predicate { $0.dataType == exercise && $0.start >= exerciseSince && $0.start <= now }
        ))
        var fields: [ProfileField] = []
        for type in localOnlyTypes {
            let key = type.rawValue
            let samples = try modelContext.fetch(FetchDescriptor<LocalSample>(
                predicate: #Predicate { $0.dataType == key && $0.start >= localOnlySince && $0.start <= now }
            ))
            if let field = KnowledgeDerivation.localOnlyField(
                dataType: type, samples: samples, windowStart: localOnlySince, windowDays: windowDays, asOf: now
            ) {
                fields.append(field)
            }
        }
        return Result(exerciseSupplements: sessions.map(ExerciseSupplement.init(sample:)), localOnlyFields: fields)
    }
}
