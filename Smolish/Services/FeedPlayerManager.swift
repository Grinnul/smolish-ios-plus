import AVFoundation

@MainActor
final class FeedPlayerManager: ObservableObject {
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private(set) var currentVideoID: String?

    func show(videoID: String, url: URL) {
        guard currentVideoID != videoID else { return }
        currentVideoID = videoID
        player.removeAllItems()
        let item = AVPlayerItem(url: url)
        looper = AVPlayerLooper(player: player, templateItem: item)
    }

    func play() { player.play() }
    func pause() { player.pause() }
    func setMuted(_ muted: Bool) { player.isMuted = muted }
}
