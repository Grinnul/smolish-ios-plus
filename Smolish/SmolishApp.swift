import SwiftUI

@MainActor
final class Settings: ObservableObject {
    @Published var ready: Bool = false
    @Published var accent: Color = .smolishBlue
}

@main
struct SmolishApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = SessionStore()
    @StateObject private var notifications = NotificationCenterStore()
    @StateObject private var webAuthentication = WebAuthenticationStore()
    @StateObject private var settings = Settings()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(session)
                .environmentObject(notifications)
                .environmentObject(webAuthentication)
                .environmentObject(settings)
                .tint(settings.accent)
                .preferredColorScheme(.dark)
                .task {
                    await webAuthentication.restore(session: session)
                    await session.restore()
                    await webAuthentication.refreshAllAccountsIfNeeded()
                    notifications.startPolling(session: session)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await webAuthentication.refreshAllAccountsIfNeeded() }
                    }
                }
        }
    }
}
