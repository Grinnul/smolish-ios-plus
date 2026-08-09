import SwiftUI

@MainActor
final class CommentsViewModel: ObservableObject {
    @Published private(set) var comments: [SmolishComment] = []
    @Published private(set) var pinned: [SmolishComment] = []
    @Published private(set) var replies: [String: [SmolishComment]] = [:]
    @Published private(set) var expandedReplies: Set<String> = []
    @Published private(set) var mentionResults: [MentionUser] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var isPosting = false
    @Published var draft = ""
    @Published var replyTarget: SmolishComment?
    @Published var errorMessage: String?

    private let videoID: String
    private var nextCursor: String?

    init(videoID: String) { self.videoID = videoID }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await APIClient.shared.comments(videoID: videoID)
            pinned = response.pinned; comments = response.items; nextCursor = response.nextCursor; errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func loadMore() async {
        guard let nextCursor, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let response = try await APIClient.shared.comments(videoID: videoID, cursor: nextCursor)
            let known = Set(comments.map(\.id))
            comments.append(contentsOf: response.items.filter { !known.contains($0.id) })
            self.nextCursor = response.nextCursor
        } catch { errorMessage = error.localizedDescription }
    }

    func toggleReplies(for comment: SmolishComment) async {
        if expandedReplies.contains(comment.id) { expandedReplies.remove(comment.id); return }
        expandedReplies.insert(comment.id)
        guard replies[comment.id] == nil else { return }
        do { replies[comment.id] = try await APIClient.shared.comments(videoID: videoID, parentID: comment.id).items }
        catch { errorMessage = error.localizedDescription }
    }

    func beginReply(to comment: SmolishComment) {
        replyTarget = comment
        let mention = "@\(comment.authorHandle) "
        if !draft.contains(mention) { draft = mention + draft }
    }

    func cancelReply() { replyTarget = nil }

    func post() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isPosting else { return }
        isPosting = true
        defer { isPosting = false }
        do {
            let rootID = replyTarget.map { $0.parentId ?? $0.id }
            let response = try await APIClient.shared.postComment(videoID: videoID, body: text, parentID: rootID)
            if let rootID {
                replies[rootID, default: []].append(response.comment)
                expandedReplies.insert(rootID)
            } else { comments.insert(response.comment, at: 0) }
            draft = ""; replyTarget = nil; mentionResults = []; errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func updateMentions() async {
        guard let query = activeMentionQuery else { mentionResults = []; return }
        do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
        guard !Task.isCancelled else { return }
        do { mentionResults = try await APIClient.shared.mentionSuggestions(query: query).items }
        catch { mentionResults = [] }
    }

    func insertMention(_ user: MentionUser) {
        guard let range = activeMentionRange else { return }
        draft.replaceSubrange(range, with: "@\(user.handle) ")
        mentionResults = []
    }

    func toggleReaction(_ comment: SmolishComment) async {
        do { try await APIClient.shared.setCommentReaction(commentID: comment.id, liked: comment.viewerReaction != "like") }
        catch { errorMessage = error.localizedDescription }
    }

    private var activeMentionQuery: String? {
        guard let range = activeMentionRange else { return nil }
        return String(draft[range].dropFirst())
    }

    private var activeMentionRange: Range<String.Index>? {
        let end = draft.endIndex
        let start = draft[..<end].lastIndex(where: { $0.isWhitespace }).map { draft.index(after: $0) } ?? draft.startIndex
        guard start < end, draft[start] == "@" else { return nil }
        let token = draft[start..<end]
        guard token.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return start..<end
    }
}

struct CommentsView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var model: CommentsViewModel
    @FocusState private var composerFocused: Bool

    init(videoID: String) { _model = StateObject(wrappedValue: CommentsViewModel(videoID: videoID)) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                commentList
                if let error = model.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal).padding(.top, 6)
                }
                composer
            }
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await model.load() }
        .task(id: model.draft) { await model.updateMentions() }
    }

    @ViewBuilder private var commentList: some View {
        if model.isLoading && model.comments.isEmpty { ProgressView().frame(maxHeight: .infinity) }
        else if model.comments.isEmpty && model.pinned.isEmpty {
            ContentUnavailableView("No comments yet", systemImage: "bubble.right", description: Text("Start the conversation."))
                .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !model.pinned.isEmpty {
                        sectionLabel("Pinned")
                        ForEach(model.pinned) { commentRow($0, pinned: true, inset: false) }
                    }
                    if !model.comments.isEmpty {
                        if !model.pinned.isEmpty { sectionLabel("Comments") }
                        ForEach(model.comments) { comment in
                            commentRow(comment, pinned: false, inset: false)
                                .onAppear { if comment.id == model.comments.last?.id { Task { await model.loadMore() } } }
                            if model.expandedReplies.contains(comment.id) {
                                ForEach(model.replies[comment.id] ?? []) { reply in commentRow(reply, pinned: false, inset: true) }
                            }
                        }
                    }
                    if model.isLoadingMore { ProgressView().padding() }
                }
                .padding(.horizontal)
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if let target = model.replyTarget {
                HStack {
                    Text("Replying to @\(target.authorHandle)").font(.caption).foregroundStyle(.secondary)
                    Spacer(); Button("Cancel") { model.cancelReply() }.font(.caption.bold())
                }
            }
            if !model.mentionResults.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(model.mentionResults) { user in
                            Button { model.insertMention(user); composerFocused = true } label: {
                                HStack(spacing: 7) {
                                    CreatorAvatar(url: user.avatarUrl, size: 28)
                                    Text("@\(user.handle)").font(.caption.bold())
                                }
                                .padding(.horizontal, 9).padding(.vertical, 6).background(.secondary.opacity(0.14), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField(session.isAuthenticated ? "Add a comment… Use @ to tag" : "Sign in from Profile to comment", text: $model.draft, axis: .vertical)
                    .lineLimit(1...4).focused($composerFocused)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 18)).disabled(!session.isAuthenticated)
                Button { Task { await model.post() } } label: {
                    Image(systemName: "arrow.up").font(.headline.bold()).frame(width: 40, height: 40)
                        .background(Color.smolishBlue, in: Circle()).foregroundStyle(.white)
                }
                .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isPosting || !session.isAuthenticated)
            }
        }
        .padding().background(.ultraThinMaterial)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
    }

    private func commentRow(_ comment: SmolishComment, pinned: Bool, inset: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            CreatorAvatar(url: comment.authorAvatar, size: inset ? 32 : 40)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(comment.authorName).font(.subheadline.bold()).lineLimit(1)
                    Text("@\(comment.authorHandle)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Color.smolishBlue) }
                }
                Text(comment.body).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 14) {
                    if let date = comment.createdAt { Text(date, style: .relative) }
                    Button("Reply") { model.beginReply(to: comment); composerFocused = true }
                    Button { Task { await model.toggleReaction(comment) } } label: {
                        Label(comment.likesCount > 0 ? comment.likesCount.formatted() : "Like", systemImage: comment.viewerReaction == "like" ? "heart.fill" : "heart")
                            .foregroundStyle(comment.viewerReaction == "like" ? .red : .secondary)
                    }
                    if comment.repliesCount > 0 && !inset {
                        Button(model.expandedReplies.contains(comment.id) ? "Hide replies" : "\(comment.repliesCount) replies") {
                            Task { await model.toggleReplies(for: comment) }
                        }
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, inset ? 36 : 0).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider().opacity(0.3) }
    }
}
