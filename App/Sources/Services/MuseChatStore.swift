import Foundation
import UIKit

/// Keeps the chat on this device: the Muse Gadget SDK has no endpoint for reading past messages.
/// Lives in Application Support rather than Documents, which the app shares through Finder.
final class MuseChatStore {
    private struct StoredItem: Codable {
        let id: UUID
        let author: String
        let text: String
        let museMessageID: String?
        let imageFile: String?
        var createdAt: Date?
        var updatedAt: Date?
        var hasRemoteImage: Bool?
    }

    private struct StoredHistory: Codable {
        var version = 1
        let items: [StoredItem]
    }

    static let maxStoredItems = 200

    private let directory: URL
    private let saveDelay: TimeInterval
    private let queue = DispatchQueue(label: "MuseGadgetLegacy.chatStore")
    private var pendingSave: DispatchWorkItem?
    private var pendingItems: [MuseChatItem]?

    private var historyFile: URL { directory.appendingPathComponent("history.json") }

    init(directory: URL? = nil, saveDelay: TimeInterval = 0.5) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chat-history", isDirectory: true)
        self.saveDelay = saveDelay
    }

    func load() -> [MuseChatItem] {
        queue.sync {
            guard let data = try? Data(contentsOf: historyFile) else { return [] }
            guard let history = try? JSONDecoder().decode(StoredHistory.self, from: data) else {
                // Keep an unreadable file instead of overwriting it on the next save.
                let aside = directory.appendingPathComponent("history.unreadable.json")
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.moveItem(at: historyFile, to: aside)
                return []
            }
            return history.items.enumerated().compactMap { index, stored in
                guard let author = MuseChatItem.Author(storedName: stored.author) else { return nil }
                let image = stored.imageFile
                    .flatMap { try? Data(contentsOf: directory.appendingPathComponent($0)) }
                    .flatMap(UIImage.init(data:))
                // Items saved before dates existed keep their order and sort before anything newer.
                let createdAt = stored.createdAt ?? Date(timeIntervalSince1970: TimeInterval(index))
                return MuseChatItem(
                    id: stored.id,
                    author: author,
                    text: stored.text,
                    image: image,
                    museMessageID: stored.museMessageID,
                    createdAt: createdAt,
                    updatedAt: stored.updatedAt ?? createdAt,
                    hasRemoteImage: stored.hasRemoteImage ?? false
                )
            }
        }
    }

    /// Coalesces the burst of writes that a streamed reply would otherwise cause.
    func scheduleSave(_ items: [MuseChatItem]) {
        queue.async {
            self.pendingItems = items
            self.pendingSave?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.writePending() }
            self.pendingSave = work
            self.queue.asyncAfter(deadline: .now() + self.saveDelay, execute: work)
        }
    }

    /// Blocks until the latest history is on disk; call before the app can be suspended.
    func flush() {
        queue.sync {
            pendingSave?.cancel()
            pendingSave = nil
            writePending()
        }
    }

    func clear() {
        queue.sync {
            pendingSave?.cancel()
            pendingSave = nil
            pendingItems = nil
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func writePending() {
        guard let items = pendingItems else { return }
        pendingItems = nil
        do {
            try prepareDirectory()
            // Failure notices describe a moment that has passed, so only the conversation is kept.
            let kept = items.filter { $0.author != .system }.suffix(Self.maxStoredItems)
            let stored = try kept.map { item -> StoredItem in
                StoredItem(
                    id: item.id,
                    author: item.author.storedName,
                    text: item.text,
                    museMessageID: item.museMessageID,
                    imageFile: try writeImageIfNeeded(item),
                    createdAt: item.createdAt,
                    updatedAt: item.updatedAt,
                    hasRemoteImage: item.hasRemoteImage
                )
            }
            let data = try JSONEncoder().encode(StoredHistory(items: stored))
            try data.write(to: historyFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            removeUnreferencedImages(keeping: Set(stored.compactMap(\.imageFile)))
        } catch {
            // Keep the snapshot so the next save or flush retries it.
            if pendingItems == nil { pendingItems = items }
        }
    }

    private func prepareDirectory() throws {
        var url = directory
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private func writeImageIfNeeded(_ item: MuseChatItem) throws -> String? {
        guard let image = item.image else { return nil }
        let name = "\(item.id.uuidString.lowercased()).jpg"
        let file = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: file.path) { return name }
        guard let data = image.jpegData(compressionQuality: 0.8) else { return nil }
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return name
    }

    private func removeUnreferencedImages(keeping names: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in files where name.hasSuffix(".jpg") && !names.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}

extension MuseChatItem.Author {
    init?(storedName: String) {
        switch storedName {
        case "user": self = .user
        case "muse": self = .muse
        default: return nil
        }
    }

    var storedName: String {
        switch self {
        case .user: return "user"
        case .muse: return "muse"
        case .system: return "system"
        }
    }
}
