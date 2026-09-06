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
// The custom tab bar (not `TabView`) is design-locked per D12: hairline
// top rule on surface, light-weight icons, ink/tertiary selection states.

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
                    TodayView()
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
        HStack {
            ForEach(HomeTab.allCases, id: \.self) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 7) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 18, weight: .light))
                        Text(tab.title)
                            .font(Theme.font(10, .medium, relativeTo: .caption2))
                    }
                    .foregroundStyle(selection == tab ? Theme.ink : Theme.tertiary)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(tab.accessibilityIdentifier)
                .accessibilityLabel("\(tab.title) tab")
                .accessibilityAddTraits(selection == tab ? [.isSelected] : [])
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 8) // sits above the home indicator's safe area
        .background(
            Theme.surface
                .overlay(Rectangle().fill(Theme.gray).frame(height: 1), alignment: .top)
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

#Preview {
    HomeView()
        .environment(AppEnvironment())
}
