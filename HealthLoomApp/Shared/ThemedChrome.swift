// ThemedChrome.swift
//
// The Yacht club design language (Theme.swift / architecture.md D12) applied
// to every screen that isn't Today.
//
// **Why this file exists / documented gap:** WP-33's brief is scoped to the
// *Today view* ("WP-33 · Today view — Yacht club design", implementation-plan
// .md), and it delivered exactly that. Everything else -- the Data dashboard
// (WP-10/14), Activities (WP-12b), Settings (WP-17), Backfill (WP-15) and the
// Sync Log (WP-18) -- was built as stock SwiftUI `List` screens with system
// SF type, system grouped backgrounds, blue tint, green toggles and red error
// text, so switching tabs moved between two unrelated-looking apps. No work
// package in implementation-plan.md covers restyling them; `OnboardingScaffold
// .swift` closed the same gap for onboarding, and this file closes it for the
// rest.
//
// **Ported, not invented.** Geometry and roles come from the locked mockups
// (`Design/healthloom-final-yachtclub.html`, `Design/HealthLoomTodayView-
// YachtClub.swift`) as already interpreted by `Today/TodayComponents.swift`:
// 22 pt gutters and a 12 pt top inset, `Theme.gray` hairline under the
// header, uppercase 11 pt tracked section labels (`TODAY`/`COACH`), 4 pt-
// radius `Theme.surface` panels stroked in `Theme.border` with hairline
// `Theme.border` row separators (`InstrumentPanel`), the 2 pt rust attention
// bar for rows needing attention (`TodayMetricRowView`'s `isPriority`), the
// rust-tint callout panel (`CoachPanel`), 6 pt status dots (`TodayHeader`),
// and Helvetica via `Theme.font(_:_:relativeTo:)` so Dynamic Type still
// scales (D12 deviation (a)).
//
// **Status colors.** The palette has no green/red/orange/purple -- rust is
// its only functional color (Theme.swift) -- so the system status colors
// these screens used are re-mapped rather than kept: OK/fresh -> a rust dot
// (as `TodayHeader` already does for sync freshness), idle/never -> a
// `Theme.gray` dot, and *error* -> the 2 pt rust bar plus `Theme.accentDeep`
// text, which is how the design already marks a row that wants attention.
// Badge strings are unchanged -- `DashboardUITests` asserts on their exact
// labels ("Not in Apple Health", "Clinical · excluded from AI").
//
// **Navigation chrome.** Tab roots hide the system navigation bar entirely
// and draw their own header, matching `TodayView` (which has never had one).
// Pushed screens keep the bar -- inline, transparent background, rust tint --
// so the system back button *and* the interactive swipe-back gesture keep
// working; hiding it there would have traded real navigation behavior for a
// few points of empty canvas. See `ThemedScreen.Chrome`.

import SwiftUI

// MARK: - Screen scaffold

/// Whether a screen is the root of a tab or has been pushed onto a
/// `NavigationStack` -- see this file's header for why they differ. Declared
/// at file scope, not nested in the generic `ThemedScreen`, so callers can
/// name it (`ScreenChrome`) without having to spell out generic arguments.
enum ScreenChrome {
    case tabRoot
    case pushed
}

struct ThemedScreen<Actions: View, Content: View>: View {
    let title: String
    var chrome: ScreenChrome = .tabRoot
    /// Set when the screen owns its scrolling (e.g. a `List`-free custom
    /// layout that must not double-scroll).
    var isScrollable = true
    let actions: Actions
    let content: Content

    init(
        title: String,
        chrome: ScreenChrome = .tabRoot,
        isScrollable: Bool = true,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.chrome = chrome
        self.isScrollable = isScrollable
        self.actions = actions()
        self.content = content()
    }

    var body: some View {
        Group {
            if isScrollable {
                ScrollView { stack }
            } else {
                stack
            }
        }
        .background(Theme.canvas.ignoresSafeArea())
        .modifier(ThemedNavigationChrome(chrome: chrome))
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: 0) {
            ThemedHeader(title: title, topPadding: chrome == .tabRoot ? 12 : 4) {
                actions
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.bottom, 24)
    }
}

/// The title + actions row and its `Theme.gray` hairline, on its own so
/// screens that can't be a `ThemedScreen` still get the identical header.
/// `TodayMetricsEditor` uses it directly: that sheet's body is a `List`
/// (its `EditMode` reorder handles are the whole point of the screen), which
/// must keep its own row insets rather than sit inside `ThemedScreen`'s
/// 22 pt gutter -- so it applies the gutter to this header alone.
///
/// Callers supply their own horizontal padding; this view adds none.
struct ThemedHeader<Actions: View>: View {
    let title: String
    var topPadding: CGFloat = 12
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(Theme.font(26, .light, relativeTo: .title))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 12)
                HStack(spacing: 18) { actions }
            }
            .padding(.top, topPadding)

            Rectangle().fill(Theme.gray).frame(height: 1)
                .padding(.top, 14)
        }
    }
}

/// Convenience for the majority of screens, which have no header actions.
/// A defaulted `actions:` parameter on the main `init` is rejected -- Swift
/// can't use a default expression to infer `Actions` when it is also
/// inferrable from the other parameters -- so this is a separate overload.
extension ThemedScreen where Actions == EmptyView {
    init(
        title: String,
        chrome: ScreenChrome = .tabRoot,
        isScrollable: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            chrome: chrome,
            isScrollable: isScrollable,
            actions: { EmptyView() },
            content: content
        )
    }
}

/// Split out as a `ViewModifier` because `.toolbar(.hidden,...)` and the
/// inline/transparent-bar combination can't both live in one `if` branch of a
/// `some View` body without erasing the type.
private struct ThemedNavigationChrome: ViewModifier {
    let chrome: ScreenChrome

    func body(content: Content) -> some View {
        switch chrome {
        case .tabRoot:
            content.toolbar(.hidden, for: .navigationBar)
        case .pushed:
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .tint(Theme.accent)
        }
    }
}

// MARK: - Structure

/// `TodayView`'s uppercase tracked section label (its `TODAY` header).
struct ThemedSectionHeader: View {
    let title: String
    var topPadding: CGFloat = 22

    var body: some View {
        Text(title.uppercased())
            .font(Theme.font(11, .medium, relativeTo: .caption2)).tracking(0.8)
            .foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, topPadding)
            .padding(.bottom, 10)
    }
}

/// `InstrumentPanel`'s surface panel: 4 pt radius, `Theme.border` stroke,
/// hairline-separated rows. Callers lay rows out in a `VStack(spacing: 0)`
/// and put `ThemedRowDivider()` between them.
struct ThemedPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
    }
}

struct ThemedRowDivider: View {
    var body: some View {
        Rectangle().fill(Theme.border).frame(height: 1)
    }
}

/// `CoachPanel`'s rust-tint callout, used for the informational blurbs these
/// screens previously rendered as plain secondary footnotes.
struct ThemedCallout: View {
    let title: String
    let message: String
    var accessibilityIdentifier: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
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
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
    }
}

// MARK: - Row furniture

/// The 6 pt status dot `TodayHeader` uses for sync freshness, generalised.
/// There is deliberately no red/green here -- see this file's header.
struct ThemedStatusDot: View {
    enum Kind { case active, idle }

    let kind: Kind

    var body: some View {
        Circle()
            .fill(kind == .active ? Theme.accent : Theme.gray)
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
    }
}

/// Hairline-stroked pill. `.neutral` reads as quiet metadata; `.accent`
/// borrows `CoachPanel`'s rust tint for the clinical marker.
struct ThemedBadge: View {
    enum Style { case neutral, accent }

    let text: String
    var style: Style = .neutral
    var accessibilityIdentifier: String?

    var body: some View {
        Text(text)
            .font(Theme.font(10.5, .medium, relativeTo: .caption2))
            .foregroundStyle(style == .accent ? Theme.accentDeep : Theme.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(style == .accent ? Theme.accentTint : Color.clear)
            )
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.border))
            .accessibilityIdentifier(accessibilityIdentifier ?? "")
    }
}

/// Error text in `Theme.accentDeep`. Rows that use this should also show the
/// 2 pt rust bar (`ThemedAttentionBar`) so the state is not carried by color
/// alone -- an accessibility requirement the previous red text didn't meet
/// either, and one WP-37's audit should confirm.
struct ThemedErrorText: View {
    let message: String
    var accessibilityIdentifier: String

    var body: some View {
        Text(message)
            .font(Theme.font(12, .regular, relativeTo: .caption))
            .foregroundStyle(Theme.accentDeep)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// `TodayMetricRowView`'s `isPriority` bar, as a reusable leading marker.
struct ThemedAttentionBar: View {
    var body: some View {
        Rectangle().fill(Theme.accent).frame(width: 2).frame(maxHeight: .infinity)
            .accessibilityHidden(true)
    }
}

/// Toolbar-style icon button for the themed headers (the design's tab bar
/// uses `.light`-weight symbols in ink; these match).
struct ThemedIconButton: View {
    let systemImage: String
    var accessibilityLabel: String
    var accessibilityIdentifier: String
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isBusy {
                    ProgressView().tint(Theme.ink)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(Theme.ink)
                }
            }
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// Panel row that pushes a destination: ink label, tertiary chevron.
struct ThemedNavRow<Destination: View>: View {
    let title: String
    var accessibilityIdentifier: String
    @ViewBuilder var destination: Destination

    var body: some View {
        NavigationLink(destination: destination) {
            HStack {
                Text(title)
                    .font(Theme.font(14, .medium, relativeTo: .subheadline))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .light))
                    .foregroundStyle(Theme.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// Toggle row on a panel. `.tint(Theme.accent)` replaces the system green.
struct ThemedToggleRow: View {
    let title: String
    var isBusy = false
    var accessibilityIdentifier: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 8) {
                Text(title)
                    .font(Theme.font(14, .medium, relativeTo: .subheadline))
                    .foregroundStyle(Theme.ink)
                if isBusy {
                    ProgressView().controlSize(.mini).tint(Theme.accent)
                }
            }
        }
        .tint(Theme.accent)
        .padding(.horizontal, 16).padding(.vertical, 11)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
