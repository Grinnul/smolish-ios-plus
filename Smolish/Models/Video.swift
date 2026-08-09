import Foundation

struct FeedResponse: Decodable, Sendable {
    let items: [SmolishVideo]
    let nextCursor: String?
}

struct SmolishVideo: Identifiable, Decodable, Hashable, Sendable {
    let id: String
    let title: String
    let description: String
    let src: URL
    let thumbnail: URL?
    let width: Int
    let height: Int
    let durationSeconds: Double
    let epilepsyWarning: Bool
    let aiGenerated: Bool
    let viewsCount: Int
    let likesCount: Int
    let commentsCount: Int
    let transcript: String?
    let publishedAt: Date
    let authorId: String
    let authorHandle: String
    let authorName: String
    let authorAvatar: URL?
    let authorFollowers: Int
    let authorBraincells: Int
    let authorBraincellsProvisional: Bool
    let viewerFollows: Bool
    let viewerLiked: Bool
    let viewerSaved: Bool
    let friendLikers: [FriendLiker]
}

struct FriendLiker: Decodable, Hashable, Sendable {
    let id: String?
    let handle: String?
    let name: String?
    let avatar: URL?
}

struct NotificationsResponse: Decodable, Sendable {
    let items: [SmolishNotification]
    let page: Int?
    let pages: Int?
    let total: Int?

    private enum CodingKeys: String, CodingKey { case items, notifications, page, pages, total }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([SmolishNotification].self, forKey: .items)
            ?? container.decodeIfPresent([SmolishNotification].self, forKey: .notifications)
            ?? []
        page = try container.decodeIfPresent(Int.self, forKey: .page)
        pages = try container.decodeIfPresent(Int.self, forKey: .pages)
        total = try container.decodeIfPresent(Int.self, forKey: .total)
    }
}

struct SmolishNotification: Identifiable, Decodable, Sendable {
    let id: String
    let type: String?
    let title: String?
    let body: String?
    let message: String?
    let createdAt: Date?
    let readAt: Date?
    let actorName: String?
    let actorHandle: String?
    let actorAvatar: URL?
    let videoId: String?

    var displayTitle: String {
        title ?? actorName.map { "\($0) interacted with you" } ?? type?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Notification"
    }

    var displayBody: String? { body ?? message ?? actorHandle.map { "@\($0)" } }
    var isUnread: Bool { readAt == nil }
}

struct StudioVideosResponse: Decodable, Sendable {
    let items: [StudioVideo]
    let page: Int?
    let pages: Int?
    let total: Int?
    let limit: Int?

    private enum CodingKeys: String, CodingKey { case items, videos, page, pages, total, limit }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([StudioVideo].self, forKey: .items)
            ?? container.decodeIfPresent([StudioVideo].self, forKey: .videos)
            ?? []
        page = try container.decodeIfPresent(Int.self, forKey: .page)
        pages = try container.decodeIfPresent(Int.self, forKey: .pages)
        total = try container.decodeIfPresent(Int.self, forKey: .total)
        limit = try container.decodeIfPresent(Int.self, forKey: .limit)
    }
}

struct StudioVideo: Identifiable, Decodable, Sendable {
    let id: String
    let title: String?
    let description: String?
    let thumbnail: URL?
    let status: String?
    let visibility: String?
    let viewsCount: Int?
    let likesCount: Int?
    let commentsCount: Int?
    let impressionsCount: Int?
    let playsCount: Int?
    let completionsCount: Int?
    let replaysCount: Int?
    let uniqueViewersCount: Int?
    let durationSeconds: Double?
    let src: URL?
    let publishedAt: Date?
    let createdAt: Date?
}

struct UploadCreationResponse: Decodable, Sendable {
    let video: StudioVideo
    let partSize: Int
    let partCount: Int
}

struct UploadPartURLResponse: Decodable, Sendable {
    let partNumber: Int
    let url: URL
}

struct StudioVideoEnvelope: Decodable, Sendable {
    let video: StudioVideo
}

struct CommentsResponse: Decodable, Sendable {
    let items: [SmolishComment]
    let pinned: [SmolishComment]
    let nextCursor: String?
    let commentsEnabled: Bool
    let commentsCount: Int?

    private enum CodingKeys: String, CodingKey { case items, pinned, nextCursor, commentsEnabled, commentsCount }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([SmolishComment].self, forKey: .items) ?? []
        pinned = try container.decodeIfPresent([SmolishComment].self, forKey: .pinned) ?? []
        nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
        commentsEnabled = try container.decodeIfPresent(Bool.self, forKey: .commentsEnabled) ?? true
        commentsCount = try container.decodeIfPresent(Int.self, forKey: .commentsCount)
    }
}

struct SmolishComment: Identifiable, Decodable, Sendable {
    let id: String
    let body: String
    let authorId: String?
    let authorHandle: String
    let authorName: String
    let authorAvatar: URL?
    let createdAt: Date?
    let likesCount: Int
    let repliesCount: Int
    let viewerReaction: String?
    let pinnedAt: Date?
    let ownerLiked: Bool?
    let parentId: String?
}

struct PostedCommentResponse: Decodable, Sendable {
    let comment: SmolishComment
    let commentsCount: Int?
}

struct SearchUsersResponse: Decodable, Sendable {
    let items: [SearchUser]
    let nextCursor: String?
}

struct SearchUser: Identifiable, Decodable, Hashable, Sendable {
    let userId: String
    let handle: String
    let displayName: String
    let bio: String?
    let avatarUrl: URL?
    let followersCount: Int
    let videosCount: Int
    let braincells: Int
    let braincellsProvisional: Bool
    let viewerFollows: Bool

    var id: String { userId }
}

struct MentionsResponse: Decodable, Sendable {
    let items: [MentionUser]
}

struct MentionUser: Identifiable, Decodable, Hashable, Sendable {
    let userId: String
    let handle: String
    let displayName: String
    let avatarUrl: URL?
    let followersCount: Int
    let viewerFollows: Bool

    var id: String { userId }
}

struct CreatorSummary: Hashable, Sendable {
    let userId: String
    let handle: String
    let displayName: String
    let bio: String?
    let avatarURL: URL?
    let followersCount: Int
    let videosCount: Int?
    let braincells: Int
    let viewerFollows: Bool

    init(video: SmolishVideo) {
        userId = video.authorId
        handle = video.authorHandle
        displayName = video.authorName
        bio = nil
        avatarURL = video.authorAvatar
        followersCount = video.authorFollowers
        videosCount = nil
        braincells = video.authorBraincells
        viewerFollows = video.viewerFollows
    }

    init(user: SearchUser) {
        userId = user.userId
        handle = user.handle
        displayName = user.displayName
        bio = user.bio
        avatarURL = user.avatarUrl
        followersCount = user.followersCount
        videosCount = user.videosCount
        braincells = user.braincells
        viewerFollows = user.viewerFollows
    }
}

struct StudioAnalytics: Sendable {
    let metrics: [AnalyticsMetric]
    let points: [AnalyticsPoint]
}

struct AnalyticsMetric: Identifiable, Sendable {
    let id: String
    let title: String
    let value: Double
    let format: AnalyticsMetricFormat
}

enum AnalyticsMetricFormat: Sendable { case count, seconds, percentage }

struct AnalyticsPoint: Identifiable, Sendable {
    let id: String
    let date: Date
    let views: Double
}
