import SwiftUI
import WebKit

@MainActor
final class WebAuthenticationStore: NSObject, ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var isCheckingSession = false
    @Published private(set) var currentURL: URL?
    @Published private(set) var statusMessage = "Waiting for sign-in…"
    @Published var errorMessage: String?
    @Published private(set) var accounts: [WebAccount] = []
    @Published private(set) var isLoadingAccounts = false
    @Published private(set) var switchingAccountToken: String?

    let webView: WKWebView
    private weak var sessionStore: SessionStore?
    private var pollingTask: Task<Void, Never>?
    private var didComplete = false
    private var requiresNewAccount = false
    private var knownAccountTokens: Set<String> = []
    private var accountBeingAddedFromProfileID: String?
    private var isPreparingAddAccount = false
    var onSignIn: (() -> Void)?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: URL(string: "https://smolish.com/search")!))
    }

    func start(session: SessionStore) {
        sessionStore = session
        didComplete = false
        requiresNewAccount = false
        knownAccountTokens = []
        accountBeingAddedFromProfileID = nil
        errorMessage = nil
        statusMessage = "Waiting for sign-in…"
        if webView.url?.host?.hasSuffix("smolish.com") == true {
            webView.reload()
        } else {
            webView.load(URLRequest(url: URL(string: "https://smolish.com/search")!))
        }
        startPolling()
    }

    func startAddingAccount(session: SessionStore) async {
        isPreparingAddAccount = true
        defer { isPreparingAddAccount = false }
        sessionStore = session
        accountBeingAddedFromProfileID = session.profile?.id
        errorMessage = nil
        stopPolling()
        await loadAccounts()
        knownAccountTokens = Set(accounts.map(\.sessionToken))
        requiresNewAccount = true
        didComplete = false
        statusMessage = "Tap the profile icon, open Switch account, then add an account"
        if webView.url?.host?.hasSuffix("smolish.com") == true {
            webView.load(URLRequest(url: URL(string: "https://smolish.com/search")!))
        } else {
            webView.load(URLRequest(url: URL(string: "https://smolish.com/search")!))
        }
        startPolling()
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func goBack() {
        if webView.canGoBack { webView.goBack() }
    }

    func reload() { webView.reload() }

    private func ensureBrowserReady() async -> Bool {
        if webView.url?.host?.hasSuffix("smolish.com") != true {
            webView.load(URLRequest(url: URL(string: "https://smolish.com/search")!))
        }
        for _ in 0..<20 {
            if !isLoading,
               let state = try? await webView.callAsyncJavaScript(
                   "return document.readyState;",
                   arguments: [:],
                   in: nil,
                   contentWorld: .page
               ) as? String,
               state == "interactive" || state == "complete" {
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    func loadAccounts() async {
        guard !isLoadingAccounts else { return }
        isLoadingAccounts = true
        defer { isLoadingAccounts = false }
        guard await ensureBrowserReady() else {
            errorMessage = "The Smolish browser session is still loading. Tap Refresh to try again."
            return
        }
        let script = """
        try {
          const response = await fetch('/api/accounts', { credentials: 'include', cache: 'no-store' });
          if (!response.ok) return JSON.stringify({ accounts: [], error: `Accounts returned ${response.status}` });
          return JSON.stringify(await response.json());
        } catch (error) {
          return JSON.stringify({ accounts: [], error: String(error) });
        }
        """
        for attempt in 0..<3 {
            do {
                guard let json = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) as? String,
                      let data = json.data(using: .utf8),
                      let envelope = try? JSONDecoder().decode(WebAccountsEnvelope.self, from: data) else { return }
                if let error = envelope.error,
                   error.localizedCaseInsensitiveContains("load failed"),
                   attempt < 2 {
                    webView.reload()
                    try? await Task.sleep(for: .seconds(1))
                    _ = await ensureBrowserReady()
                    continue
                }
                accounts = envelope.accounts
                errorMessage = envelope.error
                return
            } catch {
                if attempt == 2 { errorMessage = error.localizedDescription }
                else {
                    webView.reload()
                    try? await Task.sleep(for: .seconds(1))
                    _ = await ensureBrowserReady()
                }
            }
        }
    }

    func switchAccount(_ account: WebAccount) async -> Bool {
        guard !account.active, switchingAccountToken == nil else { return false }
        switchingAccountToken = account.sessionToken
        errorMessage = nil
        defer { switchingAccountToken = nil }
        guard await ensureBrowserReady() else {
            errorMessage = "The Smolish browser session is not ready. Please try again."
            return false
        }
        let script = """
        try {
          const response = await fetch('/api/auth/multi-session/set-active', {
            method: 'POST', credentials: 'include',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ sessionToken: accountToken })
          });
          return JSON.stringify({ ok: response.ok, status: response.status });
        } catch (error) {
          return JSON.stringify({ ok: false, status: 0, error: String(error) });
        }
        """
        do {
            guard let json = try await webView.callAsyncJavaScript(
                script,
                arguments: ["accountToken": account.sessionToken],
                in: nil,
                contentWorld: .page
            ) as? String,
                  let data = json.data(using: .utf8),
                  let result = try? JSONDecoder().decode(WebAccountSwitchResult.self, from: data),
                  result.ok else {
                errorMessage = "That Smolish account could not be opened."
                return false
            }
            webView.reload()
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                if await checkSession(expectedHandle: account.handle) {
                    await loadAccounts()
                    return true
                }
            }
            errorMessage = "Smolish did not activate @\(account.handle ?? account.displayName). Please try again."
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func refreshBrowserSession() async {
        guard await ensureBrowserReady() else { return }
        let script = """
        try {
          var response = await fetch('/api/auth/get-session', { credentials: 'include', cache: 'no-store' });
          if (!response.ok) return false;
          const auth = await response.json();
          const payload = auth?.data ?? auth;
          if (payload?.needsRefresh || payload?.session?.needsRefresh) {
            response = await fetch('/api/auth/get-session', {
              method: 'POST', credentials: 'include', cache: 'no-store'
            });
          }
          return response.ok;
        } catch (_) { return false; }
        """
        _ = try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
    }

    func clearWebSession() async {
        stopPolling()
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let smolishRecords = records.filter { $0.displayName.contains("smolish") }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: smolishRecords)
        webView.loadHTMLString("", baseURL: nil)
    }

    private func startPolling() {
        stopPolling()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !self.didComplete else { return }
                await self.checkSession()
            }
        }
    }

    @discardableResult
    private func checkSession(expectedHandle: String? = nil) async -> Bool {
        guard !isPreparingAddAccount,
              !isCheckingSession,
              webView.url?.host?.hasSuffix("smolish.com") == true else { return false }
        isCheckingSession = true
        defer { isCheckingSession = false }
        statusMessage = "Checking Smolish session…"
        let script = """
        try {
          const response = await fetch('/api/auth/get-session', { credentials: 'include', cache: 'no-store' });
          const auth = response.ok ? await response.json() : null;
          const payload = auth?.data ?? auth;
          if (!payload?.user || !payload?.session) {
            return JSON.stringify({ error: `Session check returned ${response.status}` });
          }
          const profileResponse = await fetch('/api/profile', { credentials: 'include', cache: 'no-store' });
          if (!profileResponse.ok) {
            return JSON.stringify({ error: `Profile check returned ${profileResponse.status}` });
          }
          const profile = await profileResponse.json();
          return JSON.stringify({
            profile,
            userAgent: navigator.userAgent
          });
        } catch (error) {
          return JSON.stringify({ error: String(error) });
        }
        """
        do {
            guard let json = try await webView.callAsyncJavaScript(
                script,
                arguments: [:],
                in: nil,
                contentWorld: .page
            ) as? String,
                  let data = json.data(using: .utf8) else {
                statusMessage = "Could not read the browser session"
                return false
            }
            if let failure = try? JSONDecoder().decode(WebSessionFailure.self, from: data) {
                statusMessage = failure.error
                return false
            }
            guard let envelope = try? JSONDecoder().decode(WebProfileEnvelope.self, from: data) else {
                statusMessage = "Smolish returned an unreadable session"
                return false
            }
            if let expectedHandle,
               envelope.profile.handle?.caseInsensitiveCompare(expectedHandle) != .orderedSame {
                statusMessage = "Waiting for @\(expectedHandle) to become active…"
                return false
            }
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                .filter { $0.domain.lowercased().hasSuffix("smolish.com") }
                .filter { $0.expiresDate.map { $0 > Date() } ?? true }
                .sorted { $0.name < $1.name }
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")
            guard !cookies.isEmpty, let sessionStore else {
                statusMessage = "Signed in, waiting for browser cookies…"
                return false
            }
            await loadAccounts()
            if requiresNewAccount {
                let hasNewSession = accounts.contains { !knownAccountTokens.contains($0.sessionToken) }
                let hasDifferentProfile = accountBeingAddedFromProfileID == nil
                    || envelope.profile.id != accountBeingAddedFromProfileID
                guard hasNewSession && hasDifferentProfile else {
                    statusMessage = "Waiting for a newly added Smolish account…"
                    return false
                }
            }
            statusMessage = "Transferring session to Smolish V2…"
            try sessionStore.acceptWebSession(cookie: cookies, userAgent: envelope.userAgent, profile: envelope.profile)
            didComplete = true
            requiresNewAccount = false
            knownAccountTokens = []
            accountBeingAddedFromProfileID = nil
            statusMessage = "Signed in"
            stopPolling()
            onSignIn?()
            return true
        } catch {
            statusMessage = "Browser bridge failed"
            errorMessage = error.localizedDescription
            return false
        }
    }
}

extension WebAuthenticationStore: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        Task { @MainActor in self.isLoading = true }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        Task { @MainActor in
            self.isLoading = false
            self.currentURL = webView.url
            await self.checkSession()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        Task { @MainActor in self.isLoading = false; self.errorMessage = error.localizedDescription }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
        Task { @MainActor in self.isLoading = false; self.errorMessage = error.localizedDescription }
    }
}

extension WebAuthenticationStore: WKUIDelegate {
    nonisolated func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            Task { @MainActor in self.webView.load(URLRequest(url: url)) }
        }
        return nil
    }
}

private struct WebProfileEnvelope: Decodable {
    let profile: SmolishProfile
    let userAgent: String
}

private struct WebSessionFailure: Decodable {
    let error: String
}

struct WebAccount: Identifiable, Decodable, Sendable {
    let sessionToken: String
    let displayName: String
    let handle: String?
    let avatarUrl: URL?
    let active: Bool
    var id: String { sessionToken }
}

private struct WebAccountsEnvelope: Decodable {
    let accounts: [WebAccount]
    let error: String?
}

private struct WebAccountSwitchResult: Decodable {
    let ok: Bool
    let status: Int
    let error: String?
}

struct PersistentWebView: UIViewRepresentable {
    @ObservedObject var store: WebAuthenticationStore
    func makeUIView(context: Context) -> WKWebView { store.webView }
    func updateUIView(_ webView: WKWebView, context: Context) {}
}
