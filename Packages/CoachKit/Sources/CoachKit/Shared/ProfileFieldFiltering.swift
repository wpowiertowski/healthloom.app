// ProfileFieldFiltering.swift
// CoachKit
//
// Single definition of the exclusion rule's read side (D7/D8): every place
// that derives "which keys/fields are excluded" from a `[ProfileField]`
// goes through here, so a future second exclusion condition needs exactly
// one edit -- not the three lockstep sites this replaces
// (`KnowledgeStore` cache populate + gate cold path, `ContextAssembler`
// assembly filter; see `ContextAssembler`'s doc on the single-rule
// invariant).

import CoreModel
import Foundation

public extension Array where Element == ProfileField {
    /// Keys currently excluded from AI.
    var excludedKeys: Set<String> {
        Set(filter(\.excludedFromAI).map(\.key))
    }

    /// Fields the coach may see.
    func includedInAI() -> [ProfileField] {
        filter { !$0.excludedFromAI }
    }
}
