import Foundation
import WebKit

actor AuthRequestGate {
    static let shared = AuthRequestGate()
    private var maintenanceActive = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func beginMaintenance() {
        maintenanceActive = true
    }

    func endMaintenance() {
        maintenanceActive = false
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitUntilAvailable() async {
        guard maintenanceActive else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
@MainActor
final class WebFetchBridge {
    static let shared = WebFetchBridge()
    weak var webView: WKWebView?

    struct Response: Sendable {
        let status: Int
        let data: Data
    }

    private struct Envelope: Decodable {
        let status: Int
        let body: String
    }

    private static let fetchScript = """
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 25000);
    try {
      const headers = { accept: accept };
      const init = { method: method, credentials: 'include', cache: 'no-store', headers: headers, signal: controller.signal };
      if (body !== null) { headers['content-type'] = 'application/json'; init.body = body; }
      const response = await fetch(path, init);
      const text = await response.text();
      return JSON.stringify({ status: response.status, body: text });
    } catch (error) {
      return JSON.stringify({ status: 0, body: String(error) });
    } finally {
      clearTimeout(timer);
    }
    """

    func fetch(path: String, method: String, body: Data?, accept: String) async throws -> Response {
        guard let webView else {
            throw APIError.server(status: 0, message: "The Smolish browser session isn't ready yet.")
        }
        let bodyString: Any = body.flatMap { String(data: $0, encoding: .utf8) } ?? NSNull()
        let arguments: [String: Any] = ["path": path, "method": method, "body": bodyString, "accept": accept]

        var lastError: Error = APIError.invalidResponse
        for attempt in 0..<2 {
            guard await waitUntilReady(webView) else {
                throw APIError.server(status: 0, message: "The Smolish browser session is still loading. Try again in a moment.")
            }
            do {
                guard let json = try await webView.callAsyncJavaScript(
                    Self.fetchScript, arguments: arguments, in: nil, contentWorld: .page
                ) as? String,
                      let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(json.utf8)) else {
                    throw APIError.invalidResponse
                }
                if envelope.status == 0 {
                    throw APIError.server(status: 0, message: "Network error: \(envelope.body)")
                }
                return Response(status: envelope.status, data: Data(envelope.body.utf8))
            } catch let error as APIError {
                throw error
            } catch {
                lastError = error
                // A navigation can interrupt the script; give the page a moment and retry once.
                if attempt == 0 { try? await Task.sleep(for: .milliseconds(500)) }
            }
        }
        throw lastError
    }

    /// Waits for a settled smolish.com document with the site's gate installed (or a short grace period).
    private func waitUntilReady(_ webView: WKWebView) async -> Bool {
        if webView.url?.host?.hasSuffix("smolish.com") != true, !webView.isLoading {
            webView.load(URLRequest(url: URL(string: "https://smolish.com/search")!))
        }
        for attempt in 0..<48 {
            if !webView.isLoading,
               webView.url?.host?.hasSuffix("smolish.com") == true,
               let json = try? await webView.callAsyncJavaScript(
                   "return JSON.stringify({ rs: document.readyState, gate: !!window.__smolishGate });",
                   arguments: [:], in: nil, contentWorld: .page
               ) as? String,
               let state = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
               state["rs"] as? String == "complete" {
                if state["gate"] as? Bool == true || attempt >= 16 { return true }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }
}

enum APIError: LocalizedError {
    case invalidResponse
    case server(status: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Smolish returned an invalid response."
        case let .server(status, message):
            message ?? "Smolish request failed (\(status))."
        }
    }
}

actor APIClient {
    static let shared = APIClient()

    private let baseURL = URL(string: "https://smolish.com")!
    private let session: URLSession
    private let decoder: JSONDecoder

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.waitsForConnectivity = true
            self.session = URLSession(configuration: configuration)
        }
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }
    func profileTabs(handle: String) async throws -> ProfileTabsData {
        let url = baseURL.appending(path: "@\(handle)")
        let data = try await send(url, accept: "text/html,application/xhtml+xml")
        guard let html = String(data: data, encoding: .utf8),
              let parsed = ProfileTabsParser.parse(html: html) else {
            throw APIError.invalidResponse
        }
        return parsed
    }
    func feed(cursor: String? = nil, author: String? = nil, friends: Bool = false, refreshNonce: String? = nil) async throws -> FeedResponse {
        var components = URLComponents(url: baseURL.appending(path: "api/feed"), resolvingAgainstBaseURL: false)!
        var queryItems: [URLQueryItem] = []
        if let cursor { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let author { queryItems.append(URLQueryItem(name: "author", value: author)) }
        if friends { queryItems.append(URLQueryItem(name: "friends", value: "1")) }
        if let refreshNonce { queryItems.append(URLQueryItem(name: "_refresh", value: refreshNonce)) }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return try await request(components.url!, includeSessionIfAvailable: true)
    }

    func searchUsers(query: String) async throws -> SearchUsersResponse {
        var components = URLComponents(url: baseURL.appending(path: "api/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "tab", value: "users"),
            URLQueryItem(name: "q", value: query)
        ]
        return try await request(components.url!, includeSessionIfAvailable: true)
    }

    func mentionSuggestions(query: String) async throws -> MentionsResponse {
        var components = URLComponents(url: baseURL.appending(path: "api/mentions"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return try await request(components.url!, includeSessionIfAvailable: true)
    }

    func setFollowing(userID: String, following: Bool) async throws {
        try await mutation(path: "api/follow", method: following ? "POST" : "DELETE", body: ["userId": userID])
    }

    func profile() async throws -> SmolishProfile {
        try await request(baseURL.appending(path: "api/profile"), authenticated: true)
    }

    func setLiked(videoID: String, liked: Bool) async throws {
        try await mutation(path: "api/likes", method: liked ? "POST" : "DELETE", body: ["videoId": videoID])
    }

    func setBookmarked(videoID: String, bookmarked: Bool) async throws {
        try await mutation(path: "api/bookmarks", method: bookmarked ? "POST" : "DELETE", body: ["videoId": videoID])
    }

    func unreadNotificationCount() async throws -> Int {
        let response: UnreadEnvelope = try await request(baseURL.appending(path: "api/notifications/unread"), authenticated: true)
        return response.unread
    }

    func notifications(page: Int = 1) async throws -> NotificationsResponse {
        var components = URLComponents(url: baseURL.appending(path: "api/notifications"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "page", value: String(page))]
        return try await request(components.url!, authenticated: true)
    }

    func markAllNotificationsRead() async throws {
        try await mutation(path: "api/notifications/read", method: "POST", body: [:])
    }

    func studioVideos(page: Int = 1, limit: Int = 10) async throws -> StudioVideosResponse {
        var components = URLComponents(url: baseURL.appending(path: "api/videos"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "sort", value: "date"),
            URLQueryItem(name: "dir", value: "desc")
        ]
        return try await request(components.url!, authenticated: true)
    }

    func createVideoUpload(filename: String, contentType: String, sizeBytes: Int) async throws -> UploadCreationResponse {
        try await authenticatedJSON(path: "api/videos", method: "POST", body: CreateUploadBody(contentType: contentType, sizeBytes: sizeBytes, filename: filename))
    }

    func uploadPartURL(videoID: String, partNumber: Int) async throws -> UploadPartURLResponse {
        try await authenticatedJSON(path: "api/videos/\(videoID)/parts", method: "POST", body: PartNumberBody(partNumber: partNumber))
    }

    func uploadPart(data: Data, to url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data
        let (responseData, response) = try await session.data(for: request)
        try validate(response: response, data: responseData)
        guard let http = response as? HTTPURLResponse,
              let etag = http.value(forHTTPHeaderField: "ETag") else { throw APIError.invalidResponse }
        return etag
    }

    func acknowledgeUploadPart(videoID: String, partNumber: Int, etag: String, sizeBytes: Int) async throws {
        let _: EmptyResponse = try await authenticatedJSON(
            path: "api/videos/\(videoID)/parts",
            method: "PUT",
            body: AcknowledgePartBody(partNumber: partNumber, etag: etag, sizeBytes: sizeBytes)
        )
    }

    func completeVideoUpload(videoID: String) async throws -> StudioVideoEnvelope {
        try await authenticatedJSON(path: "api/videos/\(videoID)/complete", method: "POST", body: EmptyBody())
    }

    func updateVideo(videoID: String, title: String, description: String, visibility: String, epilepsyWarning: Bool, aiGenerated: Bool) async throws -> StudioVideoEnvelope {
        try await authenticatedJSON(
            path: "api/videos/\(videoID)",
            method: "PATCH",
            body: UpdateVideoBody(title: title, description: description, visibility: visibility, epilepsyWarning: epilepsyWarning, aiGenerated: aiGenerated)
        )
    }

    func comments(videoID: String, parentID: String? = nil, cursor: String? = nil) async throws -> CommentsResponse {
        var components = URLComponents(url: baseURL.appending(path: "api/comments"), resolvingAgainstBaseURL: false)!
        var query = [URLQueryItem(name: "videoId", value: videoID)]
        if let parentID { query.append(URLQueryItem(name: "parentId", value: parentID)) }
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        components.queryItems = query
        return try await request(components.url!, includeSessionIfAvailable: true)
    }

    func postComment(videoID: String, body: String, parentID: String? = nil) async throws -> PostedCommentResponse {
        let payload = try JSONEncoder().encode(PostCommentBody(videoId: videoID, body: body, gifSlug: nil, parentId: parentID))
        let data = try await send(baseURL.appending(path: "api/comments"), method: "POST", body: payload)
        return try decoder.decode(PostedCommentResponse.self, from: data)
    }

    func setCommentReaction(commentID: String, liked: Bool) async throws {
        let reaction: String? = liked ? "like" : nil
        let payload = try JSONEncoder().encode(CommentReactionBody(commentId: commentID, reaction: reaction))
        _ = try await send(baseURL.appending(path: "api/comments/reactions"), method: "POST", body: payload)
    }

    func studioAnalytics(days: Int) async throws -> StudioAnalytics {
        var components = URLComponents(url: baseURL.appending(path: "api/studio/analytics"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "days", value: String(days))]
        let data = try await send(components.url!)
        return StudioAnalyticsParser.parse(data: data)
    }

    private func request<T: Decodable>(_ url: URL, authenticated: Bool = false, includeSessionIfAvailable: Bool = false) async throws -> T {
        let data = try await send(url)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }

    private func mutation(path: String, method: String, body: [String: String]) async throws {
        _ = try await send(baseURL.appending(path: path), method: method, body: try JSONEncoder().encode(body))
    }

    private func authenticatedJSON<Body: Encodable, Response: Decodable>(path: String, method: String, body: Body) async throws -> Response {
        let data = try await send(baseURL.appending(path: path), method: method, body: try JSONEncoder().encode(body))
        if Response.self == EmptyResponse.self, data.isEmpty {
            return EmptyResponse() as! Response
        }
        return try decoder.decode(Response.self, from: data)
    }

    /// Runs the request inside the signed-in web view so the site's gate handles it.
    private func send(_ url: URL, method: String = "GET", body: Data? = nil, accept: String = "application/json") async throws -> Data {
        await AuthRequestGate.shared.waitUntilAvailable()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var path = components?.percentEncodedPath ?? url.path
        if let query = components?.percentEncodedQuery, !query.isEmpty { path += "?\(query)" }
        let response = try await WebFetchBridge.shared.fetch(path: path, method: method, body: body, accept: accept)
        try validate(status: response.status, data: response.data)
        return response.data
    }

    private func validate(status: Int, data: Data) throws {
        guard (200..<300).contains(status) else {
            let body = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
            let message: String? = body?.error ?? (status == 401 ? "Sign in from Profile first." : nil)
            throw APIError.server(status: status, message: message)
        }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        try validate(status: http.statusCode, data: data)
    }
}

struct ClipItem: Decodable {
    let id: String
    let title: String
    let thumbnail: String
    let viewsCount: Int
    let durationSeconds: Int
    let authorHandle: String
    let pinned: Bool
}

struct ClipsPage: Decodable {
    let items: [ClipItem]
    let nextCursor: String?
}

struct ProfileTabsData: Decodable {
    let handle: String
    let isViewer: Bool
    let clips: ClipsPage
    let likedClips: ClipsPage
    let savedClips: ClipsPage
    let likesPublic: Bool
    let likesVisible: Bool
}

private struct ErrorEnvelope: Decodable {
    let error: String?
}



private struct UnreadEnvelope: Decodable {
    let unread: Int
}

private struct PostCommentBody: Encodable {
    let videoId: String
    let body: String
    let gifSlug: String?
    let parentId: String?
}

private struct CommentReactionBody: Encodable {
    let commentId: String
    let reaction: String?
}

private struct CreateUploadBody: Encodable { let contentType: String; let sizeBytes: Int; let filename: String }
private struct PartNumberBody: Encodable { let partNumber: Int }
private struct AcknowledgePartBody: Encodable { let partNumber: Int; let etag: String; let sizeBytes: Int }
private struct EmptyBody: Encodable {}
private struct EmptyResponse: Decodable { init() {} }
private struct UpdateVideoBody: Encodable {
    let title: String
    let description: String
    let visibility: String
    let epilepsyWarning: Bool
    let aiGenerated: Bool
}

private enum StudioAnalyticsParser {
    static func parse(data: Data) -> StudioAnalytics {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return StudioAnalytics(metrics: [], points: [])
        }
        let summary = (root["summary"] as? [String: Any]) ?? (root["totals"] as? [String: Any]) ?? root
        let definitions: [(keys: [String], title: String, format: AnalyticsMetricFormat)] = [
            (["views", "totalViews"], "Views", .count),
            (["uniqueViewers", "viewers"], "Unique viewers", .count),
            (["watchTimeSeconds", "totalWatchTimeSeconds", "watchTime"], "Watch time", .seconds),
            (["averageWatchTimeSeconds", "avgWatchTimeSeconds", "averageWatchTime"], "Avg. watch time", .seconds),
            (["completionRate", "averageCompletionRate"], "Completion", .percentage),
            (["likes", "likesCount"], "Likes", .count),
            (["comments", "commentsCount"], "Comments", .count),
            (["shares", "sharesCount"], "Shares", .count),
            (["followersGained", "newFollowers"], "Followers gained", .count)
        ]
        let metrics = definitions.compactMap { definition -> AnalyticsMetric? in
            guard let pair = definition.keys.compactMap({ key in number(summary[key]).map { (key, $0) } }).first else { return nil }
            return AnalyticsMetric(id: pair.0, title: definition.title, value: pair.1, format: definition.format)
        }

        let rawPoints = (root["daily"] as? [[String: Any]])
            ?? (root["series"] as? [[String: Any]])
            ?? (root["timeline"] as? [[String: Any]])
            ?? []
        let formatter = ISO8601DateFormatter()
        let points = rawPoints.compactMap { point -> AnalyticsPoint? in
            guard let dateString = (point["date"] ?? point["day"]) as? String,
                  let date = formatter.date(from: dateString),
                  let views = number(point["views"] ?? point["count"]) else { return nil }
            return AnalyticsPoint(id: dateString, date: date, views: views)
        }
        return StudioAnalytics(metrics: metrics, points: points)
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }
}

extension ClipItem {
    func asSmolishVideo(author: SmolishVideo? = nil) -> SmolishVideo {
        SmolishVideo(
            id: id,
            title: title,
            description: "",
            src: URL(string: "https://cdn.smolish.com/videos/\(id)/1080p.mp4")!,
            thumbnail: URL(string: thumbnail),
            width: 1080,
            height: 1920,
            durationSeconds: Double(durationSeconds),
            epilepsyWarning: false,
            aiGenerated: false,
            viewsCount: viewsCount,
            likesCount: 0,
            commentsCount: 0,
            transcript: nil,
            publishedAt: .now,
            authorId: author?.authorId ?? "",
            authorHandle: authorHandle,
            authorName: author?.authorName ?? authorHandle,
            authorAvatar: author?.authorAvatar,
            authorFollowers: author?.authorFollowers ?? 0,
            authorBraincells: author?.authorBraincells ?? 0,
            authorBraincellsProvisional: author?.authorBraincellsProvisional ?? false,
            viewerFollows: author?.viewerFollows ?? false,
            viewerLiked: false,
            viewerSaved: false,
            friendLikers: []
        )
    }
}

enum ProfileTabsParser {

    static func parse(html: String) -> ProfileTabsData? {
        let combined = extractFlightText(from: html)

        guard let line = combined
            .split(separator: "\n")
            .first(where: { $0.contains("\"likedClips\"") }) else {
            return nil
        }

        guard let colonIndex = line.firstIndex(of: ":") else { return nil }
        let jsonPart = String(line[line.index(after: colonIndex)...])

        guard let data = jsonPart.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              array.count >= 4,
              let propsDict = array[3] as? [String: Any],
              let propsData = try? JSONSerialization.data(withJSONObject: propsDict) else {
            return nil
        }

        return try? JSONDecoder().decode(ProfileTabsData.self, from: propsData)
    }

    private static func extractFlightText(from html: String) -> String {
        let pattern = #"self\.__next_f\.push\(\[1,\"((?:[^"\\]|\\.)*)\"\]\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "" }

        let nsrange = NSRange(html.startIndex..., in: html)
        var combined = ""

        regex.enumerateMatches(in: html, range: nsrange) { match, _, _ in
            guard let match, let range = Range(match.range(at: 1), in: html) else { return }
            combined += unescape(String(html[range]))
        }
        return combined
    }

    private static func unescape(_ s: String) -> String {
        var result = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count {
                switch chars[i + 1] {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "u" where i + 5 < chars.count:
                    let hex = String(chars[(i + 2)...(i + 5)])
                    if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                        result.append(Character(scalar))
                    }
                    i += 4
                default:
                    result.append(chars[i + 1])
                }
                i += 2
            } else {
                result.append(chars[i])
                i += 1
            }
        }
        return result
    }
}
