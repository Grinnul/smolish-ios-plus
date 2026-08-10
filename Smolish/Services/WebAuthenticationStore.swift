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
    @Published private(set) var accountHealth: [String: AccountSessionHealth] = [:]
    @Published private(set) var isMaintainingAccounts = false

    let webView: WKWebView
    private weak var sessionStore: SessionStore?
    private var pollingTask: Task<Void, Never>?
    private var didComplete = false
    private var requiresNewAccount = false
    private var knownAccountTokens: Set<String> = []
    private var accountBeingAddedFromProfileID: String?
    private var isPreparingAddAccount = false
    private var isPrepared = false
    private let maintenanceInterval: TimeInterval = 30 * 60
    private let lastMaintenanceKey = "smolish.lastMultiAccountMaintenance"
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
    }

    func restore(session: SessionStore) async {
        sessionStore = session
        guard !isPrepared else { return }
        isPrepared = true
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        for cookie in WebCookieJarStore.load() {
            await cookieStore.setCookie(cookie)
        }
        webView.load(URLRequest(url: URL(string: "https://smolish.com/search")!))
        guard await ensureBrowserReady() else { return }
        _ = await refreshActiveBrowserSession()
        _ = await checkSession()
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
        guard !account.active, switchingAccountToken == nil, !isMaintainingAccounts else { return false }
        switchingAccountToken = account.sessionToken
        errorMessage = nil
        defer { switchingAccountToken = nil }
        guard await ensureBrowserReady() else {
            errorMessage = "The Smolish browser session is not ready. Please try again."
            return false
        }
        let previousAccount = accounts.first(where: \.active)
        await AuthRequestGate.shared.beginMaintenance()
        let switched = await activateAccount(account)
        if switched == .success {
            webView.reloadFromOrigin()
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                if await checkSession(expectedHandle: account.handle) {
                    _ = await refreshActiveBrowserSession()
                    await loadAccounts()
                    await AuthRequestGate.shared.endMaintenance()
                    return true
                }
            }
            errorMessage = "Smolish did not activate @\(account.handle ?? account.displayName). Please try again."
        } else {
            errorMessage = "That Smolish account could not be opened."
        }
        if let previousAccount {
            _ = await activateAccount(previousAccount)
            _ = await promoteMultiSessionCookie(for: previousAccount.sessionToken)
            _ = await refreshActiveBrowserSession()
            _ = await checkSession(expectedHandle: previousAccount.handle)
            await loadAccounts()
        }
        await AuthRequestGate.shared.endMaintenance()
        return false
    }

    private func activateAccount(_ account: WebAccount) async -> WebAccountActivation {
        let script = """
        try {
          const response = await fetch('/api/auth/multi-session/set-active', {
            method: 'POST', credentials: 'include',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ sessionToken: accountToken })
          });
          const body = await response.json().catch(() => null);
          return JSON.stringify({ ok: response.ok && !!body?.session, status: response.status,
            error: body?.message ?? body?.error ?? null });
        } catch (error) {
          return JSON.stringify({ ok: false, status: 0, error: String(error) });
        }
        """
        guard let json = try? await webView.callAsyncJavaScript(
            script, arguments: ["accountToken": account.sessionToken], in: nil, contentWorld: .page
        ) as? String,
              let data = json.data(using: .utf8),
              let result = try? JSONDecoder().decode(WebAccountSwitchResult.self, from: data) else {
            return .temporarilyUnavailable
        }
        guard result.ok else {
            return result.status == 401 || result.status == 404 ? .expired : .temporarilyUnavailable
        }
        return await promoteMultiSessionCookie(for: account.sessionToken) ? .success : .temporarilyUnavailable
    }

    private func promoteMultiSessionCookie(for sessionToken: String) async -> Bool {
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = await cookieStore.allCookies()
        let suffix = "_multi-\(sessionToken.lowercased())"
        guard let source = cookies.first(where: { $0.name.lowercased().hasSuffix(suffix) }),
              let range = source.name.range(of: "_multi-", options: [.backwards, .caseInsensitive]) else {
            return false
        }
        let primaryName = String(source.name[..<range.lowerBound])
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: primaryName,
            .value: source.value,
            .domain: source.domain,
            .path: source.path,
            .secure: "TRUE"
        ]
        if let expiresDate = source.expiresDate { properties[.expires] = expiresDate }
        properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
        guard let primaryCookie = HTTPCookie(properties: properties) else { return false }
        await cookieStore.setCookie(primaryCookie)
        let updated = await cookieStore.allCookies()
        return updated.contains { $0.name == primaryName && $0.value == source.value }
    }

    @discardableResult
    private func refreshActiveBrowserSession(updateNativeHeader: Bool = true) async -> Bool {
        guard await ensureBrowserReady() else { return false }
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
        let refreshed = (try? await webView.callAsyncJavaScript(
            script, arguments: [:], in: nil, contentWorld: .page
        ) as? Bool) ?? false
        _ = try? await persistBrowserCookies(updateNativeHeader: updateNativeHeader)
        return refreshed
    }

    func refreshBrowserSession() async {
        _ = await refreshActiveBrowserSession()
    }

    func refreshAllAccountsIfNeeded(force: Bool = false) async {
        guard isPrepared, !isMaintainingAccounts, switchingAccountToken == nil,
              sessionStore?.isAuthenticated == true else { return }
        let lastRun = UserDefaults.standard.object(forKey: lastMaintenanceKey) as? Date ?? .distantPast
        guard force || Date().timeIntervalSince(lastRun) >= maintenanceInterval else { return }
        guard await ensureBrowserReady() else { return }

        isMaintainingAccounts = true
        await AuthRequestGate.shared.beginMaintenance()
        await loadAccounts()
        guard let selected = accounts.first(where: \.active) else {
            isMaintainingAccounts = false
            await AuthRequestGate.shared.endMaintenance()
            return
        }

        var health = accountHealth
        for account in accounts where !account.active {
            let activation = await activateAccount(account)
            if activation == .success {
                let refreshed = await refreshActiveBrowserSession(updateNativeHeader: false)
                health[account.sessionToken] = refreshed ? .valid(lastRefresh: Date()) : .temporarilyUnavailable
            } else {
                health[account.sessionToken] = activation == .expired ? .expired : .temporarilyUnavailable
            }
        }

        let restored = await activateAccount(selected)
        if restored == .success {
            _ = await refreshActiveBrowserSession()
            _ = await checkSession(expectedHandle: selected.handle, allowDuringMaintenance: true)
            health[selected.sessionToken] = .valid(lastRefresh: Date())
            UserDefaults.standard.set(Date(), forKey: lastMaintenanceKey)
        } else {
            // Even if the network switch failed, restore the original primary
            // cookie locally so native requests and WebKit cannot diverge.
            let restoredLocally = await promoteMultiSessionCookie(for: selected.sessionToken)
            if restoredLocally {
                _ = await refreshActiveBrowserSession()
                _ = await checkSession(expectedHandle: selected.handle, allowDuringMaintenance: true)
            }
            health[selected.sessionToken] = restoredLocally
                ? .valid(lastRefresh: Date()) : .temporarilyUnavailable
        }
        accountHealth = health
        await loadAccounts()
        isMaintainingAccounts = false
        await AuthRequestGate.shared.endMaintenance()
    }

    func clearWebSession() async {
        stopPolling()
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let smolishRecords = records.filter { $0.displayName.contains("smolish") }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: smolishRecords)
        WebCookieJarStore.delete()
        UserDefaults.standard.removeObject(forKey: lastMaintenanceKey)
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
    private func checkSession(expectedHandle: String? = nil, allowDuringMaintenance: Bool = false) async -> Bool {
        guard !isPreparingAddAccount,
              (!isMaintainingAccounts || allowDuringMaintenance),
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
            let cookies = try await persistBrowserCookies(updateNativeHeader: false)
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
            Task { await self.refreshAllAccountsIfNeeded(force: true) }
            return true
        } catch {
            statusMessage = "Browser bridge failed"
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    private func persistBrowserCookies(updateNativeHeader: Bool) async throws -> String {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            .filter { $0.domain.lowercased().hasSuffix("smolish.com") }
            .filter { $0.expiresDate.map { $0 > Date() } ?? true }
        try WebCookieJarStore.save(cookies)
        let header = cookies.sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
        if updateNativeHeader, !header.isEmpty {
            try KeychainCookieStore.save(header)
            if let userAgent = try? await webView.callAsyncJavaScript(
                "return navigator.userAgent;", arguments: [:], in: nil, contentWorld: .page
            ) as? String, !userAgent.isEmpty {
                try BrowserUserAgentStore.save(userAgent)
            }
        }
        return header
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

enum AccountSessionHealth: Equatable, Sendable {
    case valid(lastRefresh: Date)
    case temporarilyUnavailable
    case expired
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

private enum WebAccountActivation: Equatable {
    case success
    case temporarilyUnavailable
    case expired
}

struct PersistentWebView: UIViewRepresentable {
    @ObservedObject var store: WebAuthenticationStore
    func makeUIView(context: Context) -> WKWebView { store.webView }
    func updateUIView(_ webView: WKWebView, context: Context) {}
}
