import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var notifications: NotificationCenterStore

    var body: some View {
        TabView {
            FeedView()
                .tabItem { Label("For you", systemImage: "house.fill") }

            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }

            NotificationsView()
                .tabItem { Label("Alerts", systemImage: "bell.fill") }
                .badge(notifications.unreadCount)

            StudioView()
                .tabItem { Label("Studio", systemImage: "rectangle.stack.badge.play.fill") }

            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.fill") }
        }
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
}
