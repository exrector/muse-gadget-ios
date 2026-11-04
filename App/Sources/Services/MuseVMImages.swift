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

    private func animationFile(_ state: MuseAvatarState) -> URL {
        directory.appendingPathComponent("\(state.rawValue).animation")
    }

    /// Stores the original bytes, which are decoded on launch. The idle animation's first frame
    /// also becomes the still picture.
    func saveAnimation(_ data: Data, state: MuseAvatarState) throws -> MuseAvatarAnimationInfo {
        guard let info = MuseAvatarAnimationInfo(data: data) else { throw Failure.notAnImage }
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
        return info
    }

    func animationFiles() -> [MuseAvatarState: URL] {
        var files: [MuseAvatarState: URL] = [:]
        for state in MuseAvatarState.allCases where FileManager.default.fileExists(atPath: animationFile(state).path) {
            files[state] = animationFile(state)
        }
        return files
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

    func avatarAnimationFiles() -> [MuseAvatarState: URL] {
        store.animationFiles()
    }

    func installAvatar(path: String, state: String? = nil, completion: @escaping (CommandResult) -> Void) {
        if let state {
            guard let avatarState = MuseAvatarState(commandValue: state) else {
                completion(CommandResult(success: false, value: ["error": "invalid_state"]))
                return
            }
            read(path: path, completion: completion) { [store] data in
                do {
                    let info = try store.saveAnimation(data, state: avatarState)
                    Self.post(.museAvatarChanged, nil)
                    completion(CommandResult(success: true, value: [
                        "installed": true,
                        "state": avatarState.rawValue,
                        "frames": info.delays.count,
                        "width": info.pixelWidth,
                        "height": info.pixelHeight,
                        "duration_ms": Int(info.duration * 1000)
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
