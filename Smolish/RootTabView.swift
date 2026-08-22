import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var notifications: NotificationCenterStore
    @State private var selectedTab = Tab.feed
    @EnvironmentObject private var settings: Settings

    private enum Tab: Hashable { case feed, search, alerts, studio, profile }
    
    var body: some View {
        TabView(selection: $selectedTab) {
            FeedView(isTabActive: selectedTab == .feed)
                .tabItem { Label("For you", systemImage: "house.fill") }
                .tag(Tab.feed)

            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(Tab.search)

            NotificationsView()
                .tabItem { Label("Alerts", systemImage: "bell.fill") }
                .badge(notifications.unreadCount)
                .tag(Tab.alerts)

            StudioView()
                .tabItem { Label("Studio", systemImage: "rectangle.stack.badge.play.fill") }
                .tag(Tab.studio)

            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.fill") }
                .tag(Tab.profile)
        }
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)

        }
    }

