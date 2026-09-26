// Theme.swift
//
// WP-40 (implementation-plan.md) / architecture.md D16: the "Concrete
// Glass" design tokens -- Max Bill's concrete geometry for the content
// layer, Apple's Liquid Glass for the control layer
// (`Design/healthloom-bill-glass.html` is the locked mockup).
//
// D16 supersedes D12's Yacht club typography but deliberately KEEPS its
// palette. Every WP-33/WP-37 colour below is byte-identical to what
// shipped: those values carry a documented WCAG audit, and re-tinting
// them for a cosmetic warmth nudge would discard that for nothing. The
// design change comes from geometry, type and material -- not from
// moving proven colours. What D16 adds is two typefaces, one type ladder,
// and (D16.8) the mockup's four concrete fields -- held back by WP-40
// until the engine published per-signal scores (WP-43) and so could back
// a colour per signal. See `Theme.Field`.
//
// Inherited from D12, unchanged:
//
//  (a) **Dynamic Type** -- `Theme.font`/`Theme.mono` use
//      `Font.custom(_:size:relativeTo:)`, so every size scales with the
//      user's text-size setting relative to a semantically-matched text
//      style (the 46 pt hero number scales like `.largeTitle`, 9.5 pt
//      captions like `.caption2`).
//
//  (b) **Dark-mode palette variant** -- every token is a dynamic colour
//      pair. Contrast figures are hand-computed from sRGB luminance and
//      were re-verified in the WP-37 accessibility pass.

import SwiftUI
import UIKit

enum Theme {
    // canvas / surface
    static let canvas = dynamic(light: 0xF2F0EF, dark: 0x201D1A)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x2A2622)

    // ink (deep teal -- doubles as primary text color)
    static let ink = dynamic(light: 0x245F73, dark: 0xA8CBD8)
    /// Muted teal-gray -- secondary text (5.32/4.68 vs white/canvas).
    static let secondary = dynamic(light: 0x527078, dark: 0x7FA0AC)
    /// Teal-gray -- placeholders, subs, and decorative glyphs. Clears
    /// 5.28/4.64 light, 4.77/5.33 dark.
    static let tertiary = dynamic(light: 0x54707B, dark: 0x7A969D)

    // structure
    /// Soft warm hairline.
    static let border = dynamic(light: 0xE3E0DC, dark: 0x3B3733)
    /// Exact palette value -- dividers/disabled. Decorative structure, so
    /// exempt from the 3:1 non-text floor (WCAG 1.4.11 covers graphics
    /// needed to understand content; a hairline rule is not one).
    static let gray = dynamic(light: 0xBBBDBC, dark: 0x4C4E4D)

    // accent (rust -- the one functional color)
    static let accent = dynamic(light: 0x733E24, dark: 0xC98A63)
    /// Coach panel background.
    static let accentTint = dynamic(light: 0xEDE1DA, dark: 0x3B2B21)
    /// Icons/labels on tint.
    static let accentDeep = dynamic(light: 0x5A2F1B, dark: 0xE3B999)

    // MARK: - D16.8: the concrete fields

    /// The four flat, unmixed colour fields of the locked mockup (Max
    /// Bill's Konkrete Kunst fields). They only ever tell one thing from
    /// another -- one readiness signal from the next, one kind of activity
    /// from the next -- and always sit beside a label that names it, so
    /// colour is never the only carrier (WCAG 1.4.1).
    ///
    /// Rust is the accent itself. Ochre, slate and sky keep the mockup's
    /// hues but not all of its values: as drawn, ochre (light) and sky
    /// (both modes) fall below the 3:1 non-text floor against the
    /// `border` track they fill (WCAG 1.4.11 -- a bar's length is
    /// information), and the mockup's dark sky was darker than its dark
    /// slate. Lightness only was adjusted; figures are against `border`:
    ///
    ///             light               dark
    ///   rust    #733E24  6.53       #C98A63  4.10   (= `accent`)
    ///   ochre   #9D7432  3.21       #D4A860  5.38   (mockup light #B8873A, 2.43)
    ///   slate   #30464F  7.55       #6E939F  3.56   (mockup light #43626E)
    ///   sky     #56828F  3.20       #C6D5DA  7.83   (mockup #9DBBC4 1.54 / #4A6670 1.92)
    ///
    /// Slate and sky share a hue, so they are held ≥ 2.2:1 apart from each
    /// other in both modes (2.36 light, 2.20 dark) to read as two fields.
    enum Field: CaseIterable {
        case rust
        case ochre
        case slate
        case sky

        var color: Color {
            switch self {
            case .rust: return Theme.accent
            case .ochre: return Self.ochreColor
            case .slate: return Self.slateColor
            case .sky: return Self.skyColor
            }
        }

        // Built once, not per render: bars redraw on every readiness update.
        private static let ochreColor = Theme.dynamic(light: 0x9D7432, dark: 0xD4A860)
        private static let slateColor = Theme.dynamic(light: 0x30464F, dark: 0x6E939F)
        private static let skyColor = Theme.dynamic(light: 0x56828F, dark: 0xC6D5DA)
    }

    // MARK: - D16: the type scale
    //
    // Bill sized by rule, not by eye: one geometric ladder, ratio 1.25,
    // anchored at 9.5 pt. Every size in the app is a step on it. The
    // Yacht club build had drifted to 17 distinct sizes against no stated
    // system; these seven replace them. Rungs are 9.5 x 1.25^n: the first
    // six are n = 0-5 rounded to the nearest half point; `display` is
    // n = 7 (45.3) rounded up to the locked mockup's 46, and n = 6 (~36)
    // is unused. So `display` is on the ladder, one rung skipped.
    enum Step {
        /// Instrument labels, units, timestamps.
        static let micro: CGFloat = 9.5
        /// Captions, secondary body.
        static let caption: CGFloat = 12
        /// Row titles, body.
        static let body: CGFloat = 15
        /// Greeting, lead-ins.
        static let lead: CGFloat = 18.5
        /// Metric values, screen titles.
        static let value: CGFloat = 23
        /// Section heroes.
        static let hero: CGFloat = 29
        /// The readiness score.
        static let display: CGFloat = 46
    }

    /// The display face: **Archivo**, a geometric grotesque in the
    /// Akzidenz/Helvetica lineage the Ulm school actually set in. Bundled
    /// as a single variable TTF (`Resources/Fonts/Archivo.ttf`): it
    /// registers nine named instances as real faces, so `.weight()`
    /// resolves to a true cut (ArchivoRoman-Light, -Medium, ...) rather
    /// than a synthesised smear -- verified via CoreText before bundling.
    static func font(
        _ size: CGFloat,
        _ weight: Font.Weight = .regular,
        relativeTo textStyle: Font.TextStyle = .body
    ) -> Font {
        Font.custom("Archivo", size: size, relativeTo: textStyle).weight(weight)
    }

    /// The utility face: **IBM Plex Mono**, for anything that is a reading
    /// off an instrument rather than language -- units, timestamps,
    /// record counts, the uppercase section labels. Tabular by
    /// construction, which is why the metric column lines up.
    ///
    /// Nav labels are language, not silkscreen: they use `font(_:)`. Six
    /// mono uppercase tab labels overflowed their cells.
    static func mono(
        _ size: CGFloat,
        _ weight: Font.Weight = .regular,
        relativeTo textStyle: Font.TextStyle = .body
    ) -> Font {
        Font.custom("IBM Plex Mono", size: size, relativeTo: textStyle).weight(weight)
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
