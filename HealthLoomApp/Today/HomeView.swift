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
// every `tabbar.*` accessibility identifier survives, and it stays IN
// FLOW (this `VStack`) rather than floating in `.safeAreaInset`.
//
// Floating it was tried and reverted. `.safeAreaInset(edge: .bottom)` is
// what would let scrolling content pass beneath the capsule so the glass
// refracts it, but the outer inset does not reach through the
// `NavigationStack` each non-Today tab wraps itself in: those screens
// kept claiming full height, the capsule covered whatever they pinned to
// the bottom, and Coach's `input.tap()` landed on the You tab underneath
// it (the failure dump showed `tabbar.you` Selected while the test still
// asked for `chat.input`). Today, the one tab with no `NavigationStack`,
// was unaffected -- which is what identified the cause.
//
// So the bar is glass over the canvas, not over moving content. Getting
// true refraction needs the tab shell to own one `NavigationStack`
// instead of six, which is a navigation change, not a design one -- see
// implementation-plan.md WP-40's follow-up.

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

    init(initialTab: HomeTab = .today) {
        _selection = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch selection {
                case .today:
                    // WP-34 F2: the coach panel's chevron opens the Coach
                    // tab — selection lives here, so the closure bridges
                    // the gap `TodayView` cannot cross alone.
                    TodayView(onOpenCoach: { selection = .coach })
                case .coach:
                    CoachChatView(viewModel: appEnvironment.coachChatViewModel)
                case .you:
                    NavigationStack { YouView(viewModel: appEnvironment.youViewModel()) }
                case .data:
                    // DashboardView owns its own NavigationStack (WP-10).
                    DashboardView()
                case .activities:
                    NavigationStack { ActivitiesView() }
                case .settings:
                    NavigationStack { SettingsView() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HomeTabBar(selection: $selection)
        }
        .background(Theme.canvas.ignoresSafeArea())
        // Applied at the shell so every pushed screen's system navigation
        // chrome (the back chevron in particular) picks up the palette's
        // accent instead of the stock blue -- a `.tint` inside an individual
        // screen's body does not reach the navigation bar hosting it.
        .tint(Theme.accent)
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
        // behind it, which in flow is the canvas rather than moving content
        // (see the header for why). The capsule is the concentric shape
        // iOS 26 expects a bar to take.
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }
}

#Preview {
    HomeView()
        .environment(AppEnvironment())
}
