import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var session: SessionStore
    @State private var showCookieEntry = false

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
                            Button("Check session") { Task { await session.verifyStoredCookie() } }
                            Button("Remove cookie and sign out", role: .destructive) { session.signOut() }
                        }
                    }
                } else {
                    VStack(spacing: 22) {
                        SmolishLogo(size: 72)
                        Text("Your Smolish profile").font(.title2.bold())
                        Text("For this development build, paste your Smolish browser cookie. It is stored only in this device’s Keychain.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 28)
                        Button("Authenticate with cookie") { showCookieEntry = true }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        if let error = session.authenticationError {
                            Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal)
                        }
                    }
                }
            }
            .navigationTitle("Profile")
            .sheet(isPresented: $showCookieEntry) { CookieSignInView() }
        }
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
                TextField("Browser User-Agent (recommended)", text: $userAgent, axis: .vertical)
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
                    .disabled(cookie.isEmpty || session.isChecking)
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
