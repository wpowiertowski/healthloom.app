// UnitSettingsPanel.swift
//
// WP-79: Settings' Units panel -- one segmented row per kind of
// measurement, each bound to its own unit in `UnitSettings`.

import SwiftUI

struct UnitSettingsPanel: View {
    let settings: UnitSettings

    var body: some View {
        ThemedPanel {
            row("Weight", options: UnitSettings.weightOptions, \.weight, id: "weight")
            ThemedRowDivider()
            row("Distance", options: UnitSettings.distanceOptions, \.distance, id: "distance")
            ThemedRowDivider()
            row("Pool", options: UnitSettings.poolOptions, \.pool, id: "pool")
            ThemedRowDivider()
            row("Energy", options: UnitSettings.energyOptions, \.energy, id: "energy")
            ThemedRowDivider()
            row("Stride, bounce", options: UnitSettings.bodyLengthOptions, \.bodyLength, id: "bodyLength")
        }
    }

    private func row<Unit: RawRepresentable<String> & Hashable>(
        _ title: String,
        options: [(value: Unit, title: String)],
        _ keyPath: WritableKeyPath<UnitPreferences, Unit>,
        id: String
    ) -> some View {
        ThemedSegmentedRow(
            title: title,
            options: options,
            selection: Binding(get: { settings.preferences[keyPath: keyPath] }, set: { settings.set(keyPath, to: $0) }),
            accessibilityIdentifier: "settings.units.\(id)"
        )
    }
}
