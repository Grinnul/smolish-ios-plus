import SwiftUI

@MainActor
final class SearchViewModel: ObservableObject {
    @Published private(set) var users: [SearchUser] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    func search(_ rawQuery: String) async {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { users = []; errorMessage = nil; return }
        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        guard !Task.isCancelled else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            users = try await APIClient.shared.searchUsers(query: query).items
            errorMessage = nil
        } catch where error is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }
}

struct SearchView: View {
    @StateObject private var model = SearchViewModel()
    @State private var query = ""
    @State private var selectedCreator: CreatorSummary?

    var body: some View {
        NavigationStack {
            Group {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView("Search Smolish", systemImage: "magnifyingglass", description: Text("Find creators by name or @handle."))
                } else if model.isLoading && model.users.isEmpty {
                    ProgressView()
                } else if let error = model.errorMessage, model.users.isEmpty {
                    ContentUnavailableView("Search failed", systemImage: "wifi.exclamationmark", description: Text(error))
                } else if model.users.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(model.users) { user in
                        Button { selectedCreator = CreatorSummary(user: user) } label: {
                            SearchUserRow(user: user)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Creators and @handles")
        }
        .task(id: query) { await model.search(query) }
        .sheet(item: $selectedCreator) { CreatorProfileView(summary: $0) }
    }
}

private struct SearchUserRow: View {
    let user: SearchUser

    var body: some View {
        HStack(spacing: 12) {
            CreatorAvatar(url: user.avatarUrl, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(user.displayName).font(.headline).lineLimit(1)
                Text("@\(user.handle)").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text("\(user.followersCount.formatted(.number.notation(.compactName))) followers")
                    Label(user.braincells.formatted(.number.notation(.compactName)), systemImage: "brain.head.profile")
                        .foregroundStyle(Color.smolishBlue)
                }
                .font(.caption)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

@MainActor
final class CreatorProfileViewModel: ObservableObject {
    @Published private(set) var videos: [SmolishVideo] = []
    @Published private(set) var isLoading = false
    @Published var following: Bool
    @Published var errorMessage: String?
    private let summary: CreatorSummary
    private var nextCursor: String?
    private var isLoadingMore = false

    init(summary: CreatorSummary) {
        self.summary = summary
        following = summary.viewerFollows
    }

    func load() async {
        guard videos.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await APIClient.shared.feed(author: summary.handle)
            videos = response.items
            nextCursor = response.nextCursor
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func loadMoreIfNeeded(current video: SmolishVideo) async {
        guard video.id == videos.last?.id, let nextCursor, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let response = try await APIClient.shared.feed(cursor: nextCursor, author: summary.handle)
            let known = Set(videos.map(\.id))
            videos.append(contentsOf: response.items.filter { !known.contains($0.id) })
            self.nextCursor = response.nextCursor
        } catch { errorMessage = error.localizedDescription }
    }

    func toggleFollow() async {
        let previous = following
        following.toggle()
        do { try await APIClient.shared.setFollowing(userID: summary.userId, following: following) }
        catch { following = previous; errorMessage = error.localizedDescription }
    }
}

struct CreatorProfileView: View {
    let summary: CreatorSummary
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionStore
    @StateObject private var model: CreatorProfileViewModel
    @State private var selectedVideo: SmolishVideo?
    @State private var showSignIn = false

    init(summary: CreatorSummary) {
        self.summary = summary
        _model = StateObject(wrappedValue: CreatorProfileViewModel(summary: summary))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 10) {
                        CreatorAvatar(url: summary.avatarURL, size: 88)
                        VStack(spacing: 2) {
                            Text(summary.displayName).font(.title2.bold())
                            Text("@\(summary.handle)").foregroundStyle(.secondary)
                        }
                        HStack(spacing: 22) {
                            metric(summary.followersCount, "Followers")
                            metric(summary.videosCount ?? model.videos.count, "Videos")
                            metric(summary.braincells, "Braincells")
                        }
                        if let bio = summary.bio, !bio.isEmpty { Text(bio).multilineTextAlignment(.center).font(.subheadline) }
                        Button {
                            guard session.isAuthenticated else { showSignIn = true; return }
                            Task { await model.toggleFollow() }
                        } label: {
                            Text(model.following ? "Following" : "Follow")
                                .font(.subheadline.bold()).frame(minWidth: 120).padding(.vertical, 9)
                                .foregroundStyle(model.following ? Color.primary : Color.white)
                                .background(model.following ? Color.clear : Color.smolishBlue, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(model.following ? Color.secondary : Color.clear))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal)

                    Divider()
                    if model.isLoading && model.videos.isEmpty { ProgressView().padding(.top, 35) }
                    else if model.videos.isEmpty {
                        ContentUnavailableView("No public videos", systemImage: "play.rectangle")
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                            ForEach(model.videos) { video in
                                Button { selectedVideo = video } label: {
                                    ZStack(alignment: .bottomLeading) {
                                        AsyncImage(url: video.thumbnail) { image in image.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.18) }
                                            .frame(maxWidth: .infinity).aspectRatio(0.72, contentMode: .fit).clipped()
                                        Label(video.viewsCount.formatted(.number.notation(.compactName)), systemImage: "play.fill")
                                            .font(.caption2.bold()).foregroundStyle(.white).padding(6).shadow(radius: 3)
                                    }
                                }
                                .buttonStyle(.plain)
                                .task { await model.loadMoreIfNeeded(current: video) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .task { await model.load() }
        .sheet(isPresented: $showSignIn) { CookieSignInView() }
        .fullScreenCover(item: $selectedVideo) { video in
            ZStack(alignment: .topTrailing) {
                VideoPageView(video: video, isActive: true, onRequiresSignIn: { showSignIn = true })
                    .ignoresSafeArea(edges: .bottom)
                Button { selectedVideo = nil } label: {
                    Image(systemName: "xmark").font(.headline).padding(12).background(.black.opacity(0.55), in: Circle())
                }
                .foregroundStyle(.white).padding()
            }
            .background(.black)
        }
        .alert("Couldn’t update profile", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "Please try again.") }
    }

    private func metric(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value.formatted(.number.notation(.compactName))).font(.headline)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct CreatorAvatar: View {
    let url: URL?
    let size: CGFloat
    var body: some View {
        AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: {
            Color.smolishBlue.opacity(0.45).overlay(Image(systemName: "person.fill").foregroundStyle(.white))
        }
        .frame(width: size, height: size).clipShape(Circle())
    }
}

extension CreatorSummary: Identifiable { var id: String { userId } }
