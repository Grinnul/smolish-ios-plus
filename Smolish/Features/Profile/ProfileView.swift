import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var webAuthentication: WebAuthenticationStore
    @State private var showCookieEntry = false
    @State private var showWebSignIn = false

    var body: some View {
        NavigationStack {
            Group {
                if let profile = session.profile {
                    MySmolishProfileView(profile: profile)
                } else {
                    VStack(spacing: 22) {
                        SmolishLogo(size: 72)
                        Text("Your Smolish profile").font(.title2.bold())
                        Text("Sign in on the real Smolish website. V2 captures the complete browser session and exact User-Agent automatically.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 28)
                        Button("Sign in with Smolish") { showWebSignIn = true }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        Button("Use V1 manual cookie fallback") { showCookieEntry = true }
                            .font(.footnote)
                        if let error = session.authenticationError {
                            Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal)
                        }
                    }
                }
            }
            .navigationTitle("Profile")
            .sheet(isPresented: $showCookieEntry) { CookieSignInView() }
            .sheet(isPresented: $showWebSignIn) { WebSignInView() }
        }
    }
}

@MainActor
final class MyProfileViewModel: ObservableObject {
    @Published private(set) var videos: [SmolishVideo] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    private var nextCursor: String?
    private var isLoadingMore = false

    func load(handle: String) async {
        guard videos.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await APIClient.shared.feed(author: handle)
            videos = response.items
            nextCursor = response.nextCursor
        } catch { errorMessage = error.localizedDescription }
    }

    func loadMoreIfNeeded(current video: SmolishVideo, handle: String) async {
        guard video.id == videos.last?.id, let nextCursor, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let response = try await APIClient.shared.feed(cursor: nextCursor, author: handle)
            let known = Set(videos.map(\.id))
            videos.append(contentsOf: response.items.filter { !known.contains($0.id) })
            self.nextCursor = response.nextCursor
        } catch { errorMessage = error.localizedDescription }
    }
}

struct MySmolishProfileView: View {
    let profile: SmolishProfile
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var webAuthentication: WebAuthenticationStore
    @StateObject private var model = MyProfileViewModel()
    @State private var selectedVideo: SmolishVideo?

    private var shareURL: URL? {
        profile.handle.flatMap { URL(string: "https://smolish.com/@\($0)") }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                banner
                VStack(spacing: 14) {
                    CreatorAvatar(url: profile.displayAvatar, size: 92)
                        .overlay(Circle().stroke(Color.smolishBlack, lineWidth: 4))
                        .padding(.top, -48)

                    VStack(spacing: 3) {
                        Text(profile.displayNameText).font(.title2.bold())
                        if let handle = profile.handle {
                            Text("@\(handle)").foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 24) {
                        metric(profile.followingCount, "Following")
                        metric(profile.followersCount, "Followers")
                        braincellsMetric
                    }

                    if let bio = profile.bio, !bio.isEmpty {
                        Text(bio).font(.subheadline).multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }

                    HStack(spacing: 10) {
                        if let shareURL {
                            ShareLink(item: shareURL) {
                                Label("Share profile", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Menu {
                            Button("Refresh profile", systemImage: "arrow.clockwise") {
                                Task { await session.verifyStoredCookie() }
                            }
                            Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                                session.signOut()
                                Task { await webAuthentication.clearWebSession() }
                            }
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 42, height: 34)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 18)

                Divider()
                HStack {
                    Label("Videos", systemImage: "play.rectangle")
                        .font(.headline)
                    Spacer()
                    Text((profile.videosCount > 0 ? profile.videosCount : model.videos.count).formatted())
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding()

                if model.isLoading && model.videos.isEmpty {
                    ProgressView().padding(.vertical, 42)
                } else if model.videos.isEmpty {
                    ContentUnavailableView("No public videos", systemImage: "play.rectangle")
                        .padding(.vertical, 28)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                        ForEach(model.videos) { video in
                            Button { selectedVideo = video } label: {
                                ZStack(alignment: .bottomLeading) {
                                    AsyncImage(url: video.thumbnail) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: { Color.secondary.opacity(0.16) }
                                    .frame(maxWidth: .infinity).aspectRatio(0.72, contentMode: .fit).clipped()
                                    HStack(spacing: 4) {
                                        Image(systemName: "play.fill")
                                        Text(video.viewsCount.formatted(.number.notation(.compactName)))
                                    }
                                    .font(.caption2.bold()).foregroundStyle(.white).padding(6).shadow(radius: 3)
                                }
                            }
                            .buttonStyle(.plain)
                            .task {
                                if let handle = profile.handle {
                                    await model.loadMoreIfNeeded(current: video, handle: handle)
                                }
                            }
                        }
                    }
                }
            }
        }
        .background(Color.smolishBlack)
        .task { if let handle = profile.handle { await model.load(handle: handle) } }
        .fullScreenCover(item: $selectedVideo) { video in
            ZStack(alignment: .topTrailing) {
                VideoPageView(video: video, isActive: true, onRequiresSignIn: {})
                    .ignoresSafeArea(edges: .bottom)
                Button { selectedVideo = nil } label: {
                    Image(systemName: "xmark").font(.headline).padding(12).background(.black.opacity(0.55), in: Circle())
                }
                .foregroundStyle(.white).padding()
            }
            .background(.black)
        }
        .alert("Couldn’t load videos", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(model.errorMessage ?? "Please try again.") }
    }

    private var banner: some View {
        AsyncImage(url: profile.bannerUrl) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            LinearGradient(colors: [.smolishBlue.opacity(0.85), .purple.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .frame(maxWidth: .infinity).frame(height: 150).clipped()
    }

    private var braincellsMetric: some View {
        VStack(spacing: 2) {
            Label(profile.braincells.formatted(.number.notation(.compactName)), systemImage: "brain.head.profile")
                .font(.headline).foregroundStyle(Color.smolishBlue)
            Text(profile.braincellsProvisional ? "Braincells*" : "Braincells")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func metric(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value.formatted(.number.notation(.compactName))).font(.headline)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct WebSignInView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var webAuthentication: WebAuthenticationStore
    @State private var hasStarted = false

    var body: some View {
        NavigationStack {
            Group {
                if hasStarted {
                    ZStack(alignment: .top) {
                        PersistentWebView(store: webAuthentication)
                            .ignoresSafeArea(edges: .bottom)

                        if webAuthentication.isLoading {
                            ProgressView().padding(10).background(.ultraThinMaterial, in: Capsule()).padding(.top, 8)
                        }

                        VStack {
                            Spacer()
                            Text(webAuthentication.statusMessage)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(.bottom, 12)
                        }

                        if let error = webAuthentication.errorMessage {
                            Text(error)
                                .font(.caption).foregroundStyle(.white)
                                .padding(10).background(.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
                                .padding()
                        }
                    }
                } else {
                    VStack(spacing: 22) {
                        SmolishLogo(size: 76)
                        Text("Connect your Smolish account").font(.title2.bold())
                        Text("We’ll open the Smolish Search page. Tap the profile icon on the website, then sign in using Google, email, or your preferred method. Once Smolish confirms the login, you’ll return here automatically.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Label("Your password stays on smolish.com", systemImage: "lock.shield")
                            .font(.footnote.weight(.medium)).foregroundStyle(.green)
                        Button("Open Smolish Search") {
                            hasStarted = true
                            webAuthentication.start(session: session)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    }
                    .padding(30)
                }
            }
            .navigationTitle("Sign in to Smolish")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if hasStarted {
                        Button { webAuthentication.goBack() } label: { Image(systemName: "chevron.left") }
                            .disabled(!webAuthentication.webView.canGoBack)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if hasStarted { Button { webAuthentication.reload() } label: { Image(systemName: "arrow.clockwise") } }
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear {
            webAuthentication.onSignIn = { dismiss() }
        }
        .onDisappear {
            webAuthentication.stopPolling()
            webAuthentication.onSignIn = nil
        }
        .interactiveDismissDisabled(webAuthentication.isCheckingSession)
    }
}

struct CookieSignInView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionStore
    @State private var cookie = ""
    @State private var userAgent = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                SmolishLogo(size: 76)
                Text("Connect your account")
                    .font(.title.bold())
                Text("Paste the complete Cookie request header. For Cloudflare-protected actions, also paste navigator.userAgent from the same browser session.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                TextField("better-auth.session_token=…", text: $cookie, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(3...6)
                    .padding()
                    .background(.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal)
                TextField("Browser User-Agent (required)", text: $userAgent, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(2...4)
                    .padding()
                    .background(.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal)
                Button(session.isChecking ? "Checking…" : "Save and verify") {
                    Task { if await session.authenticate(cookie: cookie, userAgent: userAgent) { dismiss() } }
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(cookie.isEmpty || userAgent.isEmpty || session.isChecking)
                if let error = session.authenticationError {
                    Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.smolishBlack)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}
