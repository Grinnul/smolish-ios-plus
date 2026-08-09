import Foundation
import Security

struct SmolishProfile: Decodable, Sendable {
    let id: String?
    let handle: String?
    let name: String?
    let displayName: String?
    let avatar: URL?
    let avatarUrl: URL?

    var displayNameText: String { displayName ?? name ?? handle ?? "Smolish user" }
    var displayAvatar: URL? { avatar ?? avatarUrl }

    private enum CodingKeys: String, CodingKey { case id, userId, handle, name, displayName, avatar, avatarUrl }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? container.decodeIfPresent(String.self, forKey: .userId)
        handle = try container.decodeIfPresent(String.self, forKey: .handle)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        avatar = try container.decodeIfPresent(URL.self, forKey: .avatar)
        avatarUrl = try container.decodeIfPresent(URL.self, forKey: .avatarUrl)
    }
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var profile: SmolishProfile?
    @Published private(set) var isChecking = false
    @Published private(set) var isAuthenticated = false
    @Published var authenticationError: String?

    init() {
        if let stored = KeychainCookieStore.load() {
            let normalized = Self.normalizedCookie(stored)
            if normalized != stored { try? KeychainCookieStore.save(normalized) }
            isAuthenticated = true
        }
    }

    func restore() async {
        guard isAuthenticated else { return }
        await verifyStoredCookie()
    }

    func authenticate(cookie rawCookie: String, userAgent rawUserAgent: String = "") async -> Bool {
        let cookie = Self.normalizedCookie(rawCookie)
        guard !cookie.isEmpty else {
            authenticationError = "Paste the complete Cookie header value."
            return false
        }

        do {
            try KeychainCookieStore.save(cookie)
            let userAgent = rawUserAgent.trimmingCharacters(in: .whitespacesAndNewlines)
            if userAgent.isEmpty { BrowserUserAgentStore.delete() }
            else { try BrowserUserAgentStore.save(userAgent) }
            isAuthenticated = true
            await verifyStoredCookie()
            if profile != nil { return true }
            KeychainCookieStore.delete()
            isAuthenticated = false
            return false
        } catch {
            authenticationError = error.localizedDescription
            return false
        }
    }

    func verifyStoredCookie() async {
        guard KeychainCookieStore.load() != nil else {
            isAuthenticated = false
            return
        }

        isChecking = true
        authenticationError = nil
        defer { isChecking = false }

        do {
            profile = try await APIClient.shared.profile()
            isAuthenticated = true
        } catch {
            profile = nil
            isAuthenticated = false
            authenticationError = "That cookie is expired or invalid. \(error.localizedDescription)"
        }
    }

    func signOut() {
        KeychainCookieStore.delete()
        BrowserUserAgentStore.delete()
        profile = nil
        isAuthenticated = false
        authenticationError = nil
    }

    private static func normalizedCookie(_ input: String) -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("cookie:") {
            value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        value = value.replacingOccurrences(of: "\n", with: "")

        return value.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("=") }
            .joined(separator: "; ")
    }
}

enum KeychainCookieStore {
    private static let service = "com.smolish.ios.session"
    private static let account = "cookie-header"

    static func save(_ cookie: String) throws {
        let data = Data(cookie.utf8)
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum BrowserUserAgentStore {
    private static let service = "com.smolish.ios.session"
    private static let account = "browser-user-agent"

    static func save(_ userAgent: String) throws {
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(userAgent.utf8)
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
