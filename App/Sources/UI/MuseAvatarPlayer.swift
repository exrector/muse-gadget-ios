import AVFoundation
import SwiftUI
import UIKit

/// Keeps the states the app switches between in preloaded players, and switches by showing another
/// layer, so a change of state needs no loading. The video hardware does the work, even on an old
/// phone. iOS allows only so many players at once, so a movement Muse starts by name is loaded when
/// asked for, and the last one stays ready for a repeat. Every file stays on the device either way.
final class MuseAvatarPlayerView: UIView {
    private struct Track {
        let player: AVQueuePlayer
        let looper: AVPlayerLooper
        let layer: AVPlayerLayer
    }

    private var tracks: [String: Track] = [:]
    private var files: [String: URL] = [:]
    private var version: UUID?
    private var current: String?
    private var lastNamedMovement: String?

    var preparedMovements: Set<String> { Set(tracks.keys) }

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
            self.files = files
            removeTracks()
            for state in MuseAvatarState.allCases {
                if let url = files[state.rawValue] { addTrack(state.rawValue, url: url) }
            }
        }
        show(files[name] != nil ? name : MuseAvatarState.idle.rawValue)
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

    private func removeTrack(_ key: String) {
        guard let track = tracks.removeValue(forKey: key) else { return }
        track.player.pause()
        track.layer.removeFromSuperlayer()
    }

    private func removeTracks() {
        Array(tracks.keys).forEach(removeTrack)
        current = nil
        lastNamedMovement = nil
    }

    private func prepareNamedMovement(_ name: String) {
        guard tracks[name] == nil, let url = files[name] else { return }
        if let lastNamedMovement { removeTrack(lastNamedMovement) }
        addTrack(name, url: url)
        lastNamedMovement = name
    }

    private func show(_ name: String) {
        guard name != current else { return }
        prepareNamedMovement(name)
        guard let next = tracks[name] else { return }
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
