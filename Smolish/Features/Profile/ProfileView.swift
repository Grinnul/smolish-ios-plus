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
                    List {
                        Section {
                            HStack(spacing: 15) {
                                AsyncImage(url: profile.displayAvatar) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: { Color.smolishBlue }
                                .frame(width: 64, height: 64)
                                .clipShape(Circle())
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(profile.displayNameText).font(.title3.bold())
                                    if let handle = profile.handle { Text("@\(handle)").foregroundStyle(.secondary) }
                                }
                            }
                        }
                        Section("Session") {
                            Label("Authenticated with Smolish", systemImage: "checkmark.shield.fill")
                                .foregroundStyle(.green)
                            Label("V2 browser session retained", systemImage: "safari.fill")
                                .foregroundStyle(.secondary)
                            Button("Check session") { Task { await session.verifyStoredCookie() } }
                            Button("Sign out", role: .destructive) {
                                session.signOut()
                                Task { await webAuthentication.clearWebSession() }
                            }
                        }
                    }
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

struct WebSignInView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var webAuthentication: WebAuthenticationStore

    var body: some View {
        NavigationStack {
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
            .navigationTitle("Sign in to Smolish")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { webAuthentication.goBack() } label: { Image(systemName: "chevron.left") }
                        .disabled(!webAuthentication.webView.canGoBack)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { webAuthentication.reload() } label: { Image(systemName: "arrow.clockwise") }
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear {
            webAuthentication.onSignIn = { dismiss() }
            webAuthentication.start(session: session)
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
