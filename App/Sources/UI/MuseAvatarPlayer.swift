import AVFoundation
import SwiftUI
import UIKit

/// Plays each ready video from its own preloaded player, and switches by showing another layer, so
/// a change of movement needs no loading. The video hardware does the work, even on an old phone.
final class MuseAvatarPlayerView: UIView {
    private struct Track {
        let player: AVQueuePlayer
        let looper: AVPlayerLooper
        let layer: AVPlayerLayer
    }

    private var tracks: [String: Track] = [:]
    private var version: UUID?
    private var current: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(resume),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) { nil }

    func update(files: [String: URL], name: String, version: UUID) {
        if version != self.version {
            self.version = version
            removeTracks()
            for (key, url) in files { addTrack(key, url: url) }
        }
        show(tracks[name] != nil ? name : MuseAvatarState.idle.rawValue)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for track in tracks.values { track.layer.frame = bounds }
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            tracks.values.forEach { $0.player.pause() }
        } else {
            resume()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        tracks.values.forEach { $0.player.pause() }
    }

    private func addTrack(_ key: String, url: URL) {
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        let looper = AVPlayerLooper(player: player, templateItem: item)
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.frame = bounds
        playerLayer.isHidden = true
        layer.addSublayer(playerLayer)
        tracks[key] = Track(player: player, looper: looper, layer: playerLayer)
    }

    private func removeTracks() {
        for track in tracks.values {
            track.player.pause()
            track.layer.removeFromSuperlayer()
        }
        tracks = [:]
        current = nil
    }

    private func show(_ name: String) {
        guard name != current, let next = tracks[name] else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        next.layer.isHidden = false
        if let current, let previous = tracks[current] {
            previous.layer.isHidden = true
            previous.player.pause()
        }
        CATransaction.commit()
        current = name
        next.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        if window != nil { next.player.play() }
    }

    @objc private func resume() {
        guard window != nil, let current else { return }
        tracks[current]?.player.play()
    }
}

struct MuseAvatarPlayer: UIViewRepresentable {
    let files: [String: URL]
    let name: String
    let version: UUID

    func makeUIView(context: Context) -> MuseAvatarPlayerView {
        let view = MuseAvatarPlayerView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ view: MuseAvatarPlayerView, context: Context) {
        view.update(files: files, name: name, version: version)
    }
}
