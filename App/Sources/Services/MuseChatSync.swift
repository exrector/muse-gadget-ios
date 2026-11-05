import Foundation

struct MuseServerChatMessage: Equatable {
    let author: MuseChatItem.Author
    let text: String
    let messageID: String
    let createdAt: Date
}

/// Reads the deliberately small, loosely-versioned `/chat/history` response without depending on
/// one wrapper shape. Only user and assistant text is imported; tool calls and hidden reasoning are
/// ignored.
enum MuseServerHistory {
    static func parse(_ data: Data, now: Date = Date()) -> [MuseServerChatMessage] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var raw: [(author: MuseChatItem.Author, text: String, id: String, date: Date?)] = []
        collect(root, into: &raw)
        var seen = Set<String>()
        let unique = raw.filter { seen.insert($0.id).inserted }
        return unique.enumerated().map { index, message in
            MuseServerChatMessage(
                author: message.author,
                text: message.text,
                messageID: message.id,
                createdAt: message.date ?? now.addingTimeInterval(TimeInterval(index - unique.count))
            )
        }.sorted { $0.createdAt == $1.createdAt ? $0.messageID < $1.messageID : $0.createdAt < $1.createdAt }
    }

    private static func collect(
        _ value: Any,
        into result: inout [(author: MuseChatItem.Author, text: String, id: String, date: Date?)]
    ) {
        if let object = value as? [String: Any] {
            if let role = object["role"] as? String,
               let author = author(role),
               let id = string(object["id"]) ?? string(object["message_id"]),
               let text = text(from: object), !text.isEmpty {
                result.append((author, text, id, date(from: object)))
                return
            }
            for key in ["messages", "history", "items", "results", "data", "result"] {
                if let child = object[key] { collect(child, into: &result) }
            }
        } else if let array = value as? [Any] {
            for child in array { collect(child, into: &result) }
        }
    }

    private static func author(_ role: String) -> MuseChatItem.Author? {
        switch role.lowercased() {
        case "user": return .user
        case "assistant", "muse": return .muse
        default: return nil
        }
    }

    private static func text(from object: [String: Any]) -> String? {
        for key in ["display_text", "text"] {
            if let value = string(object[key]), !value.isEmpty { return value }
        }
        if let value = object["content"] as? String, !value.isEmpty { return value }
        guard let content = object["content"] as? [Any] else { return nil }
        let parts = content.compactMap { item -> String? in
            guard let item = item as? [String: Any],
                  item["type"] as? String == "text" else { return nil }
            return string(item["text"])
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private static func date(from object: [String: Any]) -> Date? {
        for key in ["created_at", "createdAt", "timestamp", "time"] {
            if let number = object[key] as? NSNumber {
                let raw = number.doubleValue
                return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
            }
            if let string = object[key] as? String {
                if let raw = Double(string) {
                    return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
                }
                if let parsed = ISO8601DateFormatter().date(from: string) { return parsed }
            }
        }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}

struct MuseSyncedMessage: Codable, Equatable {
    let id: UUID
    let author: String
    let text: String
    let museMessageID: String?
    let createdAt: Date
    let updatedAt: Date
    let hasImage: Bool
}

struct MuseSyncedHistory: Codable, Equatable {
    var version = 1
    var clearedBefore: Date?
    var messages: [MuseSyncedMessage]
}

/// Combines the histories of several devices. Holds no state, so it can be tested without iCloud.
enum MuseChatMerge {
    static func mergeServer(
        local: [MuseChatItem],
        server: [MuseServerChatMessage],
        clearedBefore: Date?
    ) -> [MuseChatItem] {
        var items = local
        for message in server where clearedBefore.map({ message.createdAt > $0 }) ?? true {
            if let index = items.firstIndex(where: { $0.museMessageID == message.messageID }) {
                if items[index].text != message.text { items[index].text = message.text }
                continue
            }
            if let index = items.firstIndex(where: {
                $0.museMessageID == nil && $0.author == message.author && $0.text == message.text
                    && abs($0.createdAt.timeIntervalSince(message.createdAt)) < 120
            }) {
                items[index].museMessageID = message.messageID
                continue
            }
            items.append(MuseChatItem(
                author: message.author,
                text: message.text,
                museMessageID: message.messageID,
                createdAt: message.createdAt
            ))
        }
        return Array(ordered(uniqueReplies(items)).suffix(MuseChatStore.maxStoredItems))
    }

    static func merge(
        local: [MuseChatItem],
        remote: MuseSyncedHistory,
        clearedBefore localCleared: Date?
    ) -> (items: [MuseChatItem], clearedBefore: Date?) {
        let cleared = [localCleared, remote.clearedBefore].compactMap { $0 }.max()
        var items = local
        var indexByID = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
        for message in remote.messages {
            if let index = indexByID[message.id] {
                if message.updatedAt > items[index].updatedAt {
                    items[index].text = message.text
                    items[index].updatedAt = message.updatedAt
                }
            } else if let author = MuseChatItem.Author(storedName: message.author) {
                indexByID[message.id] = items.count
                items.append(MuseChatItem(
                    id: message.id,
                    author: author,
                    text: message.text,
                    museMessageID: message.museMessageID,
                    createdAt: message.createdAt,
                    updatedAt: message.updatedAt,
                    hasRemoteImage: message.hasImage
                ))
            }
        }
        if let cleared { items.removeAll { $0.createdAt <= cleared } }
        return (Array(ordered(uniqueReplies(items)).suffix(MuseChatStore.maxStoredItems)), cleared)
    }

    /// Newest messages that fit: iCloud key-value storage holds about 1 MB per app.
    static func encoded(items: [MuseChatItem], clearedBefore: Date?, maxBytes: Int) -> Data? {
        var messages = items
            .filter { $0.author != .system }
            .suffix(MuseChatStore.maxStoredItems)
            .map { item in
                MuseSyncedMessage(
                    id: item.id,
                    author: item.author.storedName,
                    text: item.text,
                    museMessageID: item.museMessageID,
                    createdAt: item.createdAt,
                    updatedAt: item.updatedAt,
                    hasImage: item.image != nil || item.hasRemoteImage
                )
            }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        while true {
            let history = MuseSyncedHistory(clearedBefore: clearedBefore, messages: messages)
            guard let json = try? encoder.encode(history),
                  let compressed = try? (json as NSData).compressed(using: .zlib) as Data else { return nil }
            if compressed.count <= maxBytes { return compressed }
            guard !messages.isEmpty else { return nil }
            messages.removeFirst(max(1, messages.count / 8))
        }
    }

    static func decoded(_ data: Data) -> MuseSyncedHistory? {
        guard let json = try? (data as NSData).decompressed(using: .zlib) as Data else { return nil }
        return try? JSONDecoder().decode(MuseSyncedHistory.self, from: json)
    }

    /// Two devices on the main chat can both record the same Muse reply under their own IDs.
    private static func uniqueReplies(_ items: [MuseChatItem]) -> [MuseChatItem] {
        var firstIndex: [String: Int] = [:]
        var result: [MuseChatItem] = []
        for item in ordered(items) {
            guard let messageID = item.museMessageID else {
                result.append(item)
                continue
            }
            if let index = firstIndex[messageID] {
                if item.updatedAt > result[index].updatedAt {
                    result[index].text = item.text
                    result[index].updatedAt = item.updatedAt
                }
            } else {
                firstIndex[messageID] = result.count
                result.append(item)
            }
        }
        return result
    }

    private static func ordered(_ items: [MuseChatItem]) -> [MuseChatItem] {
        items.sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
        }
    }
}

protocol MuseCloudKeyValues: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ value: Data?, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: MuseCloudKeyValues {}

/// Shares the chat text between devices on one Apple ID. Photos stay on the device that took them.
/// iCloud delivers changes when it chooses, usually within minutes. Main thread only.
final class MuseChatCloudSync {
    static let maxBytes = 900_000
    private static let historyKey = "chat-history-v1"
    private static let enabledKey = "MuseGadgetLegacy.iCloudChatSync"
    private static let clearedKey = "MuseGadgetLegacy.chatClearedBefore"

    var onRemoteChange: (() -> Void)?

    private let cloud: MuseCloudKeyValues
    private let defaults: UserDefaults
    private let publishDelay: TimeInterval
    private var pendingItems: [MuseChatItem]?
    private var pendingPublish: DispatchWorkItem?

    init(
        cloud: MuseCloudKeyValues = NSUbiquitousKeyValueStore.default,
        defaults: UserDefaults = .standard,
        publishDelay: TimeInterval = 5
    ) {
        self.cloud = cloud
        self.defaults = defaults
        self.publishDelay = publishDelay
    }

    var isEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    var isAccountAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    var clearedBefore: Date? {
        get { defaults.object(forKey: Self.clearedKey) as? Date }
        set { defaults.set(newValue, forKey: Self.clearedKey) }
    }

    func start() {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] _ in
            self?.onRemoteChange?()
        }
        synchronize()
    }

    func synchronize() {
        guard isEnabled else { return }
        cloud.synchronize()
    }

    func remoteHistory() -> MuseSyncedHistory? {
        guard isEnabled else { return nil }
        return cloud.data(forKey: Self.historyKey).flatMap(MuseChatMerge.decoded)
    }

    /// Coalesces writes: iCloud throttles apps that store too often.
    func publish(_ items: [MuseChatItem]) {
        guard isEnabled else { return }
        pendingItems = items
        pendingPublish?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pendingPublish = work
        DispatchQueue.main.asyncAfter(deadline: .now() + publishDelay, execute: work)
    }

    func flush() {
        pendingPublish?.cancel()
        pendingPublish = nil
        guard isEnabled, let items = pendingItems else { return }
        pendingItems = nil
        guard let data = MuseChatMerge.encoded(
            items: items,
            clearedBefore: clearedBefore,
            maxBytes: Self.maxBytes
        ), data != cloud.data(forKey: Self.historyKey) else { return }
        cloud.set(data, forKey: Self.historyKey)
        cloud.synchronize()
    }
}
