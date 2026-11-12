import Foundation

enum MuseChatUpdate: Equatable {
    case reply(messageID: String, text: String, done: Bool)
    /// A reply to a request the gadget stopped waiting for. It never ends the current turn.
    case lateReply(messageID: String, text: String, done: Bool)
    /// Muse sent media or a form, which a gadget cannot fetch; `text` is what can be shown instead.
    case presentation(id: String, text: String, late: Bool)
    /// A finished message of Muse's in this chat that answers no request of this gadget.
    case otherMessage
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
        var late = false
    }

    /// The one request the gadget let go of while Muse was still on it, as the SDK's ESP32 firmware
    /// remembers it (b4bee64): its reply is kept when it comes, and it is forgotten once that reply
    /// is done or 30 minutes after it was let go.
    private struct LateRequest {
        var ids: Set<String>
        let since: Date
        var busy = true
        var lastStatus: Date
        var notedIdle = false
    }

    static let lateIdleExpiry: TimeInterval = 10
    static let lateMaxAge: TimeInterval = 30 * 60

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
    private var late: LateRequest?
    private var presented: Set<String> = []
    /// Messages of the current turn, which a late reply may answer instead of the request itself.
    private var turnMessages: Set<String> = []
    private var lateEventNotes = 0
    /// The chat the current or late request belongs to.
    var currentSessionID: String? { sessionID }
    /// Content-free notes for the diagnostics log: why a late request was forgotten or a row skipped.
    var onNote: ((String) -> Void)?
    /// True while Muse's latest status for the current request says it is working on it.
    private(set) var isMuseWorking = false
    var now: () -> Date = Date.init

    /// True when a request was acknowledged and its reply has not finished.
    var hasBoundRequest: Bool { !userIDs.isEmpty }

    /// Holds events until `acknowledge` binds the next user message.
    func expectRequest() {
        holding = true
        isMuseWorking = false
    }

    func abandonRequest() {
        holding = false
        pending.removeAll()
    }

    /// Stops presenting the current turn locally. Muse has no documented semantic cancel route for
    /// ordinary chat, so the request is let go of and its reply, if it comes, arrives as late.
    func stopCurrentReply() {
        detachCurrentRequest()
    }

    /// Lets go of the current request without losing its reply. Returns false when there was none.
    @discardableResult
    func detachCurrentRequest() -> Bool {
        holding = false
        pending.removeAll()
        isMuseWorking = false
        guard !userIDs.isEmpty else { return false }
        // As the ESP32's pending_arm: the request and every message its turn already showed.
        let ids = userIDs.union(turnMessages)
        late = LateRequest(ids: ids, since: now(), lastStatus: now())
        lateEventNotes = 0
        for id in turnMessages { replies[id]?.late = true }
        userIDs.removeAll()
        turnMessages.removeAll()
        return true
    }

    /// The reply came another way, such as from the chat's history.
    func forgetLateRequest(reason: String) {
        guard late != nil else { return }
        late = nil
        onNote?("late_forgotten:" + reason)
    }

    var isWaitingForLateReply: Bool {
        expireLateRequest()
        return late != nil
    }

    private func expireLateRequest() {
        guard let request = late else { return }
        let time = now()
        if time.timeIntervalSince(request.since) > Self.lateMaxAge {
            late = nil; onNote?("late_forgotten:age"); return
        }
        // The ESP32 also forgets 10 s after Muse stops saying it is working. Measured on the iPad
        // (2026-11-12), Muse said it was idle and answered a long task two minutes later, so the
        // gadget keeps waiting: only an answer naming this request can match it.
        if !request.busy, time.timeIntervalSince(request.lastStatus) > Self.lateIdleExpiry,
           !request.notedIdle {
            late?.notedIdle = true
            onNote?("late_idle")
        }
    }

    func acknowledge(_ response: [String: Any]) -> [MuseChatUpdate] {
        let result = response["result"] as? [String: Any] ?? response
        userIDs.removeAll()
        turnMessages.removeAll()
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
        // While a late request is remembered, every event is noted without content, to see what Muse
        // sends for a long task: its kind, whom it answers and which chat it is in.
        if late != nil, lateEventNotes < 60, let name = event["event"] as? String, name != "delta.text_append" {
            lateEventNotes += 1
            let parent = Self.parent(of: payload) ?? Self.parent(of: payload["data"] as? [String: Any] ?? [:])
            let whom = parent == nil ? "none" : (isLate(parent) ? "late" : (userIDs.contains(parent!) ? "cur" : "other"))
            let chat = eventSession == nil ? "none" : (eventSession == sessionID ? "same" : "other")
            onNote?("ev:\(name.prefix(40)):p=\(whom):s=\(chat)")
        }
        if let eventSession, !eventSession.isEmpty, let sessionID, eventSession != sessionID { return [] }
        if holding {
            if pending.count < Self.maxPendingEvents { pending.append(event) }
            return []
        }
        expireLateRequest()
        guard let name = event["event"] as? String else { return [] }
        let finishedMessage = (name == "message.assistant" && payload["display_text_ready"] as? Bool != false)
            && payload["role"] as? String != "user"
        // Nothing to bind to: the message came from elsewhere, so the app reads the chat's history.
        guard !userIDs.isEmpty || late != nil else { return finishedMessage ? [.otherMessage] : [] }
        switch name {
        case "agent.status", "task.status":
            return status(name: name, payload: payload)
        case "delta.message_start", "delta.text_append", "delta.message_done", "message.assistant":
            return message(name: name, event: event, payload: payload)
        case "delta.presentation":
            return presentation(event: event, payload: payload)
        default:
            return []
        }
    }

    private func isLate(_ id: String?) -> Bool {
        guard let id, let late else { return false }
        return late.ids.contains(id) || replies[id]?.late == true
    }

    /// `delta.presentation` is not documented. As seen by other gadgets (muse-gadget-sdk#186) it
    /// describes audio, video or images by a path the gadget may not read, or carries a form as
    /// HTML, with `fallback_text`. Only that text and the kind of media are shown.
    private func presentation(event: [String: Any], payload: [String: Any]) -> [MuseChatUpdate] {
        let data = payload["data"] as? [String: Any] ?? [:]
        let parent = Self.parent(of: payload) ?? Self.parent(of: data)
        let messageID = Self.nonEmpty(payload["message_id"]) ?? Self.nonEmpty(event["message_id"])
        let late = isLate(parent) || isLate(messageID)
        let current = parent.map { userIDs.contains($0) || (replies[$0].map { !$0.late } ?? false) }
            ?? (messageID.map { replies[$0].map { !$0.late } ?? false } ?? !userIDs.isEmpty)
        guard late || current else { return [] }
        let kinds = [("audio", "audio"), ("videos", "video"), ("video", "video"), ("images", "image"),
                     ("image", "image"), ("html", "form")]
            .filter { data[$0.0] != nil || payload[$0.0] != nil }.map(\.1)
        let kind = kinds.first ?? "attachment"
        let fallback = Self.stripControls(
            (data["fallback_text"] as? String) ?? (payload["fallback_text"] as? String) ?? ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let key = (Self.nonEmpty(payload["id"]) ?? messageID ?? parent ?? "") + "#" + kind
        guard presented.insert(key).inserted else { return [] }
        if presented.count > Self.maxTrackedMessages { presented.removeAll() }
        let text = String(decoding: fallback.utf8.prefix(4096), as: UTF8.self)
        return [.presentation(id: key, text: Self.mediaMarker(kind) + (text.isEmpty ? "" : "\n" + text), late: late)]
    }

    /// The first line of a presentation's chat bubble; the app localizes it.
    static func mediaMarker(_ kind: String) -> String {
        switch kind {
        case "audio": return "presentation.audio"
        case "video": return "presentation.video"
        case "image": return "presentation.image"
        case "form": return "presentation.form"
        default: return "presentation.attachment"
        }
    }

    private func status(name: String, payload: [String: Any]) -> [MuseChatUpdate] {
        let parent = Self.parent(of: payload)
        // As the ESP32's pending_event: with no turn of its own, a status that names the late
        // request or names no request at all says whether Muse is still working on it.
        if late != nil, isLate(parent) || (parent == nil && userIDs.isEmpty) {
            late?.busy = Self.isBusy(name: name, payload: payload)
            late?.lastStatus = now()
            return []
        }
        guard !userIDs.isEmpty else { return [] }
        let linked = parent.map { userIDs.contains($0) || replies[$0] != nil } ?? false
        if parent != nil, !linked { return [] }
        if name == "task.status", let status = payload["status"] as? String,
           Self.terminalStatuses.contains(status) {
            isMuseWorking = false
            return [.finished]
        }
        if linked || parent == nil { isMuseWorking = Self.isBusy(name: name, payload: payload) }
        if name == "agent.status", linked {
            let code = payload["activity_code"] as? String
            let isIdle = code == nil || code == "" || code == "online" || code == "idle"
            return [.activity(isIdle ? nil : Self.stripControls(payload["activity_text"] as? String ?? ""))]
        }
        return []
    }

    private static func isBusy(name: String, payload: [String: Any]) -> Bool {
        if name == "task.status" {
            guard let status = payload["status"] as? String else { return false }
            return !terminalStatuses.contains(status)
        }
        let code = payload["activity_code"] as? String
        return !(code == nil || code == "" || code == "online" || code == "idle")
    }

    private func message(name: String, event: [String: Any], payload: [String: Any]) -> [MuseChatUpdate] {
        guard let messageID = Self.nonEmpty(payload["message_id"])
                ?? Self.nonEmpty(event["message_id"])
                ?? Self.nonEmpty(payload["id"]),
              payload["role"] as? String != "user" else { return [] }
        let parent = Self.parent(of: payload)
        if replies[messageID]?.late == true || (replies[messageID] == nil && isLate(parent)) {
            return lateMessage(name: name, messageID: messageID, payload: payload)
        }
        guard !userIDs.isEmpty else {
            if late != nil, name == "message.assistant" {
                onNote?(parent == nil ? "late_skip:no_parent" : "late_skip:other_parent")
                return [.otherMessage]
            }
            return []
        }
        var reply = replies[messageID]
        if let parent, !userIDs.contains(parent), replies[parent] == nil {
            if reply == nil { ignore(messageID) }
            return name == "message.assistant" ? [.otherMessage] : []
        }
        if reply == nil {
            if ignored.contains(messageID) { return name == "message.assistant" ? [.otherMessage] : [] }
            track(messageID)
            reply = Reply()
        }
        turnMessages.insert(messageID)
        guard var current = reply else { return [] }

        current = Self.updated(current, name: name, messageID: messageID, payload: payload)
        replies[messageID] = current
        return [.reply(messageID: messageID, text: current.text, done: current.done)]
    }

    private static func updated(_ reply: Reply, name: String, messageID: String, payload: [String: Any]) -> Reply {
        var current = reply
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
        return current
    }

    private func lateMessage(name: String, messageID: String, payload: [String: Any]) -> [MuseChatUpdate] {
        var current = replies[messageID] ?? Reply(late: true)
        if replies[messageID] == nil { track(messageID) }
        current.late = true
        current = Self.updated(current, name: name, messageID: messageID, payload: payload)
        replies[messageID] = current
        late?.ids.insert(messageID)
        if current.done { late = nil; onNote?("late_reply_done") }
        guard !current.text.isEmpty else { return [] }
        return [.lateReply(messageID: messageID, text: current.text, done: current.done)]
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
