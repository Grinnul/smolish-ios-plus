import Foundation

@MainActor
final class FeedViewModel: ObservableObject {
    @Published private(set) var videos: [SmolishVideo] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published var errorMessage: String?

    private var nextCursor: String?
    private var hasLoaded = false

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
            let response = try await APIClient.shared.feed()
            videos = response.items
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
