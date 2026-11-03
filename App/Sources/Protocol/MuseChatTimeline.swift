import Foundation

enum MuseChatUpdate: Equatable {
    case reply(messageID: String, text: String, done: Bool)
    case activity(String?)
    case finished
}

/// Follows Muse's shared main chat for the requests this gadget sent.
///
/// Native port of the message rules in the SDK's `linux/src/musegadget/muse_turn.py`: events wait
/// for the request's acknowledgement, replies are keyed by message ID so a final
/// `message.assistant` replaces its deltas, and messages answering other clients are dropped.
final class MuseChatTimeline {
    private struct Reply {
        var text = ""
        var done = false
    }

    private static let maxTextBytes = 64 * 1024
    private static let maxPendingEvents = 64
    private static let maxTrackedMessages = 256
    private static let terminalStatuses: Set<String> = ["completed", "failed", "errored", "cancelled", "canceled"]

    private var userIDs: Set<String> = []
    private var sessionID: String?
    private var replies: [String: Reply] = [:]
    private var replyOrder: [String] = []
    private var ignored: Set<String> = []
    private var ignoredOrder: [String] = []
    private var pending: [[String: Any]] = []
    private var holding = false

    /// Holds events until `acknowledge` binds the next user message.
    func expectRequest() {
        holding = true
    }

    func abandonRequest() {
        holding = false
        pending.removeAll()
    }

    func acknowledge(_ response: [String: Any]) -> [MuseChatUpdate] {
        let result = response["result"] as? [String: Any] ?? response
        for key in ["message_id", "reply_to_message_id"] {
            if let value = result[key] as? String, !value.isEmpty { userIDs.insert(value) }
        }
        if let session = result["session_id"] as? String, !session.isEmpty { sessionID = session }
        holding = false
        let held = pending
        pending.removeAll()
        return held.flatMap(feed)
    }

    func feed(_ event: [String: Any]) -> [MuseChatUpdate] {
        guard event["type"] as? String == "event",
              let payload = event["payload"] as? [String: Any] else { return [] }
        let eventSession = (payload["session_id"] as? String) ?? (event["session_id"] as? String)
        if let eventSession, !eventSession.isEmpty, let sessionID, eventSession != sessionID { return [] }
        if holding {
            if pending.count < Self.maxPendingEvents { pending.append(event) }
            return []
        }
        // Nothing to bind to yet: earlier main-chat traffic belongs to other clients.
        guard !userIDs.isEmpty, let name = event["event"] as? String else { return [] }
        switch name {
        case "agent.status", "task.status":
            return status(name: name, payload: payload)
        case "delta.message_start", "delta.text_append", "delta.message_done", "message.assistant":
            return message(name: name, event: event, payload: payload)
        default:
            return []
        }
    }

    private func status(name: String, payload: [String: Any]) -> [MuseChatUpdate] {
        let parent = Self.parent(of: payload)
        let linked = parent.map { userIDs.contains($0) || replies[$0] != nil } ?? false
        if parent != nil, !linked { return [] }
        if name == "task.status", let status = payload["status"] as? String,
           Self.terminalStatuses.contains(status) {
            return [.finished]
        }
        if name == "agent.status", linked {
            let code = payload["activity_code"] as? String
            let isIdle = code == nil || code == "" || code == "online" || code == "idle"
            return [.activity(isIdle ? nil : Self.stripControls(payload["activity_text"] as? String ?? ""))]
        }
        return []
    }

    private func message(name: String, event: [String: Any], payload: [String: Any]) -> [MuseChatUpdate] {
        guard let messageID = Self.nonEmpty(payload["message_id"])
                ?? Self.nonEmpty(event["message_id"])
                ?? Self.nonEmpty(payload["id"]),
              payload["role"] as? String != "user" else { return [] }
        let parent = Self.parent(of: payload)
        var reply = replies[messageID]
        if let parent, !userIDs.contains(parent), replies[parent] == nil {
            if reply == nil { ignore(messageID) }
            return []
        }
        if reply == nil {
            if ignored.contains(messageID) { return [] }
            track(messageID)
            reply = Reply()
        }
        guard var current = reply else { return [] }

        if name == "delta.text_append", !current.done, let delta = payload["text"] as? String {
            current.text += Self.stripControls(delta)
        }
        if name == "delta.message_done" || name == "message.assistant" {
            if let completed = Self.completedText(payload: payload, messageID: messageID) {
                current.text = Self.stripControls(completed)
            }
            if name == "delta.message_done" || payload["display_text_ready"] as? Bool != false {
                current.done = true
            }
        }
        if current.text.utf8.count > Self.maxTextBytes {
            current.text = String(decoding: current.text.utf8.prefix(Self.maxTextBytes), as: UTF8.self)
        }
        replies[messageID] = current
        return [.reply(messageID: messageID, text: current.text, done: current.done)]
    }

    private func track(_ messageID: String) {
        replyOrder.append(messageID)
        if replyOrder.count > Self.maxTrackedMessages {
            replies.removeValue(forKey: replyOrder.removeFirst())
        }
    }

    private func ignore(_ messageID: String) {
        guard ignored.insert(messageID).inserted else { return }
        ignoredOrder.append(messageID)
        if ignoredOrder.count > Self.maxTrackedMessages {
            ignored.remove(ignoredOrder.removeFirst())
        }
    }

    private static func parent(of payload: [String: Any]) -> String? {
        nonEmpty(payload["reply_to_message_id"]) ?? nonEmpty(payload["parent_message_id"])
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func completedText(payload: [String: Any], messageID: String) -> String? {
        if let text = payload["display_text"] as? String { return text }
        if let text = payload["transcript"] as? String { return text }
        let structured = transcriptText(payload["transcript"], messageID: messageID)
        if !structured.isEmpty { return structured }
        return payload["content"] as? String
    }

    /// Reads only assistant text from Muse's structured transcript.
    private static func transcriptText(_ value: Any?, messageID: String) -> String {
        guard let transcript = value as? [String: Any],
              let messages = transcript["messages"] as? [[String: Any]],
              let last = messages.last(where: {
                  $0["role"] as? String == "assistant" && $0["id"] as? String == messageID
              }),
              let content = last["content"] as? [[String: Any]] else { return "" }
        return content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
    }

    /// Removes C0 and C1 controls except tab and newline.
    private static func stripControls(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            if scalar == "\t" || scalar == "\n" { return true }
            return !(scalar.value < 0x20 || (0x7f...0x9f).contains(scalar.value))
        }))
    }
}
