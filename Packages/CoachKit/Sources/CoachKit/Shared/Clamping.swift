// Clamping.swift
// CoachKit
//
// Shared integer clamping: WP-19's summary windows and WP-24's tool argument
// windows bound asked-for day/night counts the same way (`1...max`), so one
// helper serves all six call sites instead of six copies drifting
// independently. (Precedent: `ReadinessEngine.clamped(_:)` for the 0-100
// Double case.)

/// Namespace for shared clamping helpers.
public enum Clamping {
    /// Bounds an asked-for day/night window to `1...maximum`.
    public static func window(_ value: Int, maximum: Int) -> Int {
        min(max(value, 1), maximum)
    }
}
