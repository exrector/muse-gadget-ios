import AVFoundation
import Foundation
import ImageIO
import os
import UIKit

enum MuseImageScaler {
    /// Decodes through ImageIO so a large file never has to fit in memory at full size.
    static func scaled(_ data: Data, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// The states the app itself plays. Muse may add any other movements, which it starts by name.
enum MuseAvatarState: String, CaseIterable {
    case idle, listening, thinking, speaking

    /// The stored name for what Muse calls an animation, or nil if it cannot be a file name.
    static func animationName(_ value: String) -> String? {
        let name = value.lowercased()
        switch name {
        case "working": return thinking.rawValue
        case "talking": return speaking.rawValue
        default: break
        }
        return name.range(of: "^[a-z0-9_-]{1,32}$", options: .regularExpression) == nil ? nil : name
    }
}

/// Turns an animation into a video once, so it plays on the video hardware from then on. WebP has
/// to be decoded in software for every frame of every loop, which an old device cannot do smoothly.
enum MuseAvatarVideoBuilder {
    /// The largest the avatar gets on this device. A file is never enlarged past its own size.
    static var maxPixelSize: Int {
        UIDevice.current.userInterfaceIdiom == .pad ? 1024 : 256
    }

    enum Failure: Error { case notAnImage, encodingFailed }

    static func build(source url: URL, destination: URL, maxPixelSize: Int = maxPixelSize) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let info = MuseAvatarAnimationInfo(source: source) else { throw Failure.notAnImage }
        let scale = min(1, Double(maxPixelSize) / Double(max(info.pixelWidth, info.pixelHeight)))
        // H.264 needs even dimensions.
        let width = max(2, Int(Double(info.pixelWidth) * scale) & ~1)
        let height = max(2, Int(Double(info.pixelHeight) * scale) & ~1)

        let temporary = destination.appendingPathExtension("building.mp4")
        try? FileManager.default.removeItem(at: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let writer = try AVAssetWriter(outputURL: temporary, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(500_000, width * height * 5)]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        guard writer.startWriting() else { throw Failure.encodingFailed }
        writer.startSession(atSourceTime: .zero)

        var time = 0.0
        for (index, delay) in info.delays.enumerated() {
            try autoreleasepool {
                guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(width, height)
                ] as CFDictionary), let pool = adaptor.pixelBufferPool else { throw Failure.encodingFailed }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let buffer else { throw Failure.encodingFailed }
                draw(frame, into: buffer, width: width, height: height)
                while !input.isReadyForMoreMediaData { usleep(2_000) }
                let presentation = CMTime(seconds: time, preferredTimescale: 600)
                guard adaptor.append(buffer, withPresentationTime: presentation) else { throw Failure.encodingFailed }
            }
            time += delay
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: time, preferredTimescale: 600))
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else { throw Failure.encodingFailed }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private static func draw(_ frame: CGImage, into buffer: CVPixelBuffer, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        // Video has no transparency, and these files are drawn for a light background.
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
}

/// What an animation file holds, read without decoding its frames.
struct MuseAvatarAnimationInfo {
    let delays: [TimeInterval]
    let pixelWidth: Int
    let pixelHeight: Int

    var duration: TimeInterval { delays.reduce(0, +) }

    /// Accepts GIF, APNG and animated WebP. Nil when the source holds no image at all.
    init?(source: CGImageSource) {
        let count = CGImageSourceGetCount(source)
        guard count > 0,
              let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = first[kCGImagePropertyPixelWidth] as? Int,
              let height = first[kCGImagePropertyPixelHeight] as? Int else { return nil }
        delays = (0..<count).map { Self.frameDelay(source, at: $0) }
        pixelWidth = width
        pixelHeight = height
    }

    init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        self.init(source: source)
    }

    /// Reads a video file. Nil when it has no video the device can play.
    init?(videoAt url: URL) {
        let asset = AVURLAsset(url: url)
        guard asset.isPlayable, let track = asset.tracks(withMediaType: .video).first else { return nil }
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration > 0 else { return nil }
        let size = track.naturalSize.applying(track.preferredTransform)
        let frames = max(1, Int((duration * Double(max(track.nominalFrameRate, 1))).rounded()))
        delays = Array(repeating: duration / Double(frames), count: frames)
        pixelWidth = Int(abs(size.width))
        pixelHeight = Int(abs(size.height))
    }

    private static func frameDelay(_ source: CGImageSource, at index: Int) -> TimeInterval {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let keys: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime)
        ]
        for (dictionary, unclamped, clamped) in keys {
            guard let values = properties?[dictionary] as? [CFString: Any] else { continue }
            let delay = (values[unclamped] as? Double) ?? (values[clamped] as? Double) ?? 0
            return delay >= 0.02 ? delay : 0.1
        }
        return 0.1
    }
}

/// Keeps the picture Muse gave this device. Muse has no route for reading an agent's avatar, so it
/// draws one on request, as the SDK's avatar recipe does, and the gadget keeps the result.
final class MuseAvatarStore {
    enum Failure: Error {
        case notAnImage
        case saveFailed
    }

    static let maxPixelSize = 1024

    private let directory: URL
    private var file: URL { directory.appendingPathComponent("avatar.png") }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("agent-avatar", isDirectory: true)
    }

    func load() -> Data? {
        try? Data(contentsOf: file)
    }

    /// Decodes and shrinks the image before anything is written, so a bad file leaves the old avatar.
    func save(imageData: Data) throws -> Data {
        guard let png = MuseImageScaler.scaled(imageData, maxPixelSize: Self.maxPixelSize)?.pngData() else {
            throw Failure.notAnImage
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: file, options: .atomic)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var stored = file
            try stored.setResourceValues(values)
        } catch {
            throw Failure.saveFailed
        }
        return png
    }

    private func animationFile(_ name: String) -> URL {
        directory.appendingPathComponent("\(name).animation")
    }

    private func videoFile(_ name: String) -> URL {
        directory.appendingPathComponent("\(name).mp4")
    }

    private func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private var storedFiles: [String] {
        // Names hold no dots, which leaves out a video still being built.
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    private func names(withExtension suffix: String) -> [String] {
        storedFiles
            .filter { $0.hasSuffix(suffix) }
            .map { String($0.dropLast(suffix.count)) }
            .filter { !$0.contains(".") }
    }

    var availableAnimations: [String] {
        Set(names(withExtension: ".animation") + names(withExtension: ".mp4")).sorted()
    }

    /// An animation with no video yet, or a video older than a new file. The old video stays until
    /// the new one is ready, so the avatar never goes still in between.
    var animationsToBuild: [String] {
        names(withExtension: ".animation").filter { name in
            guard let video = modified(videoFile(name)) else { return true }
            guard let file = modified(animationFile(name)) else { return false }
            return file > video
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var target = url
            try data.write(to: target, options: .atomic)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try target.setResourceValues(values)
        } catch {
            throw Failure.saveFailed
        }
    }

    /// An MP4 is ready to play as it is. Anything else is kept to be turned into a video. The same
    /// file arriving again changes nothing, so it costs no rebuild.
    func saveAnimation(_ data: Data, name: String) throws -> MuseAvatarAnimationInfo {
        if data.count > 8, data[data.startIndex + 4..<data.startIndex + 8] == Data("ftyp".utf8) {
            let trial = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
            defer { try? FileManager.default.removeItem(at: trial) }
            do { try data.write(to: trial) } catch { throw Failure.saveFailed }
            guard let info = MuseAvatarAnimationInfo(videoAt: trial) else { throw Failure.notAnImage }
            if name == MuseAvatarState.idle.rawValue, let poster = Self.firstFrame(ofVideoAt: trial) {
                _ = try save(imageData: poster)
            }
            try write(data, to: videoFile(name))
            try? FileManager.default.removeItem(at: animationFile(name))
            return info
        }
        guard let info = MuseAvatarAnimationInfo(data: data) else { throw Failure.notAnImage }
        if (try? Data(contentsOf: animationFile(name))) == data { return info }
        if name == MuseAvatarState.idle.rawValue { _ = try save(imageData: data) }
        try write(data, to: animationFile(name))
        return info
    }

    private static func firstFrame(ofVideoAt url: URL) -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        guard let frame = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return UIImage(cgImage: frame).pngData()
    }

    /// Builds what `animationsToBuild` lists, reporting as each one finishes. A failure, such as the
    /// app leaving the screen, leaves the file to try again next time.
    func buildMissingVideos(onProgress: (Int) -> Void = { _ in }) {
        // Builds run one at a time, so anything left here was cut off, by a reinstall for example.
        for file in storedFiles where file.hasSuffix(".building.mp4") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
        for name in animationsToBuild {
            onProgress(animationsToBuild.count)
            do {
                try MuseAvatarVideoBuilder.build(source: animationFile(name), destination: videoFile(name))
                var target = videoFile(name)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try target.setResourceValues(values)
            } catch {
                continue
            }
        }
        onProgress(animationsToBuild.count)
    }

    /// What the VM's list said about a file when it was last fetched, to notice a new version.
    func fingerprint(of name: String) -> String? {
        try? String(contentsOf: directory.appendingPathComponent("\(name).fingerprint"), encoding: .utf8)
    }

    func setFingerprint(_ fingerprint: String, of name: String) {
        try? fingerprint.write(
            to: directory.appendingPathComponent("\(name).fingerprint"),
            atomically: true,
            encoding: .utf8
        )
    }

    func videoFiles() -> [String: URL] {
        var files: [String: URL] = [:]
        for name in names(withExtension: ".mp4") { files[name] = videoFile(name) }
        return files
    }

    func duration(of name: String) -> TimeInterval? {
        MuseAvatarAnimationInfo(videoAt: videoFile(name))?.duration
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Backs the commands that show a VM file. The file comes only from the paired VM, never from a
/// URL, so these commands cannot make the device reach anywhere new.
final class MuseVMImageService {
    typealias FileReader = (String, Int, @escaping (Result<Data, Error>) -> Void) -> Void

    static let maxFileBytes = 32 * 1024 * 1024
    static let maxDrawnPixelSize = 1600

    /// Set once the runtime exists; the command registry has to be built before it.
    var readVMFile: FileReader?
    /// Asks Muse to set up its avatar, with nothing shown in the chat. Called when the VM has no list.
    var askMuseForAvatar: (() -> Void)?

    private let store: MuseAvatarStore
    private let videoQueue = DispatchQueue(label: "MuseGadgetLegacy.avatarVideos", qos: .userInitiated)

    init(store: MuseAvatarStore = MuseAvatarStore()) {
        self.store = store
    }

    func currentAvatar() -> Data? {
        store.load()
    }

    /// The relative form the SDK's `display.draw_file` takes, such as `workspace/picture.png`.
    static func isValidVMPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 512, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        guard path.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    func avatarVideoFiles() -> [String: URL] {
        store.videoFiles()
    }

    /// Runs in the background, once for each new animation.
    func buildAvatarVideos() {
        videoQueue.async { [store] in
            var last: Int?
            store.buildMissingVideos { remaining in
                Self.post(.museAvatarPreparing, remaining)
                if let last, remaining < last { Self.post(.museAvatarChanged, nil) }
                last = remaining
            }
        }
    }

    /// Where Muse lists its animations, so that every gadget on the account finds them by itself.
    static let manifestPath = "workspace/pal-again/avatars.json"
    private static let syncOffKey = "avatarSyncOff"
    private static let lastAskedKey = "avatarLastAsked"
    /// Muse may be busy or fail, so it is asked again later, but not so often as to be a bother.
    private static let askInterval: TimeInterval = 24 * 3600
    private static let logger = Logger(subsystem: "com.exrector.MuseGadgetLegacy", category: "avatar")

    struct ManifestEntry: Equatable {
        let name: String
        let path: String
        let fingerprint: String
    }

    /// `{"name": "Muse", "animations": {"idle": {"path": "workspace/idle.webp", "bytes": 123}, ...}}`. Anything in
    /// an entry can change, and a change means a new file. Bad entries are left out.
    static func parseManifest(_ data: Data) -> [ManifestEntry]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let animations = root["animations"] as? [String: Any] else { return nil }
        let entries = animations.keys.sorted().compactMap { key -> ManifestEntry? in
            guard let entry = animations[key] as? [String: Any],
                  let name = MuseAvatarState.animationName(key),
                  let path = entry["path"] as? String,
                  isValidVMPath(path),
                  let encoded = try? JSONSerialization.data(withJSONObject: entry, options: .sortedKeys),
                  let fingerprint = String(data: encoded, encoding: .utf8) else { return nil }
            return ManifestEntry(name: name, path: path, fingerprint: fingerprint)
        }
        return Array(entries.prefix(32))
    }

    /// Fetches what is new on the VM. Needs no chat message and costs nothing when all is current.
    func syncFromVM() {
        guard !UserDefaults.standard.bool(forKey: Self.syncOffKey), let readVMFile else { return }
        readVMFile(Self.manifestPath, 256 * 1024) { [weak self] result in
            guard let self else { return }
            if case .failure(MuseVMFileError.status(404)) = result {
                self.askForAvatarIfDue()
                return
            }
            guard case .success(let data) = result, let entries = Self.parseManifest(data) else {
                Self.logger.info("Could not read the avatar list on the VM")
                return
            }
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = root["name"] as? String {
                MuseAgentName.save(name)
            }
            let pending = entries.filter { self.store.fingerprint(of: $0.name) != $0.fingerprint }
            Self.logger.info("Avatar list: \(entries.count, privacy: .public) entries, \(pending.count, privacy: .public) new")
            self.download(pending)
        }
    }

    /// Nobody should have to know that an avatar has to be asked for. The first gadget to find no
    /// list asks Muse, and every other one then fetches what Muse lists.
    private func askForAvatarIfDue() {
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: Self.lastAskedKey) as? Date
        guard last.map({ Date().timeIntervalSince($0) >= Self.askInterval }) ?? true else { return }
        defaults.set(Date(), forKey: Self.lastAskedKey)
        Self.logger.info("No avatar list on the VM, asking Muse")
        askMuseForAvatar?()
    }

    private func download(_ remaining: [ManifestEntry]) {
        guard let entry = remaining.first else {
            buildAvatarVideos()
            return
        }
        let rest = Array(remaining.dropFirst())
        guard let readVMFile else { return }
        readVMFile(entry.path, Self.maxFileBytes) { [weak self] result in
            guard let self else { return }
            if case .success(let data) = result, (try? self.store.saveAnimation(data, name: entry.name)) != nil {
                self.store.setFingerprint(entry.fingerprint, of: entry.name)
                Self.post(.museAvatarChanged, nil)
            }
            self.download(rest)
        }
    }

    func playAvatar(name: String, completion: @escaping (CommandResult) -> Void) {
        let ready = Array(store.videoFiles().keys).sorted()
        guard let key = MuseAvatarState.animationName(name), store.availableAnimations.contains(key) else {
            completion(CommandResult(success: false, value: ["error": "unknown_animation", "available": ready]))
            return
        }
        guard let duration = store.duration(of: key) else {
            // Stored, but its video is still being built.
            completion(CommandResult(success: false, value: ["error": "not_ready", "available": ready]))
            return
        }
        Self.post(.museAvatarPlay, MuseAvatarPlayRequest(name: key, duration: duration))
        completion(CommandResult(success: true, value: ["playing": key, "duration_ms": Int(duration * 1000)]))
    }

    func installAvatar(path: String, state: String? = nil, completion: @escaping (CommandResult) -> Void) {
        UserDefaults.standard.removeObject(forKey: Self.syncOffKey)
        if let state {
            guard let name = MuseAvatarState.animationName(state) else {
                completion(CommandResult(success: false, value: ["error": "invalid_state"]))
                return
            }
            read(path: path, completion: completion) { [store, weak self] data in
                do {
                    let info = try store.saveAnimation(data, name: name)
                    Self.post(.museAvatarChanged, nil)
                    self?.buildAvatarVideos()
                    completion(CommandResult(success: true, value: [
                        "installed": true,
                        "state": name,
                        "frames": info.delays.count,
                        "width": info.pixelWidth,
                        "height": info.pixelHeight,
                        "duration_ms": Int(info.duration * 1000),
                        "ready": store.videoFiles()[name] != nil
                    ]))
                } catch MuseAvatarStore.Failure.notAnImage {
                    completion(CommandResult(success: false, value: ["error": "not_an_image"]))
                } catch {
                    completion(CommandResult(success: false, value: ["error": "save_failed"]))
                }
            }
            return
        }
        read(path: path, completion: completion) { [store] data in
            do {
                let png = try store.save(imageData: data)
                Self.post(.museAvatarChanged, png)
                let size = UIImage(data: png)?.size ?? .zero
                completion(CommandResult(success: true, value: [
                    "installed": true,
                    "width": Int(size.width),
                    "height": Int(size.height),
                    "byte_count": png.count
                ]))
            } catch MuseAvatarStore.Failure.notAnImage {
                completion(CommandResult(success: false, value: ["error": "not_an_image"]))
            } catch {
                completion(CommandResult(success: false, value: ["error": "save_failed"]))
            }
        }
    }

    func clearAvatar() {
        // Otherwise the list on the VM would bring it straight back.
        UserDefaults.standard.set(true, forKey: Self.syncOffKey)
        store.clear()
        Self.post(.museAvatarChanged, nil)
    }

    func draw(path: String, completion: @escaping (CommandResult) -> Void) {
        read(path: path, completion: completion) { data in
            guard let image = MuseImageScaler.scaled(data, maxPixelSize: Self.maxDrawnPixelSize) else {
                completion(CommandResult(success: false, value: ["error": "not_an_image"]))
                return
            }
            Self.post(.museDrawnImageChanged, image)
            completion(CommandResult(success: true, value: [
                "drawn": true,
                "width": Int(image.size.width),
                "height": Int(image.size.height)
            ]))
        }
    }

    func clearDrawnImage() {
        Self.post(.museDrawnImageChanged, nil)
    }

    private func read(
        path: String,
        completion: @escaping (CommandResult) -> Void,
        then use: @escaping (Data) -> Void
    ) {
        guard Self.isValidVMPath(path) else {
            completion(CommandResult(success: false, value: ["error": "invalid_path"]))
            return
        }
        guard let readVMFile else {
            completion(CommandResult(success: false, value: ["error": "not_connected"]))
            return
        }
        readVMFile(path, Self.maxFileBytes) { result in
            switch result {
            case .success(let data):
                use(data)
            case .failure(MuseVMFileError.tooLarge):
                completion(CommandResult(success: false, value: ["error": "file_too_large"]))
            case .failure(MuseVMFileError.status(let status)):
                completion(CommandResult(success: false, value: ["error": "file_unavailable", "http_status": status]))
            case .failure:
                completion(CommandResult(success: false, value: ["error": "read_failed"]))
            }
        }
    }

    private static func post(_ name: Notification.Name, _ object: Any?) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: name, object: object)
        }
    }
}

struct MuseAvatarPlayRequest {
    let name: String
    let duration: TimeInterval
}

extension Notification.Name {
    static let museAvatarPlay = Notification.Name("MuseGadgetLegacy.avatarPlay")
    static let museAvatarPreparing = Notification.Name("MuseGadgetLegacy.avatarPreparing")
    static let museAvatarChanged = Notification.Name("MuseGadgetLegacy.avatarChanged")
    static let museDrawnImageChanged = Notification.Name("MuseGadgetLegacy.drawnImageChanged")
}
