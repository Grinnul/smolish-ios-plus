import SwiftUI

@main
struct SmolishApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = SessionStore()
    @StateObject private var notifications = NotificationCenterStore()
    @StateObject private var webAuthentication = WebAuthenticationStore()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(session)
                .environmentObject(notifications)
                .environmentObject(webAuthentication)
                .tint(.smolishBlue)
                .preferredColorScheme(.dark)
                .task {
                    await session.restore()
                    await webAuthentication.refreshBrowserSession()
                    notifications.startPolling(session: session)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await webAuthentication.refreshBrowserSession() }
                    }
                }
        }
    }
}
