// OnboardingScaffold.swift
//
// The Yacht club design language (Theme.swift / architecture.md D12),
// applied to onboarding.
//
// **Why this file exists / documented gap:** WP-33's brief is scoped to the
// *Today view* ("WP-33 · Today view — Yacht club design"), and it delivered
// exactly that -- `Theme`, `TickScale`, and `TodayComponents` are used by
// `Today/` and nowhere else. Onboarding was built in WP-10 as deliberately
// plain SwiftUI ("Yacht club design lands in WP-33", WelcomeView.swift's own
// note), on the assumption WP-33 would reach it. It didn't, and no other
// work package in implementation-plan.md covers it, so the first thing a new
// user saw (system SF, `.largeTitle.bold()`, centered text, a stock blue
// `.borderedProminent` button) shared no vocabulary at all with the app
// behind it. This scaffold closes that gap for the onboarding flow; the
// Data/Activities/Settings tabs remain plain and are still uncovered.
//
// **Everything here is derived from the locked mockups, not invented.** The
// geometry and roles are lifted from `Design/healthloom-final-yachtclub.html`
// + `Design/HealthLoomTodayView-YachtClub.swift` as ported in
// `Today/TodayComponents.swift`: 22 pt horizontal gutters and a 12 pt top
// inset (`TodayView`), the rust-square + "healthloom" brand mark
// (`TodayHeader`), `Theme.gray` hairline rules under the header, uppercase
// 11 pt tracked section labels (`TODAY`/`COACH`), 4 pt-radius `Theme.surface`
// panels stroked in `Theme.border` (`InstrumentPanel`/`CoachPanel`), the
// 2 pt rust attention bar (`TodayMetricRowView`'s `isPriority`), and
// Helvetica via `Theme.font(_:_:relativeTo:)` so Dynamic Type still scales
// (D12 deviation (a)). Left alignment throughout matches the mockup, which
// is left-aligned everywhere and never centers body copy.
//
// **The one genuine extension:** the mockup is a dashboard and contains no
// primary call-to-action button, so `OnboardingPrimaryButton`'s treatment
// has no direct source to copy. It is derived from the palette's own rules
// rather than borrowed from elsewhere: rust is "the one functional color"
// (Theme.swift), so the primary action is a solid `Theme.accent` fill at the
// mockup's 4 pt `--radius`, labelled in `Theme.canvas`. Using canvas as the
// label color is deliberate and works in both palettes -- near-white
// (#F2F0EF) on deep rust (#733E24) in light, near-black (#201D1A) on
// lightened rust (#C98A63) in dark -- so neither variant needs a special
// case. Flagged here as a deviation for the WP-37 accessibility pass, whose
// "color-contrast check for both palettes" should verify these two pairings
// alongside Theme.swift's own hand-computed figures.
//
// Buttons are built as plain views with `.buttonStyle(.plain)` rather than
// as a `ButtonStyle`, matching `HomeTabBar`'s existing convention in this
// codebase. Accessibility identifiers are passed *in* and applied directly
// to the `Button`/content rather than to any wrapper, per the override
// gotcha documented in WelcomeView.swift and SyncTypeRow.swift.

import SwiftUI

// MARK: - Scaffold

/// The shared frame every onboarding screen sits in: brand mark, hairline
/// rule, optional step label, title, body copy, caller-supplied content, and
/// a bottom action area.
struct OnboardingScaffold<Content: View, Actions: View>: View {
    let step: OnboardingStepIndex?
    let symbol: String?
    let title: String
    let message: String
    /// Small print rendered under `message` (WP-38: the non-medical
    /// disclaimer on the welcome step). Optional so the other steps —
    /// consent sheets with their own legal copy — stay untouched.
    let footnote: String?
    // Plain stored properties -- `@ViewBuilder` belongs on the `init`
    // parameters below (which build these), not on the storage itself.
    let content: Content
    let actions: Actions

    init(
        step: OnboardingStepIndex? = nil,
        symbol: String? = nil,
        title: String,
        message: String,
        footnote: String? = nil,
        @ViewBuilder content: () -> Content = { EmptyView() },
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.step = step
        self.symbol = symbol
        self.title = title
        self.message = message
        self.footnote = footnote
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingBrandMark()
                .padding(.top, 12)

            Rectangle().fill(Theme.gray).frame(height: 1)
                .padding(.top, 16)

            // Fixed gap, not a `Spacer`: the mockup reads strictly top-down
            // from the header rule (`TodayView` stacks greeting → rule →
            // hero → panels with fixed offsets and never vertically centers).
            // A flexible spacer here instead floated the whole block into the
            // middle of the screen, which is the one thing that still looked
            // un-Yacht-club after the palette and type were right.
            Color.clear.frame(height: 44)

            if let symbol {
                // Light-weight symbol in the single accent color -- matches
                // `HomeTabBar`'s `.system(size:weight:.light)` icon treatment
                // rather than the multicolor `.red`/`.green`/`.orange`
                // SF Symbols these screens used before, which belonged to no
                // palette in the app.
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.accent)
                    .padding(.bottom, 18)
                    .accessibilityHidden(true) // decorative; the title carries the meaning
            }

            if let step {
                Text(step.label)
                    .font(Theme.font(11, .medium, relativeTo: .caption2)).tracking(0.8)
                    .foregroundStyle(Theme.secondary)
                    .padding(.bottom, 8)
                    .accessibilityLabel(step.accessibilityLabel)
            }

            Text(title)
                .font(Theme.font(30, .light, relativeTo: .largeTitle))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text(message)
                .font(Theme.font(13.5, .regular, relativeTo: .footnote))
                .foregroundStyle(Theme.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            if let footnote {
                Text(footnote)
                    .font(Theme.font(11.5, .regular, relativeTo: .caption))
                    .foregroundStyle(Theme.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .accessibilityIdentifier("onboarding.footnote")
            }

            content

            Spacer(minLength: 20)

            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.bottom, 24)
        .background(Theme.canvas.ignoresSafeArea())
    }
}

/// `TodayHeader`'s brand mark, reused verbatim so the first screen of the app
/// and the Today view carry the identical mark.
struct OnboardingBrandMark: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Theme.accent).frame(width: 6, height: 6)
            Text("healthloom")
                .font(Theme.font(16, .medium, relativeTo: .callout))
                .foregroundStyle(Theme.ink)
        }
        .accessibilityHidden(true) // decorative brand mark, as in TodayHeader
    }
}

/// Position in the linear welcome → HealthKit → Google → first-sync flow
/// (`OnboardingFlowView`). The two dead-end branches (HK-unavailable,
/// Workspace-unsupported) deliberately carry no step label -- they are not
/// steps on the path.
enum OnboardingStepIndex: Int {
    case welcome = 1
    case healthKit = 2
    case google = 3
    case firstSync = 4

    private static let total = 4

    var label: String { "STEP \(rawValue) OF \(Self.total)" }
    /// Spelled out so VoiceOver doesn't read the tracked uppercase form.
    var accessibilityLabel: String { "Step \(rawValue) of \(Self.total)" }
}

// MARK: - Actions

/// Solid-rust primary action. See this file's header for why this treatment
/// is a derivation rather than a port.
struct OnboardingPrimaryButton: View {
    let title: String
    var isLoading = false
    var accessibilityIdentifier: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            ZStack {
                // The label stays in place (hidden) behind the spinner so the
                // button never changes height mid-request -- the previous
                // screens swapped `Text` for `ProgressView` and visibly
                // resized.
                Text(title)
                    .font(Theme.font(15, .medium, relativeTo: .callout))
                    .opacity(isLoading ? 0 : 1)
                if isLoading {
                    // Tinted `ink`, not `canvas`: while a request is in
                    // flight the button is also `.disabled`, so it is filled
                    // `Theme.gray` -- a canvas-colored spinner on that fill
                    // was very nearly invisible.
                    ProgressView()
                        .tint(Theme.ink)
                }
            }
            .foregroundStyle(isEnabled ? Theme.canvas : Theme.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(RoundedRectangle(cornerRadius: 4).fill(isEnabled ? Theme.accent : Theme.gray))
        }
        .buttonStyle(.plain)
        // `.isButton` is explicit, not decorative. `OnboardingUITests` finds
        // this control with a *typed* `app.buttons[...]` query, and swapping
        // `.borderedProminent` for `.plain` with a custom `ZStack` label was
        // enough for the iOS 27 accessibility bridge to stop reporting it as
        // a button element -- the test failed with "Welcome screen never
        // appeared" until these traits were pinned down. Collapsing the label
        // into one element also keeps the hidden `Text` behind the spinner
        // from being surfaced separately.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// Quiet secondary action: hairline-stroked surface, ink label.
struct OnboardingSecondaryButton: View {
    let title: String
    var accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.font(15, .medium, relativeTo: .callout))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
        }
        .buttonStyle(.plain)
        // Same explicit traits as `OnboardingPrimaryButton` -- see its note.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

// MARK: - Panels

/// Error surface, in-palette. The Yacht club palette has no red -- rust is
/// its only functional color (Theme.swift) -- so errors reuse `CoachPanel`'s
/// exact accent-tint panel form with an uppercase label, rather than
/// importing a system `.red` that appears nowhere else in the design.
struct OnboardingErrorPanel: View {
    let message: String
    var accessibilityIdentifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("COULDN'T CONTINUE")
                .font(Theme.font(11, .semibold, relativeTo: .caption2)).tracking(0.6)
                .foregroundStyle(Theme.accentDeep)
            Text(message)
                .font(Theme.font(13, .regular, relativeTo: .footnote))
                .foregroundStyle(Theme.ink)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.accentTint))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
