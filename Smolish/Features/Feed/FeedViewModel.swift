import Foundation

@MainActor
final class FeedViewModel: ObservableObject {
    @Published private(set) var videos: [SmolishVideo] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published var errorMessage: String?
    @Published var isPaused = false

    private var nextCursor: String?
    var hasLoaded = false
    
    private var loadContinuation: CheckedContinuation<Void, Never>?

    func waitUntilLoaded() async {
        if hasLoaded {
            return
        }

        await withCheckedContinuation { continuation in
            loadContinuation = continuation
        }
    }
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await refresh()
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let previousOrder = videos.map(\.id)
            let response = try await APIClient.shared.feed(refreshNonce: UUID().uuidString)
            var refreshed = response.items
            if refreshed.count > 1, refreshed.map(\.id) == previousOrder {
                refreshed.rotateFirstToEnd()
            }
            videos = refreshed
            nextCursor = response.nextCursor
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMoreIfNeeded(current video: SmolishVideo) async {
        guard video.id == videos.suffix(2).first?.id,
              let cursor = nextCursor,
              !isLoadingMore else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let response = try await APIClient.shared.feed(cursor: cursor)
            let known = Set(videos.map(\.id))
            videos.append(contentsOf: response.items.filter { !known.contains($0.id) })
            nextCursor = response.nextCursor
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension Array {
    mutating func rotateFirstToEnd() {
        guard !isEmpty else { return }
        append(removeFirst())
    }
}
