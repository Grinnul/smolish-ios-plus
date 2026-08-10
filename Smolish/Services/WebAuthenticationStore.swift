import SwiftUI
import WebKit

@MainActor
final class WebAuthenticationStore: NSObject, ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var isCheckingSession = false
    @Published private(set) var currentURL: URL?
    @Published private(set) var statusMessage = "Waiting for sign-in…"
    @Published var errorMessage: String?

    let webView: WKWebView
    private weak var sessionStore: SessionStore?
    private var pollingTask: Task<Void, Never>?
    private var didComplete = false
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

    func start(session: SessionStore) {
        sessionStore = session
        didComplete = false
        errorMessage = nil
        statusMessage = "Waiting for sign-in…"
        if webView.url?.host?.hasSuffix("smolish.com") == true {
            webView.reload()
        } else {
            webView.load(URLRequest(url: URL(string: "https://smolish.com/profile")!))
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

    private func checkSession() async {
        guard !isCheckingSession, webView.url?.host?.hasSuffix("smolish.com") == true else { return }
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
          const user = payload.user;
          return JSON.stringify({
            profile: {
              id: user.id ?? null,
              handle: user.handle ?? user.username ?? null,
              name: user.name ?? null,
              displayName: user.displayName ?? user.name ?? null,
              avatarUrl: user.avatarUrl ?? user.avatar ?? user.image ?? null
            },
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
                return
            }
            if let failure = try? JSONDecoder().decode(WebSessionFailure.self, from: data) {
                statusMessage = failure.error
                return
            }
            guard let envelope = try? JSONDecoder().decode(WebProfileEnvelope.self, from: data) else {
                statusMessage = "Smolish returned an unreadable session"
                return
            }
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                .filter { $0.domain.lowercased().hasSuffix("smolish.com") }
                .filter { $0.expiresDate.map { $0 > Date() } ?? true }
                .sorted { $0.name < $1.name }
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")
            guard !cookies.isEmpty, let sessionStore else {
                statusMessage = "Signed in, waiting for browser cookies…"
                return
            }
            statusMessage = "Transferring session to Smolish V2…"
            try sessionStore.acceptWebSession(cookie: cookies, userAgent: envelope.userAgent, profile: envelope.profile)
            didComplete = true
            statusMessage = "Signed in"
            stopPolling()
            onSignIn?()
        } catch {
            statusMessage = "Browser bridge failed"
            errorMessage = error.localizedDescription
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

struct PersistentWebView: UIViewRepresentable {
    @ObservedObject var store: WebAuthenticationStore
    func makeUIView(context: Context) -> WKWebView { store.webView }
    func updateUIView(_ webView: WKWebView, context: Context) {}
}
