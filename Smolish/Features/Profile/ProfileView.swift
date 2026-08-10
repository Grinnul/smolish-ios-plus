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
                        .id(profile.id ?? profile.handle ?? profile.displayNameText)
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
    @State private var showAccountSwitcher = false

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

                    Button {
                        showAccountSwitcher = true
                    } label: {
                        Label("Switch Smolish account", systemImage: "person.2")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
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
        .task {
            if let handle = profile.handle { await model.load(handle: handle) }
            await webAuthentication.loadAccounts()
        }
        .sheet(isPresented: $showAccountSwitcher) {
            SmolishAccountSwitcherView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
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
        ZStack {
            LinearGradient(colors: [.smolishBlue.opacity(0.55), .purple.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let bannerURL = profile.bannerUrl {
                AsyncImage(url: bannerURL) { image in
                    image.resizable().scaledToFit()
                } placeholder: { ProgressView() }
            }
        }
        .frame(maxWidth: .infinity).frame(height: 104).clipped()
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

struct SmolishAccountSwitcherView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var webAuthentication: WebAuthenticationStore
    @State private var showAddAccount = false

    var body: some View {
        NavigationStack {
            ZStack {
                PersistentWebView(store: webAuthentication)
                    .frame(width: 2, height: 2)
                    .opacity(0.01)
                    .allowsHitTesting(false)

                if webAuthentication.isLoadingAccounts && webAuthentication.accounts.isEmpty {
                    ProgressView("Loading your accounts…")
                } else if webAuthentication.accounts.isEmpty {
                    VStack(spacing: 18) {
                        ContentUnavailableView(
                            "No additional accounts",
                            systemImage: "person.2",
                            description: Text("Connect another Smolish account to switch between them here.")
                        )
                        Button {
                            showAddAccount = true
                        } label: {
                            Label("Add another account", systemImage: "person.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        Section {
                            ForEach(webAuthentication.accounts) { account in
                                Button {
                                    Task {
                                        if await webAuthentication.switchAccount(account) { dismiss() }
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        CreatorAvatar(url: account.avatarUrl, size: 44)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(account.displayName).font(.headline)
                                            Text(account.handle.map { "@\($0)" } ?? "No Smolish profile yet")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if webAuthentication.switchingAccountToken == account.sessionToken {
                                            ProgressView()
                                        } else if account.active {
                                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.smolishBlue)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(account.active || webAuthentication.switchingAccountToken != nil)
                            }
                        }
                        Section {
                            Button {
                                showAddAccount = true
                            } label: {
                                Label("Add another account", systemImage: "person.badge.plus")
                                    .font(.headline).foregroundStyle(Color.smolishBlue)
                            }
                            .disabled(webAuthentication.accounts.count >= 10)
                        } footer: {
                            Text(webAuthentication.accounts.count >= 10
                                 ? "Smolish allows up to 10 connected accounts."
                                 : "Stay signed in and switch without entering your password again.")
                        }
                    }
                }
            }
            .navigationTitle("Switch account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Refresh") { Task { await webAuthentication.loadAccounts() } }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .task { await webAuthentication.loadAccounts() }
        .sheet(isPresented: $showAddAccount, onDismiss: {
            Task { await webAuthentication.loadAccounts() }
        }) {
            WebSignInView(mode: .addAccount)
        }
        .alert("Couldn’t switch account", isPresented: Binding(
            get: { webAuthentication.errorMessage != nil },
            set: { if !$0 { webAuthentication.errorMessage = nil } }
        )) { Button("OK", role: .cancel) {} } message: {
            Text(webAuthentication.errorMessage ?? "Please try again.")
        }
    }
}

enum WebSignInMode: Equatable {
    case initial
    case addAccount
}

struct WebSignInView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var webAuthentication: WebAuthenticationStore
    @State private var hasStarted = false
    let mode: WebSignInMode

    init(mode: WebSignInMode = .initial) {
        self.mode = mode
    }

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
                        Text(mode == .addAccount ? "Add another account" : "Connect your Smolish account").font(.title2.bold())
                        Text(mode == .addAccount
                             ? "We’ll open Smolish Search. Tap the profile icon, choose Switch account, then use Add to sign in with Google, email, or your preferred method."
                             : "We’ll open the Smolish Search page. Tap the profile icon on the website, then sign in using Google, email, or your preferred method. Once Smolish confirms the login, you’ll return here automatically.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Label("Your password stays on smolish.com", systemImage: "lock.shield")
                            .font(.footnote.weight(.medium)).foregroundStyle(.green)
                        Button("Open Smolish Search") {
                            Task {
                                if mode == .addAccount {
                                    await webAuthentication.startAddingAccount(session: session)
                                } else {
                                    webAuthentication.start(session: session)
                                }
                                webAuthentication.onSignIn = { dismiss() }
                                hasStarted = true
                            }
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
            if mode == .initial {
                webAuthentication.onSignIn = { dismiss() }
            } else {
                webAuthentication.onSignIn = nil
            }
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
