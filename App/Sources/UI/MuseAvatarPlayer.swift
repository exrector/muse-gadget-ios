import ImageIO
import os
import SwiftUI
import UIKit

/// One state's animation, decoded ahead of time at the size it takes on screen. Whatever fits the
/// budget stays decoded, so a short loop costs nothing after its first pass; a larger one keeps a
/// moving window of the next frames.
final class MuseAvatarClip {
    let info: MuseAvatarAnimationInfo
    let pixelSize: Int
    let capacity: Int

    /// Called once on the main thread, when the first frames are ready to play.
    var onBuffered: (() -> Void)?

    private let source: CGImageSource
    private let queue = DispatchQueue(label: "MuseGadgetLegacy.avatarClip", qos: .userInitiated)
    private let lock = NSLock()
    private var frames: [Int: CGImage] = [:]
    private var wantedStart = 0
    private var isFilling = false
    private var didBuffer = false

    init?(url: URL, targetPixelSize: Int, byteBudget: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let info = MuseAvatarAnimationInfo(source: source) else { return nil }
        self.source = source
        self.info = info
        // Never larger than the file itself, which would only cost memory.
        pixelSize = max(1, min(targetPixelSize, max(info.pixelWidth, info.pixelHeight)))
        capacity = min(info.delays.count, max(3, byteBudget / max(1, pixelSize * pixelSize * 4)))
    }

    var isBuffered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didBuffer
    }

    func delay(at index: Int) -> TimeInterval { info.delays[index] }

    /// The frame if it is decoded yet. Asking also moves the window forward to it.
    func frame(at index: Int) -> CGImage? {
        lock.lock()
        let frame = frames[index]
        wantedStart = index
        let shouldStart = !isFilling
        if shouldStart { isFilling = true }
        lock.unlock()
        if shouldStart { queue.async { self.fill() } }
        return frame
    }

    private func fill() {
        let count = info.delays.count
        let started = Date()
        while true {
            lock.lock()
            let window = (0..<capacity).map { (wantedStart + $0) % count }
            guard let missing = window.first(where: { frames[$0] == nil }) else {
                let kept = Set(window)
                frames = frames.filter { kept.contains($0.key) }
                isFilling = false
                let firstTime = !didBuffer
                didBuffer = true
                lock.unlock()
                if firstTime { announceBuffered(after: Date().timeIntervalSince(started)) }
                return
            }
            lock.unlock()
            let frame = CGImageSourceCreateThumbnailAtIndex(source, missing, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: pixelSize
            ] as CFDictionary)
            lock.lock()
            // A frame that cannot be decoded is skipped by repeating its neighbour, not by stalling.
            frames[missing] = frame ?? frames[(missing + count - 1) % count] ?? frames.values.first
            let stuck = frames[missing] == nil
            if stuck { isFilling = false }
            lock.unlock()
            if stuck { return }
        }
    }

    private func announceBuffered(after seconds: TimeInterval) {
        Self.logger.info("""
            Avatar buffered \(self.capacity, privacy: .public) of \(self.info.delays.count, privacy: .public) frames, \
            \(self.info.pixelWidth, privacy: .public)x\(self.info.pixelHeight, privacy: .public) \
            to \(self.pixelSize, privacy: .public) px, \(Int(seconds * 1000), privacy: .public) ms
            """)
        DispatchQueue.main.async { self.onBuffered?() }
    }

    private static let logger = Logger(subsystem: "com.exrector.MuseGadgetLegacy", category: "avatar")
}

/// Plays clips with a display link. The next frame is shown only once it is decoded and its time
/// has come, so a slow device plays a little slower instead of jumping.
final class MuseAvatarPlayerView: UIView {
    private var files: [MuseAvatarState: URL] = [:]
    private var state = MuseAvatarState.idle
    private var version = UUID()
    private var clips: [MuseAvatarState: MuseAvatarClip] = [:]
    private var playing: MuseAvatarClip?
    private var index = 0
    private var nextFrameAt: CFTimeInterval = 0
    private var link: CADisplayLink?
    private var pixelSize = 0

    /// A share of memory, split between the four states.
    private static let clipBudget = Int(min(ProcessInfo.processInfo.physicalMemory / 128, 64 * 1024 * 1024))

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.contentsGravity = .resizeAspect
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    func update(files: [MuseAvatarState: URL], state: MuseAvatarState, version: UUID) {
        if version != self.version {
            self.version = version
            self.files = files
            clips = [:]
            playing = nil
        }
        self.state = state
        prepareCurrentState()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let target = Int((max(bounds.width, bounds.height) * scale).rounded(.up))
        guard target > 0, target != pixelSize else { return }
        pixelSize = target
        clips = [:]
        prepareCurrentState()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let link = CADisplayLink(target: MuseWeakTarget(self), selector: #selector(MuseWeakTarget.tick))
        link.preferredFramesPerSecond = 30
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    deinit { link?.invalidate() }

    private func prepareCurrentState() {
        guard pixelSize > 0, let url = files[state] ?? files[.idle] else { return }
        let key = files[state] == nil ? MuseAvatarState.idle : state
        let clip: MuseAvatarClip
        if let existing = clips[key] {
            clip = existing
        } else {
            guard let created = MuseAvatarClip(url: url, targetPixelSize: pixelSize, byteBudget: Self.clipBudget) else { return }
            clips[key] = created
            clip = created
        }
        guard clip !== playing else { return }
        if clip.isBuffered {
            play(clip)
        } else {
            // The current animation keeps going until the new one is ready, so nothing flashes.
            clip.onBuffered = { [weak self, weak clip] in
                guard let self, let clip, self.clipForCurrentState === clip else { return }
                self.play(clip)
            }
            _ = clip.frame(at: 0)
        }
    }

    private var clipForCurrentState: MuseAvatarClip? {
        clips[files[state] == nil ? .idle : state]
    }

    private func play(_ clip: MuseAvatarClip) {
        playing = clip
        index = 0
        nextFrameAt = 0
    }

    fileprivate func tick() {
        guard let playing, let link else { return }
        let now = link.timestamp
        guard now >= nextFrameAt else { return }
        let next = nextFrameAt == 0 ? 0 : (index + 1) % playing.info.delays.count
        guard let frame = playing.frame(at: next) else { return }
        layer.contents = frame
        index = next
        nextFrameAt = now + playing.delay(at: next)
    }
}

/// A display link keeps its target alive, which would keep a removed view alive with it.
private final class MuseWeakTarget {
    private weak var view: MuseAvatarPlayerView?

    init(_ view: MuseAvatarPlayerView) { self.view = view }

    @objc func tick() { view?.tick() }
}

struct MuseAvatarPlayer: UIViewRepresentable {
    let files: [MuseAvatarState: URL]
    let state: MuseAvatarState
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
        view.update(files: files, state: state, version: version)
    }
}
