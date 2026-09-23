// HomeView.swift
//
// WP-33 (implementation-plan.md) / architecture.md D12: the app shell --
// the Yacht club tab bar from the mockup
// (`Design/HealthLoomTodayView-YachtClub.swift`'s `TabBar`), hosting the
// Today view alongside the app's existing screens.
//
// **Documented deviation from the mockup's tab set:** the design shows
// today / coach / you / settings. Coach (WP-25) and You (WP-30) now ship
// in their real tab slots; Data (the WP-10 sync dashboard) and Activities
// (WP-12b) are additive app surfaces, using the same tab-bar component.
//
// WP-40 / D16: the bar is now Liquid Glass -- a detached capsule rather
// than a hairline-ruled slab. It stays a custom bar (not `TabView`) so
// every `tabbar.*` accessibility identifier survives.
//
// The capsule floats over every screen -- tab roots and pushed screens
// alike -- so scrolling content passes beneath it and the glass refracts
// that content rather than a static canvas. Content is never trapped
// under it: the shell measures the bar and hands its height down as
// `tabBarClearance`, which `ThemedScreen`, `TodayView` and `WipeFlowView`
// reserve as bottom safe area (`.clearsTabBar()`). A scroll view can
// therefore always scroll its last row above the bar, and a fixed layout
// (Coach's input) ends above it.
//
// Why an overlay plus an explicit clearance, not `.safeAreaInset`: an
// inset applied outside a `NavigationStack` never reaches the content
// inside it (measured, PR #52 -- with five per-tab stacks or one; WP-40's
// attempt failed the same way, Coach's `input.tap()` landing on the tab
// underneath). Applied inside, on the root, it works but makes the bar
// part of the root screen, so it disappears on every push. The
// environment value crosses the stack boundary where the inset cannot.
//
// Keyboard: the bar is keyboard-avoiding like the rest of the shell, so
// with the keyboard up it sits on top of it and the clearance keeps the
// focused field above the bar -- the same arrangement as the WP-40 in-flow
// bar.

import SwiftUI

enum HomeTab: CaseIterable {
    case today
    case coach
    case you
    case data
    case activities
    case settings

    var title: String {
        switch self {
        case .today: return "Today"
        case .coach: return "Coach"
        case .you: return "You"
        case .data: return "Data"
        case .activities: return "Activities"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .today: return "square.split.1x2"
        case .coach: return "message"
        case .you: return "person"
        case .data: return "arrow.triangle.2.circlepath"
        case .activities: return "figure.run"
        case .settings: return "slider.horizontal.3"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .today: return "tabbar.today"
        case .coach: return "tabbar.coach"
        case .you: return "tabbar.you"
        case .data: return "tabbar.data"
        case .activities: return "tabbar.activities"
        case .settings: return "tabbar.settings"
        }
    }
}

struct HomeView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @State private var selection: HomeTab
    /// The floating bar's measured height -- see `tabBarClearance`.
    @State private var tabBarHeight: CGFloat = 0

    init(initialTab: HomeTab = .today) {
        _selection = State(initialValue: initialTab)
    }

    var body: some View {
        NavigationStack {
            tabRoot
        }
        // Keyed on the tab: switching tabs replaces the stack, which pops
        // anything pushed. That is the behaviour the per-tab stacks had
        // (each was destroyed with its tab), and without it a screen pushed
        // from Data would stay on top after switching to Activities.
        .id(selection)
        // Set on the stack so pushed destinations inherit it too.
        .environment(\.tabBarClearance, tabBarHeight)
        .overlay(alignment: .bottom) {
            HomeTabBar(selection: $selection)
                // Measured, not a constant: the labels scale with Dynamic
                // Type, and a fixed clearance would under-reserve at AX sizes.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { tabBarHeight = $0 }
        }
        .background(Theme.canvas.ignoresSafeArea())
        // Applied at the shell so every pushed screen's system navigation
        // chrome (the back chevron in particular) picks up the palette's
        // accent instead of the stock blue -- a `.tint` inside an individual
        // screen's body does not reach the navigation bar hosting it.
        .tint(Theme.accent)
    }

    /// The selected tab's root screen. None of them creates a
    /// `NavigationStack` -- the shell's is the only one (see the header).
    @ViewBuilder
    private var tabRoot: some View {
        switch selection {
        case .today:
            // WP-34 F2: the coach panel's chevron opens the Coach
            // tab — selection lives here, so the closure bridges
            // the gap `TodayView` cannot cross alone.
            TodayView(onOpenCoach: { selection = .coach })
        case .coach:
            CoachChatView(viewModel: appEnvironment.coachChatViewModel)
        case .you:
            YouView(viewModel: appEnvironment.youViewModel())
        case .data:
            DashboardView()
        case .activities:
            ActivitiesView()
        case .settings:
            SettingsView()
        }
    }
}

struct HomeTabBar: View {
    @Binding var selection: HomeTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(HomeTab.allCases, id: \.self) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 17, weight: .light))
                            // Decorative inside an already-labeled button —
                            // hiding keeps VoiceOver to one stop per tab
                            // (and keeps small glyph frames out of audits).
                            .accessibilityHidden(true)
                        // Nav labels are language, not instrument silkscreen:
                        // display face, sentence case, no tracking. Six mono
                        // uppercase labels do not fit six ~61pt cells.
                        Text(tab.title)
                            .font(Theme.font(Theme.Step.micro, .medium, relativeTo: .caption2))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(selection == tab ? Theme.accent : Theme.tertiary)
                    // Audit-clean 44pt+ touch target (test plan §6).
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(tab.accessibilityIdentifier)
                .accessibilityLabel("\(tab.title) tab")
                .accessibilityAddTraits(selection == tab ? [.isSelected] : [])
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        // Sits above the home indicator's safe area.
        .padding(.bottom, 2)
        // D16's control layer. `.glassEffect` is the real material, not a
        // blur imitation -- it adapts to and specular-lights whatever sits
        // behind it, which (floating over the shell's stack) is the content
        // scrolling beneath it. The capsule is the concentric shape iOS 26
        // expects a bar to take.
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }
}

#Preview {
    HomeView()
        .environment(AppEnvironment())
}
