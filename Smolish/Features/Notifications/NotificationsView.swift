import SwiftUI

@MainActor
final class NotificationCenterStore: ObservableObject {
    @Published private(set) var unreadCount = 0
    @Published private(set) var items: [SmolishNotification] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private var pollingTask: Task<Void, Never>?

    func startPolling(session: SessionStore) {
        pollingTask?.cancel()
        pollingTask = Task {
            while !Task.isCancelled {
                await refresh(session: session)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func refresh(session: SessionStore) async {
        guard session.isAuthenticated else {
            unreadCount = 0
            items = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            async let count = APIClient.shared.unreadNotificationCount()
            async let page = APIClient.shared.notifications()
            unreadCount = try await count
            items = try await page.items
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func markAllRead() async {
        do {
            try await APIClient.shared.markAllNotificationsRead()
            unreadCount = 0
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct NotificationsView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var settings = Settings()
    @EnvironmentObject private var notifications: NotificationCenterStore

    var body: some View {
        NavigationStack {
            Group {
                if !session.isAuthenticated {
                    ContentUnavailableView(
                        "Sign in to see notifications",
                        systemImage: "bell.slash",
                        description: Text("Add your Smolish cookie from the Profile tab.")
                    )
                } else if notifications.isLoading && notifications.items.isEmpty {
                    ProgressView()
                } else if notifications.items.isEmpty {
                    ContentUnavailableView("No notifications", systemImage: "bell")
                } else {
                    List(notifications.items) { item in
                        HStack(alignment: .top, spacing: 12) {
                            AsyncImage(url: item.actorAvatar) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                settings.accent.overlay(Image(systemName: "bell.fill"))
                            }
                            .frame(width: 44, height: 44)
                            .clipShape(Circle())

                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.displayTitle).font(.subheadline.weight(item.isUnread ? .bold : .regular))
                                if let body = item.displayBody {
                                    Text(body).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                                }
                                if let date = item.createdAt {
                                    Text(date, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            if item.isUnread {
                                Circle().fill(settings.accent).frame(width: 8, height: 8).padding(.top, 6)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .refreshable { await notifications.refresh(session: session) }
                }
            }
            .navigationTitle("Notifications")
            .toolbar {
                if notifications.unreadCount > 0 {
                    Button("Mark all read") { Task { await notifications.markAllRead() } }
                }
            }
        }
        .task(id: session.accountRevision) {
            notifications.startPolling(session: session)
            await notifications.refresh(session: session)
        }
    }
}
