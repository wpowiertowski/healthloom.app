// Theme.swift
//
// WP-33 (implementation-plan.md) / architecture.md D12: the Yacht club
// design tokens, ported from the locked mockups
// (`Design/HealthLoomTodayView-YachtClub.swift` +
// `Design/healthloom-final-yachtclub.html` -- palette source: Figma "Yacht
// club" #F2F0EF / #BBBDBC / #245F73 / #733E24). Deep teal serves as ink
// (primary text), rust is the single functional accent, hairline rules,
// Helvetica throughout -- Dieter Rams / Braun restraint.
//
// D12 mandates two deviations from the light-only, fixed-size mockup, both
// implemented here:
//
//  (a) **Dynamic Type** -- `Theme.font(_:weight:relativeTo:)` replaces the
//      mockup's fixed `helv(size)` with `Font.custom(_:size:relativeTo:)`,
//      so every size scales with the user's text-size setting relative to a
//      semantically-matched text style (the 60 pt hero number scales like
//      `.largeTitle`, 11 pt captions like `.caption2`, etc. -- each call
//      site picks its anchor).
//
//  (b) **Dark-mode palette variant** -- the mockup is light-only; D12:
//      "derive: canvas -> near-black warm, ink -> light teal, keep rust
//      accent, re-check >= 4.5:1 contrast." Every token below is a dynamic
//      color pair. Derived dark values, with approximate WCAG contrast
//      against the dark canvas (#201D1A, relative luminance ~0.012):
//        ink       #A8CBD8  (~9.5:1  -- primary text, comfortably AA/AAA)
//        secondary #7FA0AC  (~5.9:1)
//        tertiary  #5E7680  (~3.4:1  -- placeholders only, matching the
//                            light palette's own tertiary role: never used
//                            for essential text)
//        accent    #C98A63  (~5.7:1  -- the rust hue kept, lightened; the
//                            original #733E24 would sit near 2:1 on a
//                            near-black canvas, failing D12's re-check)
//        accentDeep #E3B999 (~8.4:1 -- labels on the dark accent tint)
//      Contrast figures are hand-computed from sRGB luminance and must be
//      re-verified in the WP-37 accessibility pass (test-plan.md §6's
//      "color-contrast check for both palettes").

import SwiftUI
import UIKit

enum Theme {
    // canvas / surface
    static let canvas = dynamic(light: 0xF2F0EF, dark: 0x201D1A)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x2A2622)

    // ink (deep teal -- doubles as primary text color)
    static let ink = dynamic(light: 0x245F73, dark: 0xA8CBD8)
    /// Muted teal-gray -- secondary text.
    static let secondary = dynamic(light: 0x5C7C87, dark: 0x7FA0AC)
    /// Light teal-gray -- placeholders.
    static let tertiary = dynamic(light: 0x96AEB5, dark: 0x5E7680)

    // structure
    /// Soft warm hairline.
    static let border = dynamic(light: 0xE3E0DC, dark: 0x3B3733)
    /// Exact palette value -- dividers/disabled.
    static let gray = dynamic(light: 0xBBBDBC, dark: 0x4C4E4D)

    // accent (rust -- the one functional color)
    static let accent = dynamic(light: 0x733E24, dark: 0xC98A63)
    /// Coach panel background.
    static let accentTint = dynamic(light: 0xEDE1DA, dark: 0x3B2B21)
    /// Icons/labels on tint.
    static let accentDeep = dynamic(light: 0x5A2F1B, dark: 0xE3B999)

    /// D12 deviation (a): the mockup's `helv(size)` with Dynamic Type
    /// scaling. `relativeTo:` anchors the custom size to a system text
    /// style so it scales proportionally with the user's setting;
    /// "Helvetica Neue" ships with iOS (the mockup's mandated face).
    static func font(
        _ size: CGFloat,
        _ weight: Font.Weight = .regular,
        relativeTo textStyle: Font.TextStyle = .body
    ) -> Font {
        Font.custom("Helvetica Neue", size: size, relativeTo: textStyle).weight(weight)
    }

    // MARK: - Private

    /// `nonisolated` is load-bearing, not tidiness. This app target sets
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` (project.yml), so a closure
    /// literal written inside a `MainActor`-isolated function inherits that
    /// isolation. UIKit resolves a `UIDynamicProviderColor` on whatever
    /// thread is rendering -- not necessarily the main one -- and under Swift
    /// 6 that mismatch is not a warning but a hard `EXC_BREAKPOINT` trap in
    /// `swift_task_checkIsolatedSwift`, crashing the app mid-render (observed
    /// via a real `xcodebuild test` run: `TodayUITests` and
    /// `OnboardingUITests` both died with `dispatch_assert_queue_fail` under
    /// `Theme.dynamic`'s closure, stack topped by
    /// `-[UIDynamicProviderColor _resolvedColorWithTraitCollection:]`).
    ///
    /// Declaring the enclosing function `nonisolated` means the closure has
    /// no ambient `MainActor` context to inherit, so it is safe to call from
    /// any thread -- exactly the reasoning HealthLoomApp.swift documents for
    /// nesting the `BGTaskScheduler` launch handler inside a `nonisolated`
    /// function rather than relying on inference.
    nonisolated private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }
}

private extension UIColor {
    /// `nonisolated` for the same reason as `Theme.dynamic` above: this
    /// initializer is called from inside that off-main dynamic-provider
    /// closure, so it must not carry the target's default `MainActor`
    /// isolation.
    nonisolated convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
