import AVFoundation
import SwiftUI


struct VideoPageView: View {
    let video: SmolishVideo
    let isActive: Bool
    let onRequiresSignIn: () -> Void

    @EnvironmentObject private var session: SessionStore
    @State private var isMuted = false
    @EnvironmentObject private var settings: Settings
    @StateObject private var model = FeedViewModel()
    @State private var liked: Bool
    @State private var saved: Bool
    @State private var following: Bool
    @State private var isDescriptionExpanded = false
    @State private var showComments = false
    @State private var showCreator = false
    @State private var showHeart = false
    @State private var actionError: String?

    init(video: SmolishVideo, isActive: Bool, onRequiresSignIn: @escaping () -> Void) {
        self.video = video
        self.isActive = isActive
        self.onRequiresSignIn = onRequiresSignIn
        _liked = State(initialValue: video.viewerLiked)
        _saved = State(initialValue: video.viewerSaved)
        _following = State(initialValue: video.viewerFollows)
    }

    var body: some View {
        ZStack {
            LoopingVideoPlayer(url: video.src, shouldPlay: isActive && !model.isPaused, isMuted: isMuted)
            
            LinearGradient(
                colors: [.clear, .clear, .black.opacity(0.82)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            VStack {
                Spacer()
                HStack(alignment: .bottom, spacing: 14) {
                    metadata
                    Spacer(minLength: 4)
                    actions
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 18)
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { model.isPaused.toggle() }
        .onTapGesture(count: 2) {
            toggleLike()
            triggerHeart()
        }
        .overlay {
            if model.isPaused {
                Image(systemName: "play.fill")
                    .font(.title2.weight(.bold))
                    .padding(17)
                    .background(.black.opacity(0.58), in: Circle())
                    .transition(.scale.combined(with: .opacity))
                    .allowsHitTesting(false)
            }
            if showHeart {
                Image(systemName: liked ? "heart.fill" : "heart.slash.fill")
                    .resizable()
                    .frame(width: 120, height: 120)
                    .foregroundColor(.red)
                    .scaleEffect(showHeart ? 1.0 : 0.5)
                    .opacity(showHeart ? 1.0 : 0.0)
                    .transition(.scale.combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.snappy, value: model.isPaused)
        .onChange(of: isActive) { _, active in if !active { model.isPaused = false } }
        .sheet(isPresented: $showComments) {
            CommentsView(videoID: video.id)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showCreator) {
            CreatorProfileView(summary: CreatorSummary(video: video))
        }
        .alert("Couldn’t complete action", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(actionError ?? "Please try again.") }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Button { showCreator = true } label: {
                    HStack(spacing: 9) {
                    avatar(url: video.authorAvatar, size: 38)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(video.authorName).font(.subheadline.weight(.bold)).lineLimit(1)
                        Text("@\(video.authorHandle)").font(.caption).foregroundStyle(.white.opacity(0.76))
                    }
                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.white.opacity(0.65))
                    }
                }
                .buttonStyle(.plain)
                Button {
                    guard session.isAuthenticated else { onRequiresSignIn(); return }
                    let previous = following
                    following.toggle()
                    Task {
                        do { try await APIClient.shared.setFollowing(userID: video.authorId, following: following) }
                        catch { following = previous; actionError = error.localizedDescription }
                    }
                } label: {
                    Image(systemName: following ? "checkmark" : "plus")
                        .font(.caption.bold()).frame(width: 26, height: 26)
                        .background(following ? Color.white.opacity(0.18) : settings.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(following ? "Following" : "Follow")
            }

            if !video.title.isEmpty { Text(video.title).font(.headline).lineLimit(2) }
            if !video.description.isEmpty {
                Text(video.description)
                    .font(.subheadline)
                    .lineLimit(isDescriptionExpanded ? nil : 2)
                    .onTapGesture { isDescriptionExpanded.toggle() }
            }
            HStack(spacing: 11) {
                Label(video.viewsCount.formatted(.number.notation(.compactName)), systemImage: "play")
                Label(video.authorBraincells.formatted(.number.notation(.compactName)), systemImage: "brain.head.profile")
                    .foregroundStyle(settings.accent)
                if video.aiGenerated { Label("AI", systemImage: "sparkles") }
                if video.epilepsyWarning { Label("Flashing", systemImage: "bolt.trianglebadge.exclamationmark") }
            }
            .font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.72))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: 285, alignment: .leading)
    }

    private var actions: some View {
        VStack(spacing: 20) {
            action(icon: liked ? "heart.fill" : "heart", count: displayedLikes, tint: liked ? .red : .white) { toggleLike() }
            action(icon: "bubble.right", count: video.commentsCount) { showComments = true }
            ShareLink(item: URL(string: "https://smolish.com/v/\(video.id)")!) {
                Image(systemName: "square.and.arrow.up").frame(width: 30, height: 30)
            }
            Menu {
                Button { toggleBookmark() } label: {
                    Label(saved ? "Remove bookmark" : "Bookmark", systemImage: saved ? "bookmark.slash" : "bookmark")
                }
                Button { isMuted.toggle() } label: {
                    Label(isMuted ? "Turn sound on" : "Mute", systemImage: isMuted ? "speaker.wave.2" : "speaker.slash")
                }
                Divider()
                Button("Not interested", systemImage: "eye.slash") { requireSignIn() }
                Button("Report", systemImage: "flag", role: .destructive) { requireSignIn() }
            } label: {
                Image(systemName: "ellipsis").frame(width: 30, height: 30)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
        .glassEffect(.regular.interactive())
        .font(.title2.weight(.medium))
        .foregroundStyle(.white)
    }
    private func triggerHeart() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.5)) {
            showHeart = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            withAnimation(.easeOut(duration: 0.3)) {
                showHeart = false
            }
        }
    }
    
    
    private var displayedLikes: Int {
        video.likesCount + (liked == video.viewerLiked ? 0 : (liked ? 1 : -1))
    }

    private func action(icon: String, count: Int, tint: Color = .white, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 3) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(max(0, count).formatted(.number.notation(.compactName))).font(.caption2.weight(.bold))
            }
            .frame(minWidth: 34)
        }
    }

    private func requireSignIn() {
        guard session.isAuthenticated else { onRequiresSignIn(); return }
    }

    private func toggleLike() {
        guard session.isAuthenticated else { onRequiresSignIn(); return }
        let previous = liked
        liked.toggle()
        Task {
            do { try await APIClient.shared.setLiked(videoID: video.id, liked: liked) }
            catch { liked = previous; actionError = error.localizedDescription }
        }
    }

    private func toggleBookmark() {
        guard session.isAuthenticated else { onRequiresSignIn(); return }
        let previous = saved
        saved.toggle()
        Task {
            do { try await APIClient.shared.setBookmarked(videoID: video.id, bookmarked: saved) }
            catch { saved = previous; actionError = error.localizedDescription }
        }
    }

    private func avatar(url: URL?, size: CGFloat) -> some View {
        AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: {
            settings.accent.overlay(Image(systemName: "person.fill").foregroundStyle(.white))
        }
        .frame(width: size, height: size).clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
    }
}

struct LoopingVideoPlayer: UIViewRepresentable {
    let url: URL
    let shouldPlay: Bool
    let isMuted: Bool
    @StateObject var model = FeedViewModel()
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        context.coordinator.player = player
        context.coordinator.looper = AVPlayerLooper(player: player,templateItem: item)
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        context.coordinator.player?.isMuted = isMuted
        if shouldPlay {
            Task {
                model.isPaused = true
                try? await Task.sleep(for: .milliseconds(1))
                model.isPaused = false
            }
            context.coordinator.playWhenReady()
        } else {
            context.coordinator.player?.pause()
        }
    }

    static func dismantleUIView(_ view: PlayerView, coordinator: Coordinator) {
        coordinator.player?.pause()

        coordinator.looper?.disableLooping()
        coordinator.looper = nil

        coordinator.player?.removeAllItems()
        coordinator.player = nil

        view.playerLayer.player = nil
    }

    final class Coordinator {
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?
        var readyObserver: NSKeyValueObservation?

        func playWhenReady() {
            guard let player,
                  let item = player.currentItem else { return }

            if item.status == .readyToPlay {
                player.play()
                return
            }

            readyObserver = item.observe(\.status, options: [.initial, .new]) {
                [weak self] item, _ in

                guard item.status == .readyToPlay else {
                    return
                }

                self?.player?.play()
                self?.readyObserver = nil
            }
        }
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

private enum MediaAudioSession {
    private static var isConfigured = false

    static func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            if !isConfigured {
                try session.setCategory(.playback, mode: .moviePlayback)
                isConfigured = true
            }
            try session.setActive(true)
        } catch {
            // AVPlayer will retry activation when the current interruption ends.
        }
    }
}
