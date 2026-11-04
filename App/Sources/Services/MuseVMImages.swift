import Foundation
import ImageIO
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

/// What the avatar shows. Muse may keep its animations under other names, so a few are accepted.
enum MuseAvatarState: String, CaseIterable {
    case idle, listening, thinking, speaking

    init?(commandValue: String) {
        switch commandValue.lowercased() {
        case "idle": self = .idle
        case "listening": self = .listening
        case "thinking", "working": self = .thinking
        case "speaking", "talking": self = .speaking
        default: return nil
        }
    }
}

/// One state's frames, decoded small: the avatar is a small view and an old phone has little memory.
struct MuseAvatarAnimation: Equatable {
    static let maxPixelSize = 96
    static let maxFrames = 48

    let id = UUID()
    let frames: [UIImage]
    let duration: TimeInterval

    static func == (left: MuseAvatarAnimation, right: MuseAvatarAnimation) -> Bool { left.id == right.id }

    /// Reads GIF, APNG and animated WebP. Nil when the data holds no image at all.
    static func decode(_ data: Data) -> MuseAvatarAnimation? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        let step = max(1, Int((Double(count) / Double(maxFrames)).rounded(.up)))
        var frames: [UIImage] = []
        for index in stride(from: 0, to: count, by: step) {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ] as CFDictionary) else { continue }
            frames.append(UIImage(cgImage: image))
        }
        guard !frames.isEmpty else { return nil }
        let duration = (0..<count).reduce(0.0) { $0 + frameDelay(source, at: $1) }
        return MuseAvatarAnimation(frames: frames, duration: duration)
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

    static let maxPixelSize = 512

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

    private func animationFile(_ state: MuseAvatarState) -> URL {
        directory.appendingPathComponent("\(state.rawValue).animation")
    }

    /// Stores the original bytes, which are decoded on launch. The idle animation's first frame
    /// also becomes the still picture.
    func saveAnimation(_ data: Data, state: MuseAvatarState) throws -> MuseAvatarAnimation {
        guard let animation = MuseAvatarAnimation.decode(data) else { throw Failure.notAnImage }
        if state == .idle { _ = try save(imageData: data) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var target = animationFile(state)
            try data.write(to: target, options: .atomic)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try target.setResourceValues(values)
        } catch {
            throw Failure.saveFailed
        }
        return animation
    }

    func loadAnimations() -> [MuseAvatarState: MuseAvatarAnimation] {
        var animations: [MuseAvatarState: MuseAvatarAnimation] = [:]
        for state in MuseAvatarState.allCases {
            if let data = try? Data(contentsOf: animationFile(state)),
               let animation = MuseAvatarAnimation.decode(data) {
                animations[state] = animation
            }
        }
        return animations
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Backs the commands that show a VM file. The file comes only from the paired VM, never from a
/// URL, so these commands cannot make the device reach anywhere new.
final class MuseVMImageService {
    typealias FileReader = (String, Int, @escaping (Result<Data, Error>) -> Void) -> Void

    static let maxFileBytes = 4 * 1024 * 1024
    static let maxDrawnPixelSize = 1600

    /// Set once the runtime exists; the command registry has to be built before it.
    var readVMFile: FileReader?

    private let store: MuseAvatarStore

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

    func avatarAnimations() -> [MuseAvatarState: MuseAvatarAnimation] {
        store.loadAnimations()
    }

    func installAvatar(path: String, state: String? = nil, completion: @escaping (CommandResult) -> Void) {
        if let state {
            guard let avatarState = MuseAvatarState(commandValue: state) else {
                completion(CommandResult(success: false, value: ["error": "invalid_state"]))
                return
            }
            read(path: path, completion: completion) { [store] data in
                do {
                    let animation = try store.saveAnimation(data, state: avatarState)
                    Self.post(.museAvatarChanged, nil)
                    completion(CommandResult(success: true, value: [
                        "installed": true,
                        "state": avatarState.rawValue,
                        "frames": animation.frames.count
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

extension Notification.Name {
    static let museAvatarChanged = Notification.Name("MuseGadgetLegacy.avatarChanged")
    static let museDrawnImageChanged = Notification.Name("MuseGadgetLegacy.drawnImageChanged")
}
