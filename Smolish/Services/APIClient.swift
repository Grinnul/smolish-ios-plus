import Foundation

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

    func feed(cursor: String? = nil, author: String? = nil, friends: Bool = false) async throws -> FeedResponse {
        var components = URLComponents(url: baseURL.appending(path: "api/feed"), resolvingAgainstBaseURL: false)!
        var queryItems: [URLQueryItem] = []
        if let cursor { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let author { queryItems.append(URLQueryItem(name: "author", value: author)) }
        if friends { queryItems.append(URLQueryItem(name: "friends", value: "1")) }
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
        guard let cookie = KeychainCookieStore.load() else {
            throw APIError.server(status: 401, message: "Sign in from Profile first.")
        }
        var request = URLRequest(url: baseURL.appending(path: "api/comments"))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(PostCommentBody(videoId: videoID, body: body, gifSlug: nil, parentId: parentID))
        applyBrowserHeaders(to: &request, cookie: cookie, mutation: true)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(PostedCommentResponse.self, from: data)
    }

    func setCommentReaction(commentID: String, liked: Bool) async throws {
        let reaction: String? = liked ? "like" : nil
        guard let cookie = KeychainCookieStore.load() else {
            throw APIError.server(status: 401, message: "Sign in from Profile first.")
        }
        var request = URLRequest(url: baseURL.appending(path: "api/comments/reactions"))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(CommentReactionBody(commentId: commentID, reaction: reaction))
        applyBrowserHeaders(to: &request, cookie: cookie, mutation: true)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
    }

    func studioAnalytics(days: Int) async throws -> StudioAnalytics {
        var components = URLComponents(url: baseURL.appending(path: "api/studio/analytics"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "days", value: String(days))]
        let data = try await authenticatedData(url: components.url!)
        return StudioAnalyticsParser.parse(data: data)
    }

    private func request<T: Decodable>(_ url: URL, authenticated: Bool = false, includeSessionIfAvailable: Bool = false) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authenticated {
            guard let cookie = KeychainCookieStore.load() else {
                throw APIError.server(status: 401, message: "Sign in from Profile first.")
            }
            applyBrowserHeaders(to: &request, cookie: cookie)
        } else if includeSessionIfAvailable, let cookie = KeychainCookieStore.load() {
            applyBrowserHeaders(to: &request, cookie: cookie)
        }
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }

    private func authenticatedData(url: URL) async throws -> Data {
        guard let cookie = KeychainCookieStore.load() else {
            throw APIError.server(status: 401, message: "Sign in from Profile first.")
        }
        var request = URLRequest(url: url)
        applyBrowserHeaders(to: &request, cookie: cookie)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return data
    }

    private func mutation(path: String, method: String, body: [String: String]) async throws {
        guard let cookie = KeychainCookieStore.load() else {
            throw APIError.server(status: 401, message: "Sign in from Profile first.")
        }
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.httpBody = try JSONEncoder().encode(body)
        applyBrowserHeaders(to: &request, cookie: cookie, mutation: true)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
    }

    private func authenticatedJSON<Body: Encodable, Response: Decodable>(path: String, method: String, body: Body) async throws -> Response {
        guard let cookie = KeychainCookieStore.load() else { throw APIError.server(status: 401, message: "Sign in from Profile first.") }
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.httpBody = try JSONEncoder().encode(body)
        applyBrowserHeaders(to: &request, cookie: cookie, mutation: true)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        if Response.self == EmptyResponse.self, data.isEmpty {
            return EmptyResponse() as! Response
        }
        return try decoder.decode(Response.self, from: data)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
            let cloudflareMessage: String? = http.statusCode == 403 && http.value(forHTTPHeaderField: "server")?.lowercased().contains("cloudflare") == true
                ? "Cloudflare rejected this browser session. Paste the complete fresh Cookie header and navigator.userAgent from the same browser in Profile."
                : nil
            throw APIError.server(status: http.statusCode, message: body?.error ?? cloudflareMessage)
        }
    }

    private func applyBrowserHeaders(to request: inout URLRequest, cookie: String, mutation: Bool = false) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://smolish.com", forHTTPHeaderField: "Origin")
        request.setValue("https://smolish.com/", forHTTPHeaderField: "Referer")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        if mutation { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let userAgent = BrowserUserAgentStore.load(), !userAgent.isEmpty {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
    }
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
