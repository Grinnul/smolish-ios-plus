import SwiftUI

struct FeedView: View {
    let isTabActive: Bool
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = FeedViewModel()
    @State private var currentVideoID: String?
    @State private var showSignIn = false

    var body: some View {
        ZStack {
            Color.smolishBlack.ignoresSafeArea()

            if model.isLoading && model.videos.isEmpty {
                ProgressView()
                    .tint(.white)
            } else if let error = model.errorMessage, model.videos.isEmpty {
                ContentUnavailableView {
                    Label("Couldn’t load Smolish", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await model.refresh() } }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                GeometryReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(model.videos) { video in
                                VideoPageView(
                                    video: video,
                                    isActive: isTabActive && scenePhase == .active && currentVideoID == video.id,
                                    onRequiresSignIn: { showSignIn = true }
                                )
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .clipped()
                                .id(video.id)
                                .task { await model.loadMoreIfNeeded(current: video) }
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollIndicators(.hidden)
                    .scrollTargetBehavior(.paging)
                    .scrollClipDisabled(false)
                    .scrollPosition(id: $currentVideoID)
                    .refreshable { await model.refresh() }
                    .onChange(of: model.videos) { _, videos in
                        if currentVideoID == nil || !videos.contains(where: { $0.id == currentVideoID }) {
                            currentVideoID = videos.first?.id
                        }
                    }
                }
            }
        }
        .task { await model.loadIfNeeded() }
        .sheet(isPresented: $showSignIn) { CookieSignInView() }
    }

}
