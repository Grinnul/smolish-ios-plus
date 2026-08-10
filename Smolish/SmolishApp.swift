import SwiftUI

@main
struct SmolishApp: App {
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
                    notifications.startPolling(session: session)
                }
        }
    }
}
