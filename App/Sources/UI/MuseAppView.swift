import SwiftUI
import UIKit
import QuickLook
import UniformTypeIdentifiers

struct MuseChatItem: Identifiable {
    enum Author: Equatable { case user, muse, system }

    let id: UUID
    let author: Author
    var text: String {
        didSet { updatedAt = Date() }
    }
    var image: UIImage?
    var museMessageID: String?
    /// Nil is the main Muse chat. A value selects a side chat on the same account.
    var sessionID: String?
    let createdAt: Date
    var updatedAt: Date
    /// The photo was sent from another device; only its text syncs through iCloud.
    var hasRemoteImage: Bool

    init(
        id: UUID = UUID(),
        author: Author,
        text: String,
        image: UIImage? = nil,
        museMessageID: String? = nil,
        sessionID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        hasRemoteImage: Bool = false
    ) {
        self.id = id
        self.author = author
        self.text = text
        self.image = image
        self.museMessageID = museMessageID
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.hasRemoteImage = hasRemoteImage
    }
}

struct MuseChatSession: Codable, Equatable, Identifiable {
    let id: String
    var title: String
    var hasCustomTitle: Bool

    init(id: String, title: String, hasCustomTitle: Bool = false) {
        self.id = id
        self.title = title
        self.hasCustomTitle = hasCustomTitle
    }

    private enum CodingKeys: String, CodingKey { case id, title, hasCustomTitle }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        hasCustomTitle = try values.decodeIfPresent(Bool.self, forKey: .hasCustomTitle) ?? false
    }
}

enum MuseChatSessionReference {
    static func id(from raw: String) -> String? {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let uuidPattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        if let components = URLComponents(string: clean), components.scheme != nil {
            let preferredKeys = ["session_id", "sessionId", "chat_id", "chatId", "thread_id", "conversation_id"]
            for key in preferredKeys {
                if let value = components.queryItems?.first(where: { $0.name == key })?.value,
                   let match = uuid(in: value, pattern: uuidPattern, last: true) {
                    return match
                }
            }
            if let match = uuid(in: components.path, pattern: uuidPattern, last: true) { return match }
        }
        if let match = uuid(in: clean, pattern: uuidPattern, last: true) { return match }
        guard clean.count <= 64,
              clean.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil else { return nil }
        return clean
    }

    private static func uuid(in value: String, pattern: String, last: Bool) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = expression.matches(in: value, range: NSRange(value.startIndex..., in: value))
        guard let match = last ? matches.last : matches.first,
              let range = Range(match.range, in: value) else { return nil }
        return String(value[range]).lowercased()
    }
}

/// Muse writes Markdown. Inline styles are rendered and list markers become bullets; other block
/// syntax stays as text, since a chat bubble has no use for headings or tables.
enum MuseChatMarkdown {
    private static let cache = NSCache<NSString, NSAttributedString>()

    static func attributed(_ source: String) -> AttributedString {
        if let cached = cache.object(forKey: source as NSString) { return AttributedString(cached) }
        let bulleted = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let trimmed = line.drop { $0 == " " }
                guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else { return String(line) }
                return String(line.prefix(line.count - trimmed.count)) + "• " + trimmed.dropFirst(2)
            }
            .joined(separator: "\n")
        let parsed = (try? AttributedString(
            markdown: bulleted,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(bulleted)
        cache.setObject(NSAttributedString(parsed), forKey: source as NSString)
        return parsed
    }
}

struct MuseWidgetMarkup: Equatable {
    let text: String
    let widgetIDs: [String]

    static func parse(_ source: String) -> MuseWidgetMarkup {
        let pattern = #"\[\[hatch_widget:([^\]]+)\]\]"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return MuseWidgetMarkup(text: source, widgetIDs: [])
        }
        let range = NSRange(source.startIndex..., in: source)
        let matches = expression.matches(in: source, range: range)
        guard !matches.isEmpty else { return MuseWidgetMarkup(text: source, widgetIDs: []) }

        var ids: [String] = []
        var seen = Set<String>()
        for match in matches {
            guard let idRange = Range(match.range(at: 1), in: source) else { continue }
            let id = String(source[idRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty, seen.insert(id).inserted { ids.append(id) }
        }
        let stripped = expression.stringByReplacingMatches(in: source, range: range, withTemplate: "")
        let compact = stripped
            .replacingOccurrences(of: #"\n[ \t]*\n[ \t]*\n+"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return MuseWidgetMarkup(text: compact, widgetIDs: ids)
    }
}

enum MuseVoiceRecordMode: String, CaseIterable, Identifiable {
    case tap
    case hold

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tap: return PalL10n.text("Нажатие")
        case .hold: return PalL10n.text("Удержание")
        }
    }
}

final class MuseAppModel: ObservableObject {
    @Published var setupStep: Int
    @Published var tokenDraft = ""
    @Published var tokenSaved: Bool
    @Published var isEditingToken = false
    @Published var pairingState: PairingCoordinator.State
    @Published var runtimeState: MuseRuntimeState
    @Published var isPaired: Bool
    @Published var permissionStates: [AppPermission: PermissionState] = [:]
    @Published var networkName: String
    @Published var caption = ""
    @Published var diagnostics: [String] = []
    @Published var alertMessage: String?
    @Published var chatItems: [MuseChatItem] {
        didSet {
            environment.chatStore.scheduleSave(chatItems)
            environment.chatCloud.publish(chatItems)
            environment.chatPeers.publish(chatItems, clearedBefore: environment.chatCloud.clearedBefore)
        }
    }
    @Published var chatSessions: [MuseChatSession] = []
    @Published var activeChatSessionID: String?
    @Published var isRefreshingChats = false
    @Published var isConnectChatOpen = false
    @Published var connectChatReference = ""
    @Published var connectChatName = ""
    @Published var documentFiles: [URL] = []
    @Published var documentStatus: String?
    @Published var isTransferringDocument = false
    /// False when Muse's server refuses the file route to this gadget, so exchange is hidden.
    @Published var vmFilesAllowed: Bool?
    @Published var isDocumentsOpen = false
    @Published var fullScreenReply: MuseChatItem?
    @Published var nearbyGadgetCount = 0
    @Published var isPeerSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isPeerSyncEnabled, forKey: Self.peerSyncKey)
            startPeerSyncIfAllowed()
        }
    }
    @Published var voiceRecordMode: MuseVoiceRecordMode {
        didSet { UserDefaults.standard.set(voiceRecordMode.rawValue, forKey: Self.voiceRecordModeKey) }
    }
    /// With this on, a finished recording waits for the user to send it or throw it away.
    @Published var confirmsVoiceNotes = UserDefaults.standard.bool(forKey: "confirmsVoiceNotes") {
        didSet { UserDefaults.standard.set(confirmsVoiceNotes, forKey: "confirmsVoiceNotes") }
    }
    /// Version 2.0: voice notes carry the SDK's spoken-turn hint, so Muse answers them briefly.
    /// Off restores the 1.0 behaviour, full replies as for typed messages.
    @Published var shortVoiceReplies = UserDefaults.standard.object(forKey: "shortVoiceReplies") as? Bool ?? true {
        didSet { UserDefaults.standard.set(shortVoiceReplies, forKey: "shortVoiceReplies") }
    }
    /// Version 2.0: a live voice call with Muse beside voice notes. Changing it reconnects,
    /// because the connection itself carries the app identity voice calls need.
    @Published var liveVoiceCalls = UserDefaults.standard.bool(forKey: MuseRuntime.liveVoiceCallsKey) {
        didSet {
            guard oldValue != liveVoiceCalls else { return }
            UserDefaults.standard.set(liveVoiceCalls, forKey: MuseRuntime.liveVoiceCallsKey)
            environment.runtime.restartConnection()
        }
    }
    @Published var videoCallsWithAvatar = UserDefaults.standard.object(forKey: MuseVoiceCall.videoCallsKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(videoCallsWithAvatar, forKey: MuseVoiceCall.videoCallsKey) }
    }
    @Published var museGreetsFirst = MuseVoiceCall.greets {
        didSet { UserDefaults.standard.set(museGreetsFirst, forKey: MuseVoiceCall.greetingKey) }
    }
    @Published var isVoiceCallOpen = false
    /// True when the chat has room to show a call beside it (an iPad), so no card is presented.
    @Published var callIsInline = false
    /// The call button wakes up 2 s after Muse is connected, so a tap right after launch or a
    /// reconnect never lands on a connection that is still settling.
    @Published private(set) var isCallReady = false
    private var callReadiness: DispatchWorkItem?
    lazy var voiceCall: MuseVoiceCall = {
        let call = MuseVoiceCall(runtime: environment.runtime)
        call.onTrace = { [weak self] step in self?.environment.diagnostics.record("call", detail: step) }
        call.onTranscript = { [weak self] fromUser, text in
            DispatchQueue.main.async { self?.addLiveCallLine(fromUser: fromUser, text: text) }
        }
        return call
    }()

    /// A voice call's sentences shown in the chat as they are said. They are stand-ins: when the
    /// call ends and the chat's history has Muse's own record of it, they make way for that.
    private var liveCallItemIDs: Set<UUID> = []
    private var liveCallStartedAt: Date?
    private func addLiveCallLine(fromUser: Bool, text: String) {
        guard isVoiceCallOpen else { return }
        if liveCallStartedAt == nil { liveCallStartedAt = Date() }
        let item = MuseChatItem(author: fromUser ? .user : .muse, text: text, sessionID: activeChatSessionID)
        liveCallItemIDs.insert(item.id)
        chatItems.append(item)
    }
    @Published var pendingVoiceNote: MusePendingVoiceNote?
    @Published var voiceHint: String?
    @Published var isCloudSyncEnabled: Bool {
        didSet {
            environment.chatCloud.isEnabled = isCloudSyncEnabled
            guard isCloudSyncEnabled else { return }
            environment.chatCloud.synchronize()
            applyCloudHistory()
            environment.chatCloud.publish(chatItems)
        }
    }
    @Published var isSendingChat = false
    @Published var isAwaitingReply = false
    @Published var museActivity: String?
    @Published var approvalPrompt: MuseApprovalPrompt?
    @Published var card: MuseCard? = MuseCard.loadPinned() {
        didSet {
            MuseCard.savePinned(card)
            publishWidget()
        }
    }
    @Published var agentIdentity = MuseAgentName.saved.map(MuseAgentIdentity.init(name:)) {
        didSet { publishWidget() }
    }
    @Published var agentAvatar: Data? {
        didSet { MuseWidgetPublisher.publishAvatar(agentAvatar) }
    }
    @Published var avatarFiles: [String: URL] = [:]
    @Published var avatarOneShot: String?
    @Published var avatarsPreparing = 0
    @Published var isSettingsOpen = false
    @Published var avatarVersion = UUID()
    @Published var avatarRequested = false
    @Published var drawnImage: UIImage?
    @Published var deviceAudio: MuseDeviceAudio?
    @Published var commandToast: MuseCommandToast?
    @Published var batterySummary = ""
    @Published var screenBrightness = Double(UIScreen.main.brightness)
    @Published var speechVolume = Double(MuseSpeechVolume.current)
    @Published var approvedShortcuts: [String] = []
    @Published var approvedDevices: [MuseLANGrant] = []
    @Published var isRecordingVoice = false
    @Published var recordingSeconds = 0
    @Published var keepScreenAwake: Bool {
        didSet {
            UserDefaults.standard.set(keepScreenAwake, forKey: Self.keepScreenAwakeKey)
            applyIdleTimerPolicy()
        }
    }

    let environment: AppEnvironment
    private static let keepScreenAwakeKey = "keepScreenAwake"
    private static let voiceRecordModeKey = "voiceRecordMode"
    private static let peerSyncKey = "peerSyncEnabled"
    private static let chatSessionsKey = "museChatSessions"
    private static let activeChatSessionKey = "activeChatSession"
    private var voiceHintReset: DispatchWorkItem?
    private var waitingForSettingsReturn = false
    private var chatTimeline = MuseChatTimeline()
    private var replyItemIDs: [String: UUID] = [:]
    private var replyTimeout: DispatchWorkItem?
    private var replyDetach: DispatchWorkItem?
    private var recordingTimer: Timer?
    private var requestGeneration = 0
    private var pendingUserItemID: UUID?
    private var serverHistorySyncInFlight = false

    init(environment: AppEnvironment) {
        self.environment = environment
        let history = environment.chatStore.load()
        chatItems = history
        var savedSessions = Self.loadChatSessions()
        Self.discoverChatSessions(in: history, sessions: &savedSessions)
        chatSessions = savedSessions
        activeChatSessionID = UserDefaults.standard.string(forKey: Self.activeChatSessionKey)
        for item in history {
            if let messageID = item.museMessageID { replyItemIDs[messageID] = item.id }
        }
        voiceRecordMode = UserDefaults.standard.string(forKey: Self.voiceRecordModeKey)
            .flatMap(MuseVoiceRecordMode.init(rawValue:)) ?? .tap
        isCloudSyncEnabled = environment.chatCloud.isEnabled
        isPeerSyncEnabled = UserDefaults.standard.object(forKey: Self.peerSyncKey) as? Bool ?? false
        keepScreenAwake = UserDefaults.standard.object(forKey: Self.keepScreenAwakeKey) as? Bool ?? true
        let hasToken = environment.credentialStore.loadSDKToken() != nil
        let hasPairing = environment.credentialStore.loadDeviceCredentials() != nil
        tokenSaved = hasToken
        isPaired = hasPairing
        #if DEBUG
        // Lets a device that cannot be paired right now show the chat, to check iCloud history.
        if ProcessInfo.processInfo.arguments.contains("--history-only") {
            UserDefaults.standard.set(true, forKey: "debugHistoryOnly")
        }
        if UserDefaults.standard.bool(forKey: "debugHistoryOnly") { isPaired = true }
        #endif
        pairingState = environment.pairing.state
        runtimeState = environment.runtime.state
        networkName = CurrentWiFi.preferredSSID() ?? ""
        setupStep = hasToken ? 2 : 0

        refreshPermissions()
        bindServices()
        refreshDocuments()
        environment.runtime.setChatSession(activeChatSessionID)
    }

    var deviceName: String { environment.identity.bluetoothName }

    var visibleChatItems: [MuseChatItem] { chatItems.filter { $0.sessionID == activeChatSessionID } }

    var activeChatTitle: String {
        guard let activeChatSessionID else { return PalL10n.text("Основной чат") }
        return chatSessions.first(where: { $0.id == activeChatSessionID })?.title
            ?? PalL10n.text("Дополнительный чат")
    }

    var latestMuseReply: MuseChatItem? {
        visibleChatItems.last(where: { $0.author == .muse && !$0.text.isEmpty })
    }

    /// A newly paired gadget gets a chat of its own, named after it, so its messages, calls and
    /// Muse's replies stay out of the main chat. Muse creates the chat with its first message.
    private static let gadgetChatKey = "gadgetChatSession"
    func ensureGadgetChat() {
        guard UserDefaults.standard.string(forKey: Self.gadgetChatKey) == nil else { return }
        let session = MuseChatSession(id: UUID().uuidString.lowercased(), title: environment.identity.displayName)
        UserDefaults.standard.set(session.id, forKey: Self.gadgetChatKey)
        UserDefaults.standard.set(true, forKey: Self.gadgetGreetingKey)
        chatSessions.append(session)
        persistChatSessions()
        selectChat(session.id)
        environment.diagnostics.record("gadget_chat", detail: "created")
    }

    /// The gadget chat's first message, sent once after a new pairing. Muse names a chat after its
    /// first message, so this gives the chat a name that says what it is, and tells Muse too.
    private static let gadgetGreetingKey = "gadgetChatGreetingPending"
    private func sendGadgetGreetingIfNeeded() {
        guard UserDefaults.standard.bool(forKey: Self.gadgetGreetingKey),
              let chat = UserDefaults.standard.string(forKey: Self.gadgetChatKey),
              activeChatSessionID == chat else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.canSendToMuse, !self.isAwaitingReply,
                  UserDefaults.standard.bool(forKey: Self.gadgetGreetingKey) else { return }
            UserDefaults.standard.set(false, forKey: Self.gadgetGreetingKey)
            self.environment.diagnostics.record("gadget_chat", detail: "greeting")
            self.sendChat(PalL10n.format("gadget_chat.greeting_format", self.environment.identity.displayName))
        }
    }

    /// True once Muse has the open chat, that is, once a message in it has an ID from Muse.
    var openChatExistsInMuse: Bool {
        activeChatSessionID == nil || visibleChatItems.contains { $0.museMessageID != nil }
    }

    func createSideChat() {
        guard !isSendingChat, !isAwaitingReply else { return }
        let session = MuseChatSession(
            id: UUID().uuidString.lowercased(),
            title: PalL10n.text("Новый чат")
        )
        chatSessions.append(session)
        persistChatSessions()
        selectChat(session.id)
    }

    func selectChat(_ sessionID: String?) {
        guard !isSendingChat, !isAwaitingReply, activeChatSessionID != sessionID else { return }
        activeChatSessionID = sessionID
        if let sessionID { UserDefaults.standard.set(sessionID, forKey: Self.activeChatSessionKey) }
        else { UserDefaults.standard.removeObject(forKey: Self.activeChatSessionKey) }
        chatTimeline = MuseChatTimeline()
        replyItemIDs = Dictionary(uniqueKeysWithValues: visibleChatItems.compactMap { item in
            item.museMessageID.map { ($0, item.id) }
        })
        environment.runtime.setChatSession(sessionID)
    }

    func refreshDocuments() { documentFiles = environment.documents.files() }

    func downloadDocument(_ name: String) {
        guard !isTransferringDocument, let remote = MuseDocumentPath.remotePath(name) else {
            documentStatus = PalL10n.text("Введите безопасное имя файла."); return
        }
        isTransferringDocument = true
        documentStatus = PalL10n.text("Получаем файл из Muse…")
        environment.runtime.readVMDocument(path: remote) { [weak self] result in
            guard let self else { return }
            self.isTransferringDocument = false
            switch result {
            case .success(let data):
                do {
                    _ = try self.environment.documents.save(data, named: remote)
                    self.refreshDocuments()
                    self.documentStatus = PalL10n.text("Файл сохранён на устройстве.")
                } catch { self.documentStatus = Self.describe(error) }
            case .failure(let error):
                if case MuseRuntimeError.requestFailed(403) = error { self.vmFilesAllowed = false }
                self.documentStatus = Self.describe(error)
            }
        }
    }

    func uploadDocument(_ url: URL) {
        guard !isTransferringDocument else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              !data.isEmpty, data.count <= MuseDocumentPath.maxBytes,
              let remote = MuseDocumentPath.remotePath(url.lastPathComponent) else {
            documentStatus = PalL10n.text("Файл недоступен или больше 1 МБ."); return
        }
        isTransferringDocument = true
        documentStatus = PalL10n.text("Отправляем файл в Muse…")
        environment.runtime.writeVMDocument(path: remote, data: data) { [weak self] result in
            guard let self else { return }
            self.isTransferringDocument = false
            switch result {
            case .success:
                _ = try? self.environment.documents.save(data, named: remote)
                self.refreshDocuments()
                self.documentStatus = PalL10n.text("Файл доступен Muse.")
            case .failure(let error):
                if case MuseRuntimeError.requestFailed(403) = error { self.vmFilesAllowed = false }
                self.documentStatus = Self.describe(error)
            }
        }
    }

    func removeLocalDocument(_ url: URL) {
        environment.documents.remove(url)
        refreshDocuments()
    }

    private func persistChatSessions() {
        if let data = try? JSONEncoder().encode(chatSessions) {
            UserDefaults.standard.set(data, forKey: Self.chatSessionsKey)
        }
    }

    private static func loadChatSessions() -> [MuseChatSession] {
        guard let data = UserDefaults.standard.data(forKey: chatSessionsKey) else { return [] }
        return (try? JSONDecoder().decode([MuseChatSession].self, from: data)) ?? []
    }

    private static func discoverChatSessions(in items: [MuseChatItem], sessions: inout [MuseChatSession]) {
        let orderedIDs = items.compactMap(\.sessionID).reduce(into: [String]()) { ids, id in
            if !ids.contains(id) { ids.append(id) }
        }
        for id in orderedIDs {
            let title = automaticChatTitle(items.first { $0.sessionID == id && $0.author == .user }?.text)
                ?? automaticChatTitle(items.first { $0.sessionID == id }?.text)
                ?? PalL10n.text("Дополнительный чат")
            if let index = sessions.firstIndex(where: { $0.id == id }), !sessions[index].hasCustomTitle {
                sessions[index].title = title
            } else if !sessions.contains(where: { $0.id == id }) {
                sessions.append(MuseChatSession(id: id, title: title))
            }
        }
        if let data = try? JSONEncoder().encode(sessions) { UserDefaults.standard.set(data, forKey: chatSessionsKey) }
    }

    private static func automaticChatTitle(_ text: String?) -> String? {
        guard let text else { return nil }
        let clean = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        return clean.count <= 42 ? clean : String(clean.prefix(41)) + "…"
    }

    var pairedAccount: String? {
        let value = environment.credentialStore.loadDeviceCredentials()?.username ?? ""
        return value.isEmpty ? nil : value
    }

    var currentSSIDWasDetected: Bool {
        guard let detected = CurrentWiFi.ssid() else { return false }
        return detected == networkName
    }

    func bindServices() {
        environment.pairing.onStateChange = { [weak self] state in
            guard let self else { return }
            self.pairingState = state
            self.environment.diagnostics.record("pairing_state", detail: MuseDiagnostics.label(state))
            if state == .paired {
                withAnimation(.easeInOut) { self.isPaired = true }
                self.applyIdleTimerPolicy()
            }
        }
        environment.pairing.onNewPairing = { [weak self] in self?.ensureGadgetChat() }
        environment.pairing.onLog = { [weak self] message in
            guard let self else { return }
            self.diagnostics.append(message)
            if self.diagnostics.count > 80 { self.diagnostics.removeFirst() }
        }
        environment.runtime.onStateChange = { [weak self] state in
            guard let self else { return }
            self.runtimeState = state
            self.environment.diagnostics.record("runtime_state", detail: MuseDiagnostics.label(state))
            if state == .registered {
                self.sendGadgetGreetingIfNeeded()
                self.pruneDeletedChats()
                self.syncServerHistory()
                self.environment.runtime.probeFileAccess { [weak self] allowed in
                    if let allowed { self?.vmFilesAllowed = allowed }
                }
            }
            self.updateCallReadiness(state)
        }
        environment.runtime.onLog = { [weak self] message in
            guard let self else { return }
            self.diagnostics.append(message)
            if self.diagnostics.count > 80 { self.diagnostics.removeFirst() }
        }
        environment.approvals.onPromptChange = { [weak self] prompt in
            self?.approvalPrompt = prompt
        }
        environment.grants.onChange = { [weak self] in self?.refreshGrants() }
        refreshGrants()
        NotificationCenter.default.addObserver(
            forName: .museCardChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.card = note.object as? MuseCard
        }
        chatTimeline.onNote = { [weak self] note in
            self?.environment.diagnostics.record("late", detail: note)
        }
        environment.runtime.onChatRecord = { [weak self] record in
            guard let self else { return }
            self.apply(self.chatTimeline.feed(record))
        }
        environment.runtime.onAgentIdentity = { [weak self] identity in
            self?.agentIdentity = identity
        }
        NotificationCenter.default.addObserver(
            forName: .museAgentNameChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            if let name = note.object as? String { self?.agentIdentity = MuseAgentIdentity(name: name) }
        }
        environment.runtime.onCommandFinished = { [weak self] command, succeeded in
            self?.showToast(for: command, succeeded: succeeded)
            self?.environment.diagnostics.record("command_finish", detail: "\(command.prefix(96)):\(succeeded ? "success" : "failure")")
        }
        agentAvatar = environment.vmImages.currentAvatar()
        reloadAvatarAnimations()
        refreshBattery()
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshBattery()
            }
        }
        for name in [UIScreen.brightnessDidChangeNotification, Notification.Name.museBrightnessChanged] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.screenBrightness = Double(UIScreen.main.brightness)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .museSpeechVolumeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.speechVolume = Double(MuseSpeechVolume.current)
        }
        NotificationCenter.default.addObserver(
            forName: .museDrawnImageChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.drawnImage = note.object as? UIImage
        }
        NotificationCenter.default.addObserver(
            forName: .museDeviceAudioChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.deviceAudio = note.object as? MuseDeviceAudio
        }
        NotificationCenter.default.addObserver(
            forName: .museAvatarChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.agentAvatar = self.environment.vmImages.currentAvatar()
            self.avatarRequested = false
            self.reloadAvatarAnimations()
        }
        NotificationCenter.default.addObserver(
            forName: .museAvatarPreparing,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.avatarsPreparing = note.object as? Int ?? 0
        }
        NotificationCenter.default.addObserver(
            forName: .museAvatarPlay,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let request = note.object as? MuseAvatarPlayRequest else { return }
            self?.avatarOneShot = request.name
            DispatchQueue.main.asyncAfter(deadline: .now() + request.duration) {
                if self?.avatarOneShot == request.name { self?.avatarOneShot = nil }
            }
        }
        applyIdleTimerPolicy()
        publishWidget()
        MuseWidgetPublisher.publishAvatar(environment.vmImages.currentAvatar())
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.environment.chatStore.flush()
                self?.environment.chatCloud.flush()
                self?.environment.chatPeers.stop()
            }
        }
        environment.chatPeers.onHistory = { [weak self] history in self?.applyRemoteHistory(history) }
        environment.chatPeers.onPeerCountChange = { [weak self] count in self?.nearbyGadgetCount = count }
        environment.chatPeers.onLog = { [weak self] message in
            guard let self else { return }
            self.diagnostics.append(message)
            if self.diagnostics.count > 80 { self.diagnostics.removeFirst() }
        }
        environment.chatPeers.publish(chatItems, clearedBefore: environment.chatCloud.clearedBefore)
        startPeerSyncIfAllowed()
        environment.chatCloud.onRemoteChange = { [weak self] in self?.applyCloudHistory() }
        environment.chatCloud.start()
        applyCloudHistory()
        environment.chatCloud.publish(chatItems)
        NotificationCenter.default.addObserver(
            forName: .museCaptionChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.caption = note.object as? String ?? ""
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.environment.runtime.resumeIfNeeded()
            if self.runtimeState == .registered { self.syncServerHistory() }
            self.environment.chatCloud.synchronize()
            self.applyCloudHistory()
            self.startPeerSyncIfAllowed()
            guard self.waitingForSettingsReturn else { return }
            self.waitingForSettingsReturn = false
            self.environment.permissions.resetLocalNetworkStatusForRecheck()
            self.refreshPermissions()
        }
    }

    func refreshPermissions() {
        permissionStates = Dictionary(uniqueKeysWithValues: AppPermission.allCases.map {
            ($0, environment.permissions.status(for: $0))
        })
    }

    func request(_ permission: AppPermission) {
        environment.diagnostics.record("permission_request", detail: String(describing: permission))
        if permissionStates[permission] == .denied {
            openSystemSettings()
            return
        }
        environment.permissions.request(permission) { [weak self] state in
            self?.permissionStates[permission] = state
            self?.environment.diagnostics.record("permission_result", detail: "\(String(describing: permission)):\(String(describing: state))")
            if permission == .location, state == .granted {
                self?.refreshNetworkName()
            }
        }
    }

    func refreshNetworkName() {
        if let detected = CurrentWiFi.ssid() { networkName = detected }
    }

    func openSystemSettings() {
        waitingForSettingsReturn = true
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    func saveNetworkName() {
        let clean = networkName.trimmingCharacters(in: .whitespacesAndNewlines)
        networkName = clean
        CurrentWiFi.saveFallbackSSID(clean)
    }

    func pasteToken() {
        guard let value = UIPasteboard.general.string, !value.isEmpty else {
            alertMessage = PalL10n.text("В буфере обмена нет текста. Скопируйте SDK Token и попробуйте ещё раз.")
            return
        }
        tokenDraft = value.trimmingCharacters(in: .whitespacesAndNewlines)
        saveToken()
    }

    func saveToken() {
        let candidate = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try environment.pairing.saveSDKToken(candidate)
            startPeerSyncIfAllowed()
            if UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) == candidate {
                UIPasteboard.general.string = ""
            }
            tokenDraft = ""
            tokenSaved = true
            isEditingToken = false
        } catch {
            alertMessage = PalL10n.text("Этот SDK Token не похож на действующий ключ Muse. Скопируйте его целиком, без пробелов.")
        }
    }

    func beginTokenReplacement() {
        tokenDraft = ""
        isEditingToken = true
        isPaired = false
        setupStep = 1
    }

    func cancelTokenReplacement() {
        tokenDraft = ""
        isEditingToken = false
    }

    func startPairing() {
        saveNetworkName()
        environment.diagnostics.record("pairing_start")
        environment.pairing.start()
    }

    func stopPairing() {
        environment.diagnostics.record("pairing_stop")
        environment.pairing.stop()
    }

    func requestAvatar() {
        avatarRequested = true
        sendChat(PalL10n.format("avatar.request_format", environment.identity.displayName))
    }

    /// What the avatar should be doing now. A movement Muse asked for wins until it has played.
    var avatarAnimationName: String {
        avatarOneShot ?? avatarState.rawValue
    }

    private var avatarState: MuseAvatarState {
        if deviceAudio == .speaking { return .speaking }
        if deviceAudio == .listening || isRecordingVoice { return .listening }
        return isAwaitingReply || museActivity != nil ? .thinking : .idle
    }

    private func reloadAvatarAnimations() {
        avatarFiles = environment.vmImages.avatarVideoFiles()
        avatarVersion = UUID()
    }

    var chatStatus: String {
        switch deviceAudio {
        case .speaking: return PalL10n.text("Говорит")
        case .listening: return PalL10n.text("Слушает")
        case nil: break
        }
        if isRecordingVoice { return PalL10n.text("Слушает") }
        if let activity = museActivity, !activity.isEmpty { return activity }
        return runtimeState == .registered
            ? PalL10n.text("Подключено")
            : runtimeState.shortTitle
    }

    func clearAvatar() {
        environment.vmImages.clearAvatar()
    }

    func setScreenBrightness(_ level: Double) {
        screenBrightness = level
        UIScreen.main.brightness = CGFloat(level)
    }

    func setSpeechVolume(_ volume: Double) {
        speechVolume = volume
        MuseSpeechVolume.set(Int(volume.rounded()))
    }

    private func refreshBattery() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        batterySummary = MuseDeviceSummary.text(
            batteryLevel: UIDevice.current.batteryLevel,
            batteryState: UIDevice.current.batteryState,
            freeBytes: (try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()))?[.systemFreeSize] as? Int64
        )
    }

    private func showToast(for command: String, succeeded: Bool) {
        guard let toast = MuseCommandToast(command: command, succeeded: succeeded) else { return }
        commandToast = toast
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.commandToast?.id == toast.id { self?.commandToast = nil }
        }
    }

    func sendChat(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, canSendToMuse else { return }
        let item = MuseChatItem(author: .user, text: clean, sessionID: activeChatSessionID)
        environment.diagnostics.record("chat_send", detail: activeChatSessionID == nil ? "main" : "side")
        chatItems.append(item)
        pendingUserItemID = item.id
        let generation = beginRequest()
        environment.runtime.sendChat(clean, sessionID: activeChatSessionID) { [weak self] result in
            self?.finishRequest(result, generation: generation)
        }
    }

    func sendPhoto(_ image: UIImage, caption: String) {
        guard canSendToMuse else { return }
        environment.diagnostics.record("photo_send")
        let clean = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = beginRequest()
        DispatchQueue.global(qos: .userInitiated).async {
            let original = image.jpegData(compressionQuality: 0.95)
            let jpeg = original.flatMap { MuseJPEG.bounded($0, maxBytes: 1_048_576, maxDimension: 1_600) }
            let preview = jpeg
                .flatMap { MuseJPEG.bounded($0, maxBytes: 128 * 1024, maxDimension: 640) }
                .flatMap(UIImage.init(data:))
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let jpeg else {
                    self.finishRequest(.failure(MuseRuntimeError.payloadTooLarge), generation: generation)
                    return
                }
                let item = MuseChatItem(
                    author: .user,
                    text: clean,
                    image: preview,
                    sessionID: self.activeChatSessionID
                )
                self.chatItems.append(item)
                self.pendingUserItemID = item.id
                self.environment.runtime.sendImage(
                    jpeg: jpeg,
                    message: clean,
                    sessionID: self.activeChatSessionID
                ) { [weak self] result in
                    self?.finishRequest(result, generation: generation)
                }
            }
        }
    }

    func sendDocument(_ url: URL) {
        guard canSendToMuse else { return }
        environment.diagnostics.record("document_send")
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              !data.isEmpty, data.count <= 2 * 1024 * 1024 else {
            alertMessage = PalL10n.text("Документ недоступен или больше 2 МБ.")
            return
        }
        let filename = url.lastPathComponent.isEmpty ? "document" : url.lastPathComponent
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let item = MuseChatItem(
            author: .user,
            text: "📎 " + filename,
            sessionID: activeChatSessionID
        )
        chatItems.append(item)
        pendingUserItemID = item.id
        let generation = beginRequest()
        environment.runtime.sendDocument(
            data: data,
            filename: filename,
            mimeType: mime,
            sessionID: activeChatSessionID
        ) { [weak self] result in
            self?.finishRequest(result, generation: generation)
        }
    }

    var canSendToMuse: Bool {
        runtimeState == .registered && !isSendingChat
    }

    var canUseCamera: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
            && environment.permissions.status(for: .camera) != .denied
            && environment.permissions.status(for: .camera) != .restricted
    }

    func explainCameraUnavailable() {
        alertMessage = PalL10n.text("Камера недоступна. Разрешите доступ к камере в системных настройках.")
    }

    func beginHeldVoiceRecording() {
        guard canSendToMuse, !isRecordingVoice else { return }
        switch environment.permissions.status(for: .microphone) {
        case .granted:
            startVoiceRecording()
        case .notDetermined:
            // The prompt takes the finger off the button, so recording starts on the next press.
            environment.permissions.request(.microphone) { [weak self] state in
                self?.permissionStates[.microphone] = state
            }
        default:
            alertMessage = PalL10n.text("Микрофон недоступен. Разрешите доступ к микрофону в системных настройках.")
        }
    }

    func endHeldVoiceRecording() {
        guard isRecordingVoice else { return }
        environment.nativeServices.stopVoiceRecording()
    }

    func toggleVoiceRecording() {
        if isRecordingVoice {
            environment.nativeServices.stopVoiceRecording()
            return
        }
        guard canSendToMuse else { return }
        switch environment.permissions.status(for: .microphone) {
        case .granted:
            startVoiceRecording()
        case .notDetermined:
            environment.permissions.request(.microphone) { [weak self] state in
                self?.permissionStates[.microphone] = state
                if state == .granted { self?.startVoiceRecording() }
            }
        default:
            alertMessage = PalL10n.text("Микрофон недоступен. Разрешите доступ к микрофону в системных настройках.")
        }
    }

    private func startVoiceRecording() {
        environment.diagnostics.record("voice_record_start")
        pendingVoiceNote = nil
        isRecordingVoice = true
        recordingSeconds = 0
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.recordingSeconds += 1
        }
        environment.nativeServices.recordVoiceNote { [weak self] result in
            self?.finishVoiceRecording(result)
        }
    }

    private func finishVoiceRecording(_ result: CommandResult) {
        recordingTimer?.invalidate()
        recordingTimer = nil
        isRecordingVoice = false
        environment.diagnostics.record("voice_record_finish", detail: result.success ? "success" : "failure")
        guard result.success,
              let encoded = result.value["data_base64"] as? String,
              let wav = Data(base64Encoded: encoded) else {
            chatItems.append(MuseChatItem(author: .system, text: PalL10n.text("Не удалось записать голосовую заметку.")))
            return
        }
        let durationMS = result.value["duration_ms"] as? Int ?? 0
        guard durationMS >= 500, canSendToMuse else {
            if voiceRecordMode == .hold { showVoiceHint(PalL10n.text("Удерживайте кнопку, чтобы говорить")) }
            return
        }
        let note = MusePendingVoiceNote(wav: wav, seconds: max(durationMS / 1_000, 1))
        if confirmsVoiceNotes {
            pendingVoiceNote = note
        } else {
            send(note)
        }
    }

    func sendPendingVoiceNote() {
        guard let note = pendingVoiceNote, canSendToMuse else { return }
        pendingVoiceNote = nil
        send(note)
    }

    private func send(_ note: MusePendingVoiceNote) {
        environment.diagnostics.record("voice_send")
        let item = MuseChatItem(
            author: .user,
            text: PalL10n.format("voice.note_format", note.seconds),
            sessionID: activeChatSessionID
        )
        chatItems.append(item)
        pendingUserItemID = item.id
        let generation = beginRequest()
        environment.runtime.sendVoiceNote(
            wav: note.wav,
            sessionID: activeChatSessionID,
            shortReply: shortVoiceReplies
        ) { [weak self] result in
            self?.finishRequest(result, generation: generation)
        }
    }

    private func showVoiceHint(_ text: String) {
        voiceHint = text
        voiceHintReset?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.voiceHint = nil }
        voiceHintReset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func startPeerSyncIfAllowed() {
        if isPeerSyncEnabled, let token = environment.credentialStore.loadSDKToken() {
            environment.chatPeers.start(token: token)
        } else {
            environment.chatPeers.stop()
        }
    }

    private func applyCloudHistory() {
        if let remote = environment.chatCloud.remoteHistory() { applyRemoteHistory(remote) }
    }

    private func applyRemoteHistory(_ remote: MuseSyncedHistory) {
        let cloud = environment.chatCloud
        let merged = MuseChatMerge.merge(local: chatItems, remote: remote, clearedBefore: cloud.clearedBefore)
        cloud.clearedBefore = merged.clearedBefore
        let fingerprint = { (items: [MuseChatItem]) in items.map { "\($0.id)|\($0.updatedAt.timeIntervalSince1970)" } }
        guard fingerprint(merged.items) != fingerprint(chatItems) else { return }
        chatItems = merged.items
        replyItemIDs.removeAll()
        for item in merged.items {
            if let messageID = item.museMessageID { replyItemIDs[messageID] = item.id }
        }
    }

    var peerSyncStatus: String {
        guard isPeerSyncEnabled else { return PalL10n.text("Гаджеты в вашей сети не обмениваются историей.") }
        guard environment.credentialStore.loadSDKToken() != nil else {
            return PalL10n.text("Сначала сохраните SDK Token: по нему гаджеты узнают друг друга.")
        }
        let state = nearbyGadgetCount > 0
            ? PalL10n.format("peer.count_format", nearbyGadgetCount)
            : PalL10n.text("Других гаджетов рядом пока нет.")
        return state + " " + PalL10n.text("Текст чата передаётся в зашифрованном виде напрямую гаджетам с тем же SDK Token, пока приложение открыто на обоих. Apple ID может быть разным.")
    }

    var cloudSyncStatus: String {
        guard isCloudSyncEnabled else { return PalL10n.text("Текст чата хранится только на этом устройстве.") }
        guard environment.chatCloud.isAccountAvailable else {
            return PalL10n.text("На устройстве не выполнен вход в iCloud, поэтому синхронизация не работает.")
        }
        return PalL10n.text("Текст чата появится на устройствах с тем же Apple ID, обычно в течение нескольких минут. Фото остаются там, где их сделали.")
    }

    @discardableResult
    private func beginRequest() -> Int {
        requestGeneration += 1
        chatTimeline.expectRequest()
        isSendingChat = true
        isAwaitingReply = true
        museActivity = nil
        return requestGeneration
    }

    private func finishRequest(_ result: Result<[String: Any], Error>, generation: Int) {
        guard generation == requestGeneration else { return }
        isSendingChat = false
        switch result {
        case .success(let response):
            environment.diagnostics.record("request_finish", detail: "success")
            let payload = response["result"] as? [String: Any] ?? response
            if let messageID = (payload["message_id"] as? String) ?? (payload["reply_to_message_id"] as? String),
               let itemID = pendingUserItemID,
               let index = chatItems.firstIndex(where: { $0.id == itemID }) {
                chatItems[index].museMessageID = messageID
            }
            pendingUserItemID = nil
            apply(chatTimeline.acknowledge(response))
            if isAwaitingReply { scheduleReplyTimeout() }
        case .failure(let error):
            environment.diagnostics.record("request_finish", detail: "failure")
            pendingUserItemID = nil
            chatTimeline.abandonRequest()
            finishWaitingForReply()
            chatItems.append(MuseChatItem(
                author: .system,
                text: Self.describe(error),
                sessionID: activeChatSessionID
            ))
        }
    }

    /// As the SDK's ESP32 firmware does (b4bee64): 20 s after Muse took the request, if it still says
    /// it is working, the gadget stops waiting and keeps the reply for when it comes. A reply that has
    /// not come after 120 s is kept the same way.
    private func scheduleReplyTimeout() {
        replyTimeout?.cancel()
        replyDetach?.cancel()
        let generation = requestGeneration
        let detach = DispatchWorkItem { [weak self] in
            guard let self, generation == self.requestGeneration, self.isAwaitingReply,
                  self.chatTimeline.isMuseWorking else { return }
            self.letGoOfReply(note: "Muse ещё работает над этим. Ответ появится здесь, когда будет готов.")
        }
        replyDetach = detach
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: detach)
        let work = DispatchWorkItem { [weak self] in
            guard let self, generation == self.requestGeneration, self.isAwaitingReply else { return }
            self.letGoOfReply(note: "Muse пока не ответил. Если ответ придёт позже, он появится здесь.")
        }
        replyTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: work)
    }

    /// A message in the open chat that answers no request of this gadget, such as one Muse posted
    /// after a call or a request from the Muse app: the live events don't say which, so the chat's
    /// history is read a moment later, once the message is finished.
    private var historySyncWork: DispatchWorkItem?
    private func scheduleHistorySync() {
        historySyncWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.environment.diagnostics.record("history_sync", detail: "other_message")
            self?.syncServerHistory()
        }
        historySyncWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func letGoOfReply(note: String) {
        let bound = chatTimeline.detachCurrentRequest()
        finishWaitingForReply()
        guard bound else { return }
        environment.diagnostics.record("reply_detached")
        chatItems.append(MuseChatItem(author: .system, text: PalL10n.text(note), sessionID: activeChatSessionID))
        checkHistoryForLateReply(attempt: 0, since: Date())
    }

    /// A safety net the ESP32 lacks: while a late reply is awaited, read the chat's history every 45 s
    /// for ten minutes. The result is noted without content; replies from this chat are merged in.
    private func checkHistoryForLateReply(attempt: Int, since: Date) {
        guard attempt < 14 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            guard let self, self.chatTimeline.isWaitingForLateReply else { return }
            let session = self.chatTimeline.currentSessionID
            self.environment.runtime.fetchChatHistory(limit: 10, sessionID: session) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    let status: String
                    if case MuseRuntimeError.requestFailed(let code) = error { status = String(code) } else { status = "error" }
                    self.environment.diagnostics.record("late", detail: "hist:\(status)")
                case .success(let data):
                    let messages = MuseServerHistory.parse(data)
                    let inChat = messages.filter { session == nil || $0.sessionID == session }
                    let known = Set(self.chatItems.compactMap(\.museMessageID))
                    let newReplies = inChat.filter {
                        $0.author == .muse && $0.createdAt > since && !known.contains($0.messageID)
                    }
                    self.environment.diagnostics.record(
                        "late", detail: "hist:200:n=\(messages.count):chat=\(inChat.count):new=\(newReplies.count)"
                    )
                    if !newReplies.isEmpty {
                        self.chatTimeline.forgetLateRequest(reason: "history")
                        self.environment.diagnostics.record("late_reply", detail: "history")
                        self.chatItems = MuseChatMerge.mergeServer(
                            local: self.chatItems, server: newReplies,
                            clearedBefore: self.environment.chatCloud.clearedBefore
                        )
                        self.replyItemIDs = Dictionary(uniqueKeysWithValues: self.chatItems.compactMap { item in
                            item.museMessageID.map { ($0, item.id) }
                        })
                    }
                }
                self.checkHistoryForLateReply(attempt: attempt + 1, since: since)
            }
        }
    }

    private func finishWaitingForReply() {
        replyTimeout?.cancel()
        replyTimeout = nil
        replyDetach?.cancel()
        replyDetach = nil
        isAwaitingReply = false
        museActivity = nil
    }

    private func apply(_ updates: [MuseChatUpdate]) {
        for update in updates {
            switch update {
            case .reply(let messageID, let text, let done):
                if let itemID = replyItemIDs[messageID],
                   let index = chatItems.firstIndex(where: { $0.id == itemID }) {
                    chatItems[index].text = text
                } else if !text.isEmpty {
                    let item = MuseChatItem(
                        author: .muse,
                        text: text,
                        museMessageID: messageID,
                        sessionID: activeChatSessionID
                    )
                    replyItemIDs[messageID] = item.id
                    chatItems.append(item)
                }
                if done {
                    finishWaitingForReply()
                }
                else if !text.isEmpty { museActivity = nil }
            case .lateReply(let messageID, let text, let done):
                if let itemID = replyItemIDs[messageID],
                   let index = chatItems.firstIndex(where: { $0.id == itemID }) {
                    chatItems[index].text = text
                } else if !text.isEmpty {
                    let item = MuseChatItem(author: .muse, text: text, museMessageID: messageID, sessionID: activeChatSessionID)
                    replyItemIDs[messageID] = item.id
                    chatItems.append(item)
                    environment.diagnostics.record("late_reply")
                }
                _ = done
            case .presentation(let id, let text, let late):
                guard replyItemIDs[id] == nil else { break }
                let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                let marker = PalL10n.text(String(lines.first ?? ""))
                let body = lines.count > 1 ? "\n" + lines[1] : ""
                let item = MuseChatItem(author: .muse, text: marker + body, sessionID: activeChatSessionID)
                replyItemIDs[id] = item.id
                chatItems.append(item)
                environment.diagnostics.record("presentation", detail: late ? "late" : "current")
            case .otherMessage:
                scheduleHistorySync()
            case .activity(let text):
                museActivity = text?.isEmpty == false ? text : nil
            case .finished:
                finishWaitingForReply()
            }
        }
    }

    /// Stops waiting, not Muse: Muse has no cancel route for chat, so its reply still arrives later.
    func stopCurrentReply() {
        guard isSendingChat || isAwaitingReply else { return }
        requestGeneration += 1
        pendingUserItemID = nil
        isSendingChat = false
        if chatTimeline.hasBoundRequest {
            letGoOfReply(note: "Ожидание остановлено. Если Muse всё же ответит, ответ появится здесь.")
        } else {
            chatTimeline.stopCurrentReply()
            finishWaitingForReply()
        }
    }

    private func syncServerHistory() {
        guard !serverHistorySyncInFlight else { return }
        serverHistorySyncInFlight = true
        isRefreshingChats = true
        environment.runtime.fetchChatHistory(limit: 50, sessionID: activeChatSessionID) { [weak self] result in
            guard let self else { return }
            self.serverHistorySyncInFlight = false
            self.isRefreshingChats = false
            guard case .success(let data) = result else { return }
            let server = MuseServerHistory.parse(data)
            if !self.liveCallItemIDs.isEmpty, !self.isVoiceCallOpen, let start = self.liveCallStartedAt,
               server.contains(where: { $0.createdAt >= start.addingTimeInterval(-5) }) {
                self.chatItems.removeAll { self.liveCallItemIDs.contains($0.id) }
                self.liveCallItemIDs.removeAll()
                self.liveCallStartedAt = nil
            }
            guard !server.isEmpty else { return }
            let merged = MuseChatMerge.mergeServer(
                local: self.chatItems,
                server: server,
                clearedBefore: self.environment.chatCloud.clearedBefore
            )
            let fingerprint = { (items: [MuseChatItem]) in
                items.map { "\($0.id)|\($0.museMessageID ?? "")|\($0.text)|\($0.updatedAt.timeIntervalSince1970)" }
            }
            Self.discoverChatSessions(in: merged, sessions: &self.chatSessions)
            guard fingerprint(merged) != fingerprint(self.chatItems) else { return }
            self.chatItems = merged
            self.replyItemIDs = Dictionary(uniqueKeysWithValues: merged.compactMap { item in
                item.museMessageID.map { ($0, item.id) }
            })
        }
    }

    /// The gadget cannot list the account's chats (muse-gadget-sdk#336), so it cannot see one deleted
    /// in the Muse app. A chat that existed, having messages with IDs from Muse, is asked for its
    /// history: when Muse no longer has it (404, or no messages at all), it leaves the list with its
    /// messages here. Runs on connecting and on Refresh Chats.
    private func pruneDeletedChats() {
        let existed = chatSessions.filter { session in
            chatItems.contains { $0.sessionID == session.id && $0.museMessageID != nil }
        }
        for session in existed {
            environment.runtime.fetchChatHistory(limit: 1, sessionID: session.id) { [weak self] result in
                guard let self else { return }
                let gone: Bool
                switch result {
                case .failure(MuseRuntimeError.requestFailed(let status)): gone = status == 404
                case .failure: gone = false
                case .success(let data): gone = MuseServerHistory.parse(data).isEmpty
                }
                guard gone else { return }
                self.environment.diagnostics.record("chat_pruned")
                self.removeChatLocally(session.id)
            }
        }
    }

    private func removeChatLocally(_ sessionID: String) {
        if activeChatSessionID == sessionID {
            let gadget = UserDefaults.standard.string(forKey: Self.gadgetChatKey)
            let next = gadget != sessionID && chatSessions.contains(where: { $0.id == gadget }) ? gadget : nil
            guard !isSendingChat, !isAwaitingReply else { return }
            selectChat(next)
        }
        chatSessions.removeAll { $0.id == sessionID }
        persistChatSessions()
        chatItems.removeAll { $0.sessionID == sessionID }
        if UserDefaults.standard.string(forKey: Self.gadgetChatKey) == sessionID {
            // The gadget's own chat was deleted in Muse: it gets a new one, greeted as after pairing.
            UserDefaults.standard.removeObject(forKey: Self.gadgetChatKey)
            ensureGadgetChat()
            sendGadgetGreetingIfNeeded()
        }
    }

    func refreshChatSessions() {
        pruneDeletedChats()
        syncServerHistory()
    }

    func beginConnectingChat() {
        connectChatReference = UIPasteboard.general.string ?? ""
        connectChatName = ""
        isConnectChatOpen = true
    }

    func connectExistingChat() {
        guard let id = MuseChatSessionReference.id(from: connectChatReference) else {
            alertMessage = PalL10n.text("Вставьте ссылку на чат Muse или его ID.")
            return
        }
        if let index = chatSessions.firstIndex(where: { $0.id == id }) {
            let name = connectChatName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                chatSessions[index].title = name
                chatSessions[index].hasCustomTitle = true
                persistChatSessions()
            }
            isConnectChatOpen = false
            selectChat(id)
            alertMessage = PalL10n.text("Этот чат уже подключён. Я открыл его.")
            return
        }
        let name = connectChatName.trimmingCharacters(in: .whitespacesAndNewlines)
        let shortID = String(id.prefix(8))
        chatSessions.append(MuseChatSession(
            id: id,
            title: name.isEmpty ? PalL10n.format("connected_chat.title_format", shortID) : name,
            hasCustomTitle: !name.isEmpty
        ))
        persistChatSessions()
        isConnectChatOpen = false
        selectChat(id)
    }

    private func publishWidget() {
        MuseWidgetPublisher.publish(name: agentIdentity?.name, card: card)
    }

    private func updateCallReadiness(_ state: MuseRuntimeState) {
        callReadiness?.cancel()
        guard state == .registered else {
            isCallReady = false
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.isCallReady = true }
        callReadiness = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func openVoiceCall() {
        // The call still waits up to 15 s for Muse if the connection drops just before a tap.
        guard isCallReady, !isRecordingVoice, !isVoiceCallOpen else { return }
        isVoiceCallOpen = true
        UIApplication.shared.isIdleTimerDisabled = true
        startCallInOpenChat()
    }

    /// A chat Muse has not created yet cannot take a call, so until then it goes to the main one.
    func startCallInOpenChat() {
        let thread = openChatExistsInMuse ? activeChatSessionID : nil
        environment.diagnostics.record("call", detail: thread == nil ? "thread=main" : "thread=side")
        voiceCall.start(threadID: thread)
    }

    static let callSpeakingAnimation = "call_speaking"
    @Published var callAvatarRequested = false

    /// Asks Muse to draw the talking animation a call plays, leaving its other animations alone.
    func requestCallAvatar() {
        callAvatarRequested = true
        sendChat(PalL10n.format("avatar.call_request_format", environment.identity.displayName))
    }

    /// Closes the call. A card's dismissal then ends it; a call shown beside the chat ends here.
    func closeVoiceCall() {
        let wasInline = callIsInline
        isVoiceCallOpen = false
        if wasInline { voiceCallDismissed() }
    }

    /// Runs once whenever the call card goes away, by a button or by a swipe.
    func voiceCallDismissed() {
        voiceCall.hangUp()
        applyIdleTimerPolicy()
        // Muse keeps the call in the main conversation; show it here too.
        syncServerHistory()
    }

    private func applyIdleTimerPolicy() {
        // Native commands run only while the app is visible, so a sleeping gadget cannot serve them.
        UIApplication.shared.isIdleTimerDisabled = keepScreenAwake && isPaired
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case MuseRuntimeError.payloadTooLarge:
            return PalL10n.text("Файл слишком большой для отправки в Muse.")
        case MuseRuntimeError.requestTimedOut:
            return PalL10n.text("Muse не подтвердил сообщение вовремя. Попробуйте ещё раз.")
        case MuseRuntimeError.requestFailed(let status):
            return PalL10n.format("send.http_error_format", status)
        default:
            return PalL10n.text("Не удалось отправить сообщение. Канал Muse переподключится автоматически.")
        }
    }

    func answerApproval(granted: Bool) {
        environment.approvals.answer(granted: granted)
    }

    func revokeShortcut(_ name: String) {
        environment.grants.revokeShortcut(name)
    }

    func revokeDevice(_ device: MuseLANGrant) {
        environment.grants.revokeLANDevice(device)
    }

    private func refreshGrants() {
        approvedShortcuts = environment.grants.shortcuts
        approvedDevices = environment.grants.lanDevices
    }

    func clearChatHistory() {
        environment.chatCloud.clearedBefore = Date()
        chatItems.removeAll()
        replyItemIDs.removeAll()
        environment.chatStore.clear()
        environment.chatCloud.flush()
    }

    func forgetPairing() {
        environment.runtime.stop()
        environment.pairing.forgetPairing()
        isPaired = false
        setupStep = 3
        applyIdleTimerPolicy()
    }

    func restartGuide() {
        isPaired = false
        setupStep = 0
    }

    /// True while a saved pairing exists, so the setup guide can be closed without finishing it.
    var canLeaveSetup: Bool { environment.credentialStore.loadDeviceCredentials() != nil }

    func leaveSetup() {
        guard canLeaveSetup else { return }
        if pairingState.isBusy { stopPairing() }
        cancelTokenReplacement()
        isPaired = true
        applyIdleTimerPolicy()
    }

    func resetApp() {
        (UIApplication.shared.delegate as? AppDelegate)?.resetToFirstLaunch()
    }
}

struct MuseAppView: View {
    @StateObject private var model: MuseAppModel
    @ObservedObject private var diagnostics: MuseDiagnostics

    init(environment: AppEnvironment) {
        _model = StateObject(wrappedValue: MuseAppModel(environment: environment))
        _diagnostics = ObservedObject(wrappedValue: environment.diagnostics)
    }

    var body: some View {
        ZStack {
            MuseTheme.background.ignoresSafeArea()
            if model.isPaired {
                MuseMainTabs(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .alert(
                        model.approvalPrompt?.title ?? "",
                        isPresented: Binding(
                            get: { model.approvalPrompt != nil },
                            set: { _ in }
                        ),
                        presenting: model.approvalPrompt
                    ) { _ in
                        Button("Запретить", role: .cancel) { model.answerApproval(granted: false) }
                        Button("Разрешить") { model.answerApproval(granted: true) }
                    } message: { prompt in
                        Text(prompt.message)
                    }
            } else {
                MuseOnboarding(model: model)
                    .transition(.opacity)
            }
        }
        .alert("Pal Again", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("Понятно", role: .cancel) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .alert(PalL10n.text("Помочь улучшить Pal Again?"), isPresented: Binding(
            // Asked once the gadget is paired, not on top of the first setup steps.
            get: { diagnostics.shouldAskForConsent && model.isPaired },
            set: { _ in }
        )) {
            Button(PalL10n.text("Не сейчас"), role: .cancel) { diagnostics.setSharingEnabled(false) }
            Button(PalL10n.text("Отправлять диагностику")) { diagnostics.setSharingEnabled(true) }
        } message: {
            Text(PalL10n.text("Приложение может отправлять разработчику отчёты о сбоях и зависаниях с коротким журналом этапов работы, чтобы быстрее находить ошибки. Текст чата, токены, имя гаджета, файлы, фото и аудио никогда не отправляются. Это можно выключить в настройках."))
        }
        // A sheet: a centred card on iPad, nearly the whole screen on an iPhone.
        .sheet(isPresented: Binding(
            get: { model.isVoiceCallOpen && !model.callIsInline },
            set: { if !$0 { model.isVoiceCallOpen = false } }
        ), onDismiss: model.voiceCallDismissed) {
            MuseVoiceCallView(model: model, call: model.voiceCall)
        }
        .sheet(isPresented: $model.isConnectChatOpen) {
            NavigationView {
                Form {
                    Section {
                        TextField(PalL10n.text("Ссылка или ID чата"), text: $model.connectChatReference)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                        TextField(PalL10n.text("Название на этом устройстве (необязательно)"), text: $model.connectChatName)
                    } footer: {
                        Text(PalL10n.text("Скопируйте ссылку на дополнительный чат в Muse. Pal Again извлечёт из неё ID и будет отправлять сообщения именно в этот чат."))
                    }
                }
                .navigationTitle(PalL10n.text("Подключить чат"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(PalL10n.text("Отмена")) { model.isConnectChatOpen = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(PalL10n.text("Подключить"), action: model.connectExistingChat)
                    }
                }
            }
        }
    }
}

private enum MuseTheme {
    // Solid on purpose: an iPhone 6s struggles with blur behind a scrolling chat.
    static let bar = Color(UIColor.secondarySystemBackground)
    static let accent = Color(red: 0.00, green: 0.64, blue: 0.72)
    static let blue = Color(red: 0.05, green: 0.52, blue: 0.92)
    static let mint = Color(red: 0.00, green: 0.67, blue: 0.57)
    static let card = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.085)
            : UIColor(white: 1, alpha: 0.86)
    })
    static let elevated = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.10)
            : UIColor(white: 0, alpha: 0.055)
    })
    static let stroke = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.13)
            : UIColor(white: 0, alpha: 0.10)
    })
    static let secondary = Color(UIColor.secondaryLabel)
    static let background = LinearGradient(
        colors: [
            Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.025, green: 0.075, blue: 0.10, alpha: 1) : UIColor(red: 0.91, green: 0.98, blue: 1.00, alpha: 1) }),
            Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.02, green: 0.11, blue: 0.13, alpha: 1) : UIColor(red: 0.95, green: 1.00, blue: 0.98, alpha: 1) }),
            Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.02, green: 0.05, blue: 0.09, alpha: 1) : UIColor(red: 0.92, green: 0.97, blue: 1.00, alpha: 1) })
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

private struct MuseCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(18)
            .background(MuseTheme.card)
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(MuseTheme.stroke, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private extension View {
    func museCard() -> some View { modifier(MuseCardModifier()) }

    @ViewBuilder
    func chatKeyboardDismissBehavior(isFocused: FocusState<Bool>.Binding) -> some View {
        let dragToDismiss = DragGesture(minimumDistance: 8)
            .onChanged { value in
                if value.translation.height > 4 { isFocused.wrappedValue = false }
            }

        if #available(iOS 16.0, *) {
            self
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(dragToDismiss)
                .onTapGesture { isFocused.wrappedValue = false }
        } else {
            self
                .simultaneousGesture(dragToDismiss)
                .onTapGesture { isFocused.wrappedValue = false }
        }
    }
}

private struct MusePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let pressedOpacity: Double = configuration.isPressed ? 0.72 : 1.0
        return configuration.label
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(
                LinearGradient(
                    colors: [MuseTheme.accent, MuseTheme.blue],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .opacity(pressedOpacity)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

private struct MuseSecondaryButtonStyle: ButtonStyle {
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundColor(destructive ? .red : MuseTheme.accent)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(MuseTheme.card.opacity(configuration.isPressed ? 0.65 : 1))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(destructive ? Color.red.opacity(0.35) : MuseTheme.stroke, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct SettingsSectionLabel: View {
    let title: String

    var body: some View {
        Text(PalL10n.key(title))
            .font(.caption.weight(.semibold))
            .foregroundColor(MuseTheme.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct MuseOnboarding: View {
    @ObservedObject var model: MuseAppModel

    var body: some View {
        VStack(spacing: 0) {
            onboardingHeader
            ScrollView(showsIndicators: false) {
                Group {
                    switch model.setupStep {
                    case 0: WelcomeStep(model: model)
                    case 1: TokenStep(model: model)
                    case 2: PermissionsStep(model: model)
                    case 3: NetworkStep(model: model)
                    default: PairingStep(model: model)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 34)
            }
            .id(model.setupStep)
        }
    }

    private var onboardingHeader: some View {
        VStack(spacing: 14) {
            HStack {
                MuseMark(size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Pal Again").font(.headline)
                    Text("Make Old Devices Smart Again")
                        .font(.caption)
                        .foregroundColor(MuseTheme.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if model.canLeaveSetup {
                    Button("Вернуться") { withAnimation(.easeInOut) { model.leaveSetup() } }
                        .font(.caption.weight(.bold))
                        .buttonStyle(.bordered)
                        .tint(MuseTheme.blue)
                }
                Text("\(model.setupStep + 1) / 5")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(MuseTheme.secondary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(MuseTheme.elevated)
                    Capsule()
                        .fill(LinearGradient(colors: [MuseTheme.accent, MuseTheme.blue], startPoint: .leading, endPoint: .trailing))
                        .frame(width: proxy.size.width * CGFloat(model.setupStep + 1) / 5)
                }
            }
            .frame(height: 5)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(MuseTheme.bar)
    }
}

private struct MuseMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [MuseTheme.accent, MuseTheme.blue], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

private struct StepIntro: View {
    let eyebrow: String
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(PalL10n.key(eyebrow))
                .font(.caption.weight(.bold))
                .foregroundColor(MuseTheme.mint)
            Text(PalL10n.key(title))
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            Text(PalL10n.key(text))
                .font(.body)
                .foregroundColor(MuseTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WelcomeStep: View {
    @ObservedObject var model: MuseAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            StepIntro(
                eyebrow: "Добро пожаловать",
                title: isPad ? "Старый iPad — новый гаджет для Muse" : "Старый iPhone — новый гаджет для Muse",
                text: "Пять простых шагов. Мы спрячем Bluetooth, ключи и протоколы под капот и будем объяснять только то, что нужно нажать."
            )

            VStack(spacing: 16) {
                FeatureLine(icon: "message.fill", title: "Muse как чат", text: "Сообщения и ответы — на главном экране.")
                FeatureLine(icon: "square.grid.2x2.fill", title: isPad ? "Возможности iPad" : "Возможности iPhone", text: "Экран, голос, камера, геопозиция и датчики.")
                FeatureLine(icon: "lock.shield.fill", title: "Личные данные защищены", text: "Ключ хранится только в системной Связке ключей.")
            }
            .museCard()

            Button("Начать настройку") {
                withAnimation { model.setupStep = 1 }
            }
            .buttonStyle(MusePrimaryButtonStyle())
        }
    }
}

private struct FeatureLine: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundColor(MuseTheme.mint)
                .frame(width: 34, height: 34)
                .background(MuseTheme.mint.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(PalL10n.key(title)).font(.headline)
                Text(PalL10n.key(text)).font(.subheadline).foregroundColor(MuseTheme.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct TokenStep: View {
    @ObservedObject var model: MuseAppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StepIntro(
                eyebrow: "Шаг 2",
                title: "Добавьте ключ Muse",
                text: "Скопируйте личный SDK Token на этом устройстве. Приложение само вставит его и сразу уберёт в Связку ключей."
            )

            VStack(alignment: .leading, spacing: 14) {
                Label {
                    Text(PalL10n.key(model.tokenSaved ? "Ключ сохранён" : "SDK Token"))
                } icon: {
                    Image(systemName: model.tokenSaved ? "checkmark.circle.fill" : "key.fill")
                }
                    .font(.headline)
                    .foregroundColor(model.tokenSaved ? MuseTheme.mint : .primary)

                if !model.tokenSaved || model.isEditingToken {
                    SecureField("mgst_…", text: $model.tokenDraft)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .padding(14)
                        .background(MuseTheme.elevated)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Button {
                        model.pasteToken()
                    } label: {
                        Label("Вставить из буфера", systemImage: "doc.on.clipboard")
                            .frame(maxWidth: .infinity, minHeight: 46)
                    }
                    .buttonStyle(MuseSecondaryButtonStyle())

                    Button("Сохранить введённый ключ") { model.saveToken() }
                        .buttonStyle(MuseSecondaryButtonStyle())
                        .disabled(model.tokenDraft.isEmpty)

                    if model.tokenSaved {
                        Button("Оставить прежний ключ") { model.cancelTokenReplacement() }
                            .font(.subheadline.weight(.semibold))
                    }
                } else {
                    Text("Сам ключ больше не показывается и не попадает в журналы приложения.")
                        .font(.subheadline)
                        .foregroundColor(MuseTheme.secondary)
                    Button("Заменить SDK Token") { model.isEditingToken = true }
                        .font(.subheadline.weight(.semibold))
                }

                Button("Получить ключ на gadgets.muse.ai ↗") {
                    if let url = URL(string: "https://gadgets.muse.ai") { openURL(url) }
                }
                .font(.subheadline.weight(.semibold))
            }
            .museCard()

            Button("Дальше") { withAnimation { model.setupStep = 2 } }
                .buttonStyle(MusePrimaryButtonStyle())
                .disabled(!model.tokenSaved || model.isEditingToken)
                .opacity(model.tokenSaved && !model.isEditingToken ? 1 : 0.45)
        }
    }
}

private struct PermissionsStep: View {
    @ObservedObject var model: MuseAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StepIntro(
                eyebrow: "Шаг 3",
                title: "Разрешите только нужное",
                text: "Нажимайте по одному. iOS покажет системное окно и объяснит, что именно получает приложение. Всё можно изменить позже в Настройках."
            )

            VStack(spacing: 4) {
                ForEach(AppPermission.allCases, id: \.self) { permission in
                    PermissionRow(
                        permission: permission,
                        state: model.permissionStates[permission] ?? .notDetermined,
                        action: { model.request(permission) }
                    )
                    if permission != AppPermission.allCases.last { Divider().overlay(MuseTheme.stroke) }
                }
            }
            .museCard()

            Text("Для создания пары нужны Bluetooth, локальная сеть и геопозиция. Камеру, микрофон и датчики можно разрешить позже, когда они понадобятся.")
                .font(.footnote)
                .foregroundColor(MuseTheme.secondary)

            Button("Дальше") { withAnimation { model.setupStep = 3 } }
                .buttonStyle(MusePrimaryButtonStyle())
        }
        .onAppear { model.refreshPermissions() }
    }
}

private struct PermissionRow: View {
    let permission: AppPermission
    let state: PermissionState
    let action: () -> Void
    @Environment(\.sizeCategory) private var sizeCategory

    var body: some View {
        Group {
            if sizeCategory.isAccessibilityCategory {
                VStack(alignment: .leading, spacing: 10) {
                    permissionDescription
                    permissionButton.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(spacing: 12) {
                    permissionDescription
                    Spacer(minLength: 8)
                    permissionButton
                }
            }
        }
        .padding(.vertical, 9)
    }

    private var permissionDescription: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: permission.icon)
                .foregroundColor(state == .granted ? MuseTheme.mint : MuseTheme.blue)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.localizedTitle).font(.subheadline.weight(.semibold))
                Text(permission.explanation).font(.caption).foregroundColor(MuseTheme.secondary)
            }
        }
    }

    private var permissionButton: some View {
        Button(state.buttonTitle, action: action)
            .font(.caption.weight(.bold))
            .buttonStyle(.bordered)
            .tint(state == .granted ? MuseTheme.mint : MuseTheme.blue)
            .disabled(state == .granted || state == .restricted)
    }
}

private struct NetworkStep: View {
    @ObservedObject var model: MuseAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StepIntro(
                eyebrow: "Шаг 4",
                title: "Проверьте сеть Wi‑Fi",
                text: isPad
                    ? "Muse и этот iPad должны видеть одну сеть. Мы подставим её имя автоматически, когда iPadOS это разрешает."
                    : "Muse и этот iPhone должны видеть одну сеть. Мы подставим её имя автоматически, когда iOS это разрешает."
            )

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "wifi").font(.title2).foregroundColor(MuseTheme.mint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(PalL10n.key(model.currentSSIDWasDetected ? "Сеть найдена" : "Имя сети"))
                            .font(.caption).foregroundColor(MuseTheme.secondary)
                        TextField("Например, Home Wi‑Fi", text: $model.networkName)
                            .font(.headline)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                    }
                    Button { model.refreshNetworkName() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Определить сеть ещё раз")
                }
                .padding(14)
                .background(MuseTheme.elevated)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                Label("Пароль вводить не нужно", systemImage: "checkmark.shield.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(MuseTheme.mint)
                Text("iOS не разрешает приложениям читать сохранённые пароли Wi‑Fi. Здесь это и не требуется: устройство уже подключено, Muse получает только имя текущей сети.")
                    .font(.footnote)
                    .foregroundColor(MuseTheme.secondary)
            }
            .museCard()

            Button("Сохранить и перейти к паре") {
                model.saveNetworkName()
                withAnimation { model.setupStep = 4 }
            }
            .buttonStyle(MusePrimaryButtonStyle())
            .disabled(model.networkName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(model.networkName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
        }
        .onAppear { model.refreshNetworkName() }
    }
}

private struct PairingStep: View {
    @ObservedObject var model: MuseAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StepIntro(
                eyebrow: "Шаг 5",
                title: "Соедините устройства",
                text: "Оставьте этот экран открытым и возьмите основной телефон с приложением Muse."
            )

            VStack(alignment: .leading, spacing: 18) {
                PairInstruction(number: "1", text: "На основном телефоне откройте Muse.")
                PairInstruction(number: "2", text: "Зайдите в Settings → Devices и включите Developer Mode.")
                PairInstruction(number: "3", text: PalL10n.format("pairing.choose_device_format", model.deviceName))
            }
            .museCard()

            HStack(spacing: 12) {
                PairPulse(active: model.pairingState.isBusy)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.pairingState.friendlyTitle).font(.headline)
                    Text(model.deviceName).font(.caption.monospaced()).foregroundColor(MuseTheme.secondary)
                }
                Spacer()
            }
            .museCard()

            if model.pairingState.isBusy {
                Button("Остановить поиск") { model.stopPairing() }
                    .buttonStyle(MuseSecondaryButtonStyle())
            } else {
                Button("Начать создание пары") { model.startPairing() }
                    .buttonStyle(MusePrimaryButtonStyle())
            }
        }
    }
}

private struct PairInstruction: View {
    let number: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Text(number)
                .font(.subheadline.weight(.bold))
                .frame(width: 30, height: 30)
                .background(MuseTheme.accent.opacity(0.20))
                .clipShape(Circle())
            Text(PalL10n.key(text)).font(.body)
            Spacer(minLength: 0)
        }
    }
}

private struct PairPulse: View {
    let active: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            if active {
                Circle()
                    .stroke(MuseTheme.mint.opacity(0.45), lineWidth: 2)
                    .scaleEffect(pulse ? 1.65 : 0.9)
                    .opacity(pulse ? 0 : 1)
            }
            Circle().fill(active ? MuseTheme.mint : MuseTheme.secondary)
        }
        .frame(width: 16, height: 16)
        .onAppear {
            withAnimation(.easeOut(duration: 1.25).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

/// A short note that a command acted on the device. Only for things a person can notice or would
/// want to know about; captions, cards and sensors already show themselves or do nothing visible.
struct MuseCommandToast: Equatable {
    let id = UUID()
    let text: String
    let succeeded: Bool

    private static let titles: [String: String] = [
        "torch.set": "Фонарик",
        "haptics.impact": "Вибрация",
        "shortcuts.run": "Быстрая команда",
        "display.set_brightness": "Яркость",
        "camera.capture": "Снимок камеры",
        "location.current": "Местоположение",
        "lan.request": "Запрос в локальную сеть",
        "display.set_avatar": "Аватар Muse"
    ]

    init?(command: String, succeeded: Bool) {
        guard let title = Self.titles[command] else { return nil }
        self.succeeded = succeeded
        text = PalL10n.format(
            succeeded ? "command.done_format" : "command.failed_format",
            PalL10n.text(title)
        )
    }
}

enum MuseDeviceSummary {
    static func text(batteryLevel: Float, batteryState: UIDevice.BatteryState, freeBytes: Int64?) -> String {
        var parts: [String] = []
        if batteryLevel >= 0 {
            let percent = Int((batteryLevel * 100).rounded())
            let charging = batteryState == .charging || batteryState == .full
            parts.append(PalL10n.format(charging ? "device.battery_charging_format" : "device.battery_format", percent))
        }
        if let freeBytes {
            let size = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
            parts.append(PalL10n.format("device.free_format", size))
        }
        return parts.joined(separator: " · ")
    }
}

struct MusePendingVoiceNote {
    let wav: Data
    let seconds: Int
}

private struct MuseMainTabs: View {
    @ObservedObject var model: MuseAppModel

    var body: some View {
        // Settings cover the chat instead of replacing it, so the draft, the scroll position and the
        // avatar stay as they were. A tab bar would cost the chat a whole row of an old phone's screen.
        ZStack {
            NavigationView { MuseChatView(model: model) }
                .navigationViewStyle(.stack)
            if model.isSettingsOpen {
                NavigationView { MuseSettingsView(model: model, diagnostics: model.environment.diagnostics) }
                    .navigationViewStyle(.stack)
                    .background(Color(UIColor.systemBackground))
                    .overlay(alignment: .topTrailing) {
                        Button { model.isSettingsOpen = false } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title)
                                .foregroundColor(MuseTheme.secondary)
                                .padding(16)
                        }
                        .accessibilityLabel(PalL10n.text("Закрыть"))
                    }
            }
        }
        .accentColor(MuseTheme.mint)
        .overlay(alignment: .top) {
            if let toast = model.commandToast {
                Label(toast.text, systemImage: toast.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(toast.succeeded ? MuseTheme.mint : Color.orange)
                    .clipShape(Capsule())
                    .padding(.top, 8)
                    .allowsHitTesting(false)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
    }
}

/// An image Muse put on the screen. A tap opens it across the whole screen.
private struct MuseDrawnImagePanel: View {
    let image: UIImage
    let dismiss: () -> Void
    @State private var isFullScreen = false

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: 280)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { isFullScreen = true }
            .overlay(alignment: .topTrailing) {
                Button(action: dismiss) {
                    // Dark behind white, so it shows on a light picture as well as a dark one.
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                        .padding(8)
                }
                .accessibilityLabel(PalL10n.text("Закрыть"))
            }
            .accessibilityElement(children: .contain)
            .fullScreenCover(isPresented: $isFullScreen) {
                ZStack {
                    Color.black.ignoresSafeArea()
                    Image(uiImage: image).resizable().scaledToFit()
                }
                .onTapGesture { isFullScreen = false }
            }
    }
}

/// Grows with the text up to a limit, then scrolls. iOS 15 has no multi-line TextField, so a hidden
/// copy of the text sets the height of a TextEditor. Return starts a new line; the arrow sends.
private struct MuseComposerField: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        Text(text.isEmpty ? " " : text + " ")
            .font(.body)
            .opacity(0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            .frame(minHeight: 46, maxHeight: 150, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
            .overlay(editor)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(PalL10n.key("Сообщение для Muse"))
                        .font(.body)
                        .foregroundColor(MuseTheme.secondary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
            .background(MuseTheme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
    }

    @ViewBuilder
    private var editor: some View {
        let field = TextEditor(text: $text)
            .font(.body)
            .focused(isFocused)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .accessibilityLabel(PalL10n.text("Сообщение для Muse"))
        if #available(iOS 16.0, *) {
            field.scrollContentBackground(.hidden)
        } else {
            field
        }
    }
}

private struct MuseChatView: View {
    private enum MediaPicker: String, Identifiable {
        case camera, library
        var id: String { rawValue }
    }

    @ObservedObject var model: MuseAppModel
    @State private var draft = ""
    @State private var mediaPicker: MediaPicker?
    @State private var importsDocument = false
    @FocusState private var isComposerFocused: Bool

    private static let bottomAnchor = "chat-bottom"

    private enum ScreenLayout {
        case phone, iPadUpright, iPadSideways

        /// A narrow iPad window has no more room than a phone.
        init(size: CGSize) {
            guard UIDevice.current.userInterfaceIdiom == .pad, size.width >= 600 else {
                self = .phone
                return
            }
            self = size.width > size.height ? .iPadSideways : .iPadUpright
        }
    }

    var body: some View {
        GeometryReader { geometry in
            switch ScreenLayout(size: geometry.size) {
            case .phone:
                chat(onPhone: true, phoneLandscape: geometry.size.width > geometry.size.height)
            case .iPadUpright:
                // A call takes the avatar's square only, so Muse's card, picture and caption
                // beside it stay in view.
                VStack(spacing: 0) {
                    MuseAvatarTopBand(model: model)
                    chat(onPhone: false)
                }
            case .iPadSideways:
                HStack(spacing: 0) {
                    MuseAvatarSidePanel(model: model)
                        .frame(width: geometry.size.width * 0.38)
                    Divider()
                    chat(onPhone: false)
                }
            }
        }
        // Where a call shows: beside the chat on an iPad, as a card over it on a phone.
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { model.callIsInline = ScreenLayout(size: proxy.size) != .phone }
                .onChange(of: proxy.size) { model.callIsInline = ScreenLayout(size: $0) != .phone }
        })
    }

    private func chat(onPhone: Bool, phoneLandscape: Bool = false) -> some View {
        let screenInChat = onPhone
        return VStack(spacing: 0) {
            if onPhone {
                MuseChatHeader(model: model, card: phoneLandscape ? model.card : nil)
            }

            if screenInChat, !phoneLandscape, let card = model.card {
                MuseWidgetCard(card: card, compact: true) { model.card = nil }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                    .background(MuseTheme.bar)
                    .overlay(alignment: .bottom) { Divider() }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if screenInChat, let image = model.drawnImage {
                MuseDrawnImagePanel(image: image) { model.drawnImage = nil }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(MuseTheme.bar)
                    .overlay(alignment: .bottom) { Divider() }
            }

            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 18) {
                    if screenInChat, !model.caption.isEmpty {
                        ChatBubble(text: model.caption, isMuse: true)
                    }

                    ForEach(model.visibleChatItems) { item in
                        ChatBubble(
                            text: item.hasRemoteImage && item.image == nil
                                ? [PalL10n.text("📷 Фото с другого устройства"), item.text].filter { !$0.isEmpty }.joined(separator: "\n")
                                : item.text,
                            isMuse: item.author != .user,
                            image: item.image
                        )
                    }

                    if model.isAwaitingReply {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(model.museActivity ?? PalL10n.text("Muse отвечает…"))
                                .font(.subheadline)
                                .foregroundColor(MuseTheme.secondary)
                            Spacer(minLength: 0)
                        }
                    }

                    Spacer(minLength: 70)
                        .id(Self.bottomAnchor)
                }
                .padding(20)
            }
            .chatKeyboardDismissBehavior(isFocused: $isComposerFocused)
            .onAppear {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
            .onChange(of: model.visibleChatItems.count) { _ in
                withAnimation { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            }
            .onChange(of: model.visibleChatItems.last?.text) { _ in
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
            }

            HStack(spacing: 10) {
                if model.isRecordingVoice {
                    HStack(spacing: 10) {
                        Image(systemName: "waveform").foregroundColor(.red)
                        Text(model.voiceRecordMode == .hold
                             ? PalL10n.format("recording.release_format", model.recordingSeconds)
                             : PalL10n.format("recording.progress_format", model.recordingSeconds))
                            .font(.subheadline.monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 15)
                    .frame(minHeight: 46)
                    .background(MuseTheme.elevated)
                    .clipShape(Capsule())
                } else if let note = model.pendingVoiceNote {
                    HStack(spacing: 10) {
                        Button { model.pendingVoiceNote = nil } label: {
                            Image(systemName: "trash")
                                .font(.headline)
                                .frame(width: 40, height: 44)
                        }
                        .accessibilityLabel(PalL10n.text("Удалить заметку"))
                        Text(PalL10n.format("voice.note_format", note.seconds))
                            .font(.subheadline.monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                    }
                    .padding(.trailing, 6)
                    .frame(minHeight: 46)
                    .background(MuseTheme.elevated)
                    .clipShape(Capsule())
                } else {
                    Menu {
                        Button {
                            if model.canUseCamera { mediaPicker = .camera }
                            else { model.explainCameraUnavailable() }
                        } label: {
                            Label("Сделать фото", systemImage: "camera")
                        }
                        Button {
                            mediaPicker = .library
                        } label: {
                            Label("Выбрать из галереи", systemImage: "photo")
                        }
                        Button { importsDocument = true } label: {
                            Label(PalL10n.text("Выбрать документ"), systemImage: "doc")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.headline)
                            .frame(width: 40, height: 44)
                    }
                    .disabled(!model.canSendToMuse)
                    .accessibilityLabel("Добавить фото")

                    MuseComposerField(text: $draft, isFocused: $isComposerFocused)
                        .disabled(model.runtimeState != .registered)
                }

                if (model.isSendingChat || model.isAwaitingReply) && !model.isRecordingVoice {
                    Button(action: model.stopCurrentReply) {
                        Image(systemName: "stop.fill")
                            .font(.subheadline.weight(.bold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(MuseTheme.accent)
                            .clipShape(Circle())
                    }
                    .accessibilityLabel(PalL10n.text("Остановить ответ"))
                } else if model.pendingVoiceNote != nil && !model.isRecordingVoice {
                    Button(action: model.sendPendingVoiceNote) {
                        Image(systemName: "arrow.up")
                            .font(.headline.weight(.bold))
                            .foregroundColor(model.canSendToMuse ? .white : MuseTheme.secondary)
                            .frame(width: 44, height: 44)
                            .background(model.canSendToMuse ? MuseTheme.accent : MuseTheme.elevated)
                            .clipShape(Circle())
                    }
                    .disabled(!model.canSendToMuse)
                    .accessibilityLabel(PalL10n.text("Отправить"))
                // Stays the same view across recording, or a held press would be cancelled.
                } else if hasDraft && !model.isRecordingVoice {
                    Button(action: sendDraft) {
                        Image(systemName: model.isSendingChat ? "ellipsis" : "arrow.up")
                            .font(.headline.weight(.bold))
                            .foregroundColor(canSend ? .white : MuseTheme.secondary)
                            .frame(width: 44, height: 44)
                            .background(canSend ? MuseTheme.accent : MuseTheme.elevated)
                            .clipShape(Circle())
                    }
                    .disabled(!canSend)
                    .accessibilityLabel("Отправить")
                } else {
                    HStack(spacing: 8) {
                        if model.liveVoiceCalls { VoiceCallButton(model: model) }
                        VoiceRecordButton(model: model)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(MuseTheme.bar)
            .overlay(alignment: .top) {
                if let voiceHint = model.voiceHint {
                    Text(voiceHint)
                        .font(.caption2)
                        .foregroundColor(MuseTheme.secondary)
                        .offset(y: -17)
                }
            }
        }
        .background(MuseTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .fullScreenCover(item: $mediaPicker) { picker in
            switch picker {
            case .camera:
                MuseCameraPicker(onFinish: finishPicking).ignoresSafeArea()
            case .library:
                MusePhotoPicker(onFinish: finishPicking).ignoresSafeArea()
            }
        }
        .fileImporter(isPresented: $importsDocument, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { model.sendDocument(url) }
        }
        .fullScreenCover(item: $model.fullScreenReply) { item in
            MuseFullScreenReply(item: item) { model.fullScreenReply = nil }
        }
    }

    private var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSend: Bool {
        model.canSendToMuse && hasDraft
    }

    private func finishPicking(_ image: UIImage?) {
        mediaPicker = nil
        guard let image else { return }
        let caption = draft
        draft = ""
        model.sendPhoto(image, caption: caption)
    }

    private func sendDraft() {
        guard canSend else { return }
        let message = draft
        draft = ""
        model.sendChat(message)
    }
}

/// Muse's face: its still picture, with the videos over it as soon as they are ready, or the app's mark.
private struct MuseAvatarFace: View {
    @ObservedObject var model: MuseAppModel
    let markSize: CGFloat

    var body: some View {
        ZStack {
            if let data = model.agentAvatar, let avatar = UIImage(data: data) {
                Image(uiImage: avatar).resizable().scaledToFit()
            } else if model.avatarFiles.isEmpty {
                MuseMark(size: markSize)
            }
            if !model.avatarFiles.isEmpty {
                MuseAvatarPlayer(files: model.avatarFiles, name: model.avatarAnimationName, version: model.avatarVersion)
            }
        }
    }
}

private struct MuseSettingsButton: View {
    @ObservedObject var model: MuseAppModel
    var showsTitle = true
    var fillsWidth = false

    var body: some View {
        Button { model.isSettingsOpen = true } label: {
            if showsTitle {
                Label(PalL10n.text("Настройки"), systemImage: "gearshape.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(MuseTheme.accent)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 44)
                    .background(MuseTheme.elevated)
                    .clipShape(Capsule())
            } else {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel(PalL10n.text("Настройки"))
            }
        }
        .frame(maxWidth: fillsWidth ? .infinity : nil)
    }
}

/// Shrinks ordinary long names, then scrolls names that still cannot fit at the minimum scale.
private struct MuseAdaptiveName: View {
    let name: String
    let pointSize: CGFloat
    let minimumScale: CGFloat
    var centered = false
    @State private var marqueeStartedAt = Date()

    private var uiFont: UIFont { .systemFont(ofSize: pointSize, weight: .semibold) }
    private var naturalWidth: CGFloat {
        ceil((name as NSString).size(withAttributes: [.font: uiFont]).width)
    }

    var body: some View {
        GeometryReader { proxy in
            if naturalWidth * minimumScale <= proxy.size.width {
                Text(name)
                    .font(.system(size: pointSize, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(minimumScale)
                    .allowsTightening(true)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: centered ? .center : .leading
                    )
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let travel = max(0, naturalWidth - proxy.size.width)
                    let pause: TimeInterval = 1.25
                    let movement = max(1, TimeInterval(travel / 24))
                    let cycle = pause * 2 + movement * 2
                    let elapsed = max(0, context.date.timeIntervalSince(marqueeStartedAt))
                        .truncatingRemainder(dividingBy: cycle)
                    let offset: CGFloat = {
                        if elapsed < pause { return 0 }
                        if elapsed < pause + movement {
                            return -travel * CGFloat((elapsed - pause) / movement)
                        }
                        if elapsed < pause * 2 + movement { return -travel }
                        return -travel * CGFloat(1 - (elapsed - pause * 2 - movement) / movement)
                    }()
                    Text(name)
                        .font(.system(size: pointSize, weight: .semibold))
                        .fixedSize(horizontal: true, vertical: false)
                        .offset(x: offset)
                        .frame(maxHeight: .infinity, alignment: .leading)
                }
            }
        }
        .frame(height: ceil(pointSize * 1.3))
        .clipped()
        .accessibilityLabel(name)
        .onChange(of: name) { _ in marqueeStartedAt = Date() }
    }
}

/// Portrait iPad keeps identity and controls in three compact rows beside the avatar.
private struct MusePortraitIdentityControls: View {
    @ObservedObject var model: MuseAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            MuseAdaptiveName(
                name: model.agentIdentity?.name.isEmpty == false ? model.agentIdentity!.name : "Muse",
                pointSize: 22,
                minimumScale: 0.5,
                centered: true
            )
            HStack(spacing: 0) {
                Circle()
                    .fill(model.runtimeState == .registered ? MuseTheme.mint : Color.orange)
                    .frame(width: 18, height: 18)
                    .frame(width: 40, height: 44)
                    .accessibilityLabel(model.chatStatus)
                MuseCompactChatTools(model: model)
            }
            MuseSettingsButton(model: model, fillsWidth: true)
        }
        .frame(width: 120, alignment: .leading)
    }
}

/// Two compact chat actions shared by every layout. Files belong to the composer's + menu.
private struct MuseCompactChatTools: View {
    @ObservedObject var model: MuseAppModel

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                Button { model.selectChat(nil) } label: {
                    Label(PalL10n.text("Основной чат"), systemImage: model.activeChatSessionID == nil ? "checkmark" : "bubble.left")
                }
                ForEach(model.chatSessions) { session in
                    Button { model.selectChat(session.id) } label: {
                        Label(session.title, systemImage: model.activeChatSessionID == session.id ? "checkmark" : "bubble.left.and.bubble.right")
                    }
                }
                Divider()
                Button(action: model.beginConnectingChat) {
                    Label(PalL10n.text("Подключить чат"), systemImage: "link")
                }
                Button(action: model.refreshChatSessions) {
                    Label(PalL10n.text("Обновить чаты"), systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshingChats)
                Button(action: model.createSideChat) {
                    Label(PalL10n.text("Новый чат"), systemImage: "plus.bubble")
                }
            } label: {
                Image(systemName: model.activeChatSessionID == nil ? "bubble.left" : "bubble.left.and.bubble.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(MuseTheme.accent)
                    .frame(width: 40, height: 44)
            }
            .disabled(model.isSendingChat || model.isAwaitingReply)
            .accessibilityLabel(model.activeChatTitle)

            Button { model.fullScreenReply = model.latestMuseReply } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(MuseTheme.accent)
                    .frame(width: 40, height: 44)
            }
            .disabled(model.latestMuseReply == nil)
            .accessibilityLabel(PalL10n.text("Ответ на весь экран"))
        }
    }
}

/// What Muse puts on the screen beside the chat: its card, its picture and its caption.
private struct MuseScreenItems: View {
    @ObservedObject var model: MuseAppModel
    var usesCompactCard = false
    var cardMaxWidth: CGFloat?
    var showsCard = true
    var fillsCompactCard = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if showsCard, let card = model.card {
                    MuseWidgetCard(
                        card: card,
                        compact: usesCompactCard,
                        fillsCompactSpace: fillsCompactCard
                    ) { model.card = nil }
                        .frame(
                            maxWidth: cardMaxWidth,
                            minHeight: fillsCompactCard ? 133 : nil,
                            maxHeight: fillsCompactCard ? 133 : nil,
                            alignment: .topLeading
                        )
                }
                if let image = model.drawnImage {
                    MuseDrawnImagePanel(image: image) { model.drawnImage = nil }
                }
                if !model.caption.isEmpty {
                    Text(model.caption)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// An iPad held sideways: the face at the top of a column, with room below for what Muse shows.
private struct MuseAvatarSidePanel: View {
    @ObservedObject var model: MuseAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // A call shows in the avatar's square, over the avatar, which keeps running underneath.
            MuseAvatarFace(model: model, markSize: 120)
                .overlay {
                    if model.isVoiceCallOpen {
                        MuseVoiceCallView(model: model, call: model.voiceCall, inline: true, inSquare: true)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .frame(maxWidth: .infinity)
            HStack(spacing: 0) {
                MuseAdaptiveName(
                    name: model.agentIdentity?.name.isEmpty == false ? model.agentIdentity!.name : "Muse",
                    pointSize: 22,
                    minimumScale: 0.5,
                    centered: true
                )
                .frame(maxWidth: .infinity, minHeight: 44)
                Circle()
                    .fill(model.runtimeState == .registered ? MuseTheme.mint : Color.orange)
                    .frame(width: 18, height: 18)
                    .frame(width: 40, height: 44)
                    .accessibilityLabel(model.chatStatus)
                MuseCompactChatTools(model: model)
                MuseSettingsButton(model: model, showsTitle: false)
            }
            MuseScreenItems(model: model)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(MuseTheme.bar)
    }
}

/// An iPad held upright: the face beside its name and what Muse shows, above the chat.
private struct MuseAvatarTopBand: View {
    @ObservedObject var model: MuseAppModel

    var body: some View {
        // During a call the square grows to hold the call's buttons over the picture.
        let side: CGFloat = model.isVoiceCallOpen ? 300 : 133
        HStack(alignment: .top, spacing: 16) {
            MuseAvatarFace(model: model, markSize: 72)
                .overlay {
                    if model.isVoiceCallOpen {
                        MuseVoiceCallView(model: model, call: model.voiceCall, inline: true, inSquare: true)
                    }
                }
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            MusePortraitIdentityControls(model: model)
            MuseScreenItems(model: model, usesCompactCard: true, fillsCompactCard: true)
                .frame(maxWidth: .infinity, minHeight: 133, maxHeight: side, alignment: .topLeading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: side + 32, alignment: .top)
        .background(MuseTheme.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct MuseChatHeader: View {
    @ObservedObject var model: MuseAppModel
    var card: MuseCard?

    private var status: String { model.chatStatus }

    /// Being connected needs no words. Anything else that is going on gets a small line under the name.
    private var showsStatusLine: Bool {
        status != PalL10n.text("Подключено")
    }

    var body: some View {
        HStack(spacing: 10) {
            MuseAvatarFace(model: model, markSize: 34)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            // The dot alone says connected, which leaves a small screen's width to the name.
            Circle()
                .fill(model.runtimeState == .registered ? MuseTheme.mint : Color.orange)
                .frame(width: 18, height: 18)
                .accessibilityLabel(model.chatStatus)
            // The status is offset rather than stacked, so the name stays put when it comes and goes.
            ZStack(alignment: .leading) {
                MuseAdaptiveName(
                    name: model.agentIdentity?.name.isEmpty == false ? model.agentIdentity!.name : "Muse",
                    pointSize: 17,
                    minimumScale: 0.55
                )
                if showsStatusLine {
                    Text(status)
                        .font(.caption2.weight(.medium))
                        .foregroundColor(MuseTheme.secondary)
                        .lineLimit(1)
                        .offset(y: 17)
                }
            }
            .frame(maxWidth: card == nil ? .infinity : 140, alignment: .leading)
            if let card {
                MuseWidgetCard(card: card, compact: true) { model.card = nil }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.isAwaitingReply {
                ProgressView()
                    .scaleEffect(0.8)
                    .accessibilityLabel("Muse отвечает…")
            }
            MuseCompactChatTools(model: model)
            MuseSettingsButton(model: model, showsTitle: false)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(MuseTheme.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct MuseFullScreenReply: View {
    let item: MuseChatItem
    let close: () -> Void
    @State private var textSize: CGFloat = 24

    var body: some View {
        NavigationView {
            ScrollView {
                Text(MuseChatMarkdown.attributed(item.text))
                    .font(.system(size: textSize, weight: .regular, design: .rounded))
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(MuseTheme.background.ignoresSafeArea())
            .navigationTitle(PalL10n.text("Ответ Muse"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    Button { textSize = max(17, textSize - 2) } label: {
                        Image(systemName: "textformat.size.smaller")
                    }
                    Button { textSize = min(44, textSize + 2) } label: {
                        Image(systemName: "textformat.size.larger")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(PalL10n.text("Закрыть"), action: close)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

private struct MuseDocumentsView: View {
    @ObservedObject var model: MuseAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var remoteName = ""
    @State private var importsDocument = false
    @State private var preview: MuseDocumentPreview?

    var body: some View {
        NavigationView {
            List {
                Section {
                    TextField(PalL10n.text("Имя файла, например notes.txt"), text: $remoteName)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    Button {
                        model.downloadDocument(remoteName)
                    } label: {
                        Label(PalL10n.text("Получить из Muse"), systemImage: "arrow.down.doc")
                    }
                    .disabled(model.isTransferringDocument || model.vmFilesAllowed == false
                              || remoteName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button { importsDocument = true } label: {
                        Label(PalL10n.text("Выбрать и отправить"), systemImage: "arrow.up.doc")
                    }
                    .disabled(model.isTransferringDocument || model.vmFilesAllowed == false)
                } header: {
                    Text(PalL10n.text("Обмен с Muse"))
                } footer: {
                    Text(PalL10n.text(model.vmFilesAllowed == false
                        ? "Сервер Muse не разрешает этому гаджету обмен файлами, поэтому кнопки выключены. Документ можно отправить в чат через +, а сохранённые файлы ниже остаются доступны."
                        : "Файлы до 1 МБ хранятся только в отдельной папке Pal Again. Сервер Muse может запретить файловый маршрут для вашего токена."))
                }

                if model.isTransferringDocument || model.documentStatus != nil {
                    Section {
                        HStack(spacing: 12) {
                            if model.isTransferringDocument { ProgressView() }
                            Text(model.documentStatus ?? "")
                                .foregroundColor(MuseTheme.secondary)
                        }
                    }
                }

                Section(PalL10n.text("На этом устройстве")) {
                    if model.documentFiles.isEmpty {
                        Text(PalL10n.text("Сохранённых документов пока нет."))
                            .foregroundColor(MuseTheme.secondary)
                    }
                    ForEach(model.documentFiles, id: \.self) { url in
                        Button { preview = MuseDocumentPreview(url: url) } label: {
                            Label(url.lastPathComponent, systemImage: "doc.text")
                        }
                        .swipeActions {
                            Button(role: .destructive) { model.removeLocalDocument(url) } label: {
                                Label(PalL10n.text("Удалить"), systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle(PalL10n.text("Документы"))
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(PalL10n.text("Готово")) { dismiss() }
                }
            }
            .fileImporter(isPresented: $importsDocument, allowedContentTypes: [.data]) { result in
                if case .success(let url) = result { model.uploadDocument(url) }
            }
            .sheet(item: $preview) { item in
                MuseQuickLook(url: item.url)
            }
        }
        .navigationViewStyle(.stack)
        .onAppear(perform: model.refreshDocuments)
    }
}

private struct MuseDocumentPreview: Identifiable {
    let id = UUID()
    let url: URL
}

private struct MuseQuickLook: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

private struct MuseWidgetCard: View {
    let card: MuseCard
    /// A single-line preview for narrow layouts; tapping it reveals the complete body above the chat.
    var compact = false
    var fillsCompactSpace = false
    let dismiss: () -> Void
    @State private var isExpanded = false

    private var iconName: String {
        card.kind == .timer ? "timer" : card.kind == .progress ? "chart.bar.fill" : "rectangle.on.rectangle.angled"
    }

    private func remaining(at date: Date) -> TimeInterval? {
        guard let duration = card.durationSeconds else { return nil }
        return max(0, duration - date.timeIntervalSince(card.shownAt))
    }

    private func timerText(_ remaining: TimeInterval) -> String {
        let seconds = Int(remaining.rounded(.up))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let tail = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, tail)
            : String(format: "%02d:%02d", minutes, tail)
    }

    private func compactRow(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    if !card.body.isEmpty { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: iconName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(MuseTheme.accent)
                        Text(card.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if !card.body.isEmpty {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2.weight(.bold))
                                .foregroundColor(MuseTheme.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(PalL10n.text(isExpanded ? "Свернуть карточку" : "Раскрыть карточку"))
                Spacer(minLength: 4)
                if let value = remaining(at: date) {
                    Text(timerText(value))
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .foregroundColor(value == 0 ? .red : MuseTheme.accent)
                } else if let progress = card.progress {
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundColor(MuseTheme.accent)
                }
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(PalL10n.text("Закрыть карточку"))
            }
            if let duration = card.durationSeconds, let value = remaining(at: date) {
                ProgressView(value: duration - value, total: duration).tint(MuseTheme.accent)
            } else if let progress = card.progress {
                ProgressView(value: progress).tint(MuseTheme.accent)
            }
            if fillsCompactSpace, !card.body.isEmpty {
                Button { isExpanded = true } label: {
                    Text(card.body)
                        .font(.footnote)
                        .foregroundColor(MuseTheme.secondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(PalL10n.text("Раскрыть карточку"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(
            maxWidth: .infinity,
            maxHeight: fillsCompactSpace ? .infinity : nil,
            alignment: .topLeading
        )
        .background(MuseTheme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .popover(isPresented: $isExpanded, arrowEdge: .top) {
            expandedCard(at: date)
        }
    }

    private func expandedCard(at date: Date) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: iconName)
                        .font(.headline)
                        .foregroundColor(MuseTheme.accent)
                    Text(card.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button { isExpanded = false } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .frame(width: 30, height: 30)
                            .background(MuseTheme.elevated)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(PalL10n.text("Свернуть карточку"))
                }
                if let value = remaining(at: date) {
                    Text(timerText(value))
                        .font(.system(.title2, design: .monospaced).weight(.semibold))
                        .foregroundColor(value == 0 ? .red : MuseTheme.accent)
                }
                if let duration = card.durationSeconds, let value = remaining(at: date) {
                    ProgressView(value: duration - value, total: duration).tint(MuseTheme.accent)
                } else if let progress = card.progress {
                    ProgressView(value: progress).tint(MuseTheme.accent)
                }
                if !card.body.isEmpty {
                    Text(card.body)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(18)
        }
        .frame(idealWidth: 420, maxWidth: 520, idealHeight: 320, maxHeight: 520)
        .background(MuseTheme.background)
    }

    var body: some View {
        TimelineView(.periodic(from: card.shownAt, by: card.kind == .timer ? 1 : 60)) { context in
            if compact {
                compactRow(at: context.date)
            } else {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: iconName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(MuseTheme.accent)
                    .frame(width: 32, height: 32)
                    .background(MuseTheme.accent.opacity(0.13))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(card.title)
                            .font(.headline)
                        Spacer(minLength: 8)
                        if let value = remaining(at: context.date) {
                            Text(timerText(value))
                                .font(.system(.headline, design: .monospaced).weight(.semibold))
                                .foregroundColor(value == 0 ? .red : MuseTheme.accent)
                        } else if let progress = card.progress {
                            Text("\(Int((progress * 100).rounded()))%")
                                .font(.headline.monospacedDigit())
                                .foregroundColor(MuseTheme.accent)
                        }
                    }
                    if let duration = card.durationSeconds,
                       let value = remaining(at: context.date) {
                        ProgressView(value: duration - value, total: duration)
                            .tint(MuseTheme.accent)
                    } else if let progress = card.progress {
                        ProgressView(value: progress)
                            .tint(MuseTheme.accent)
                    }
                    if !card.body.isEmpty {
                        Text(card.body)
                            .font(.subheadline)
                            .foregroundColor(MuseTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 30, height: 30)
                        .background(MuseTheme.elevated)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Закрыть карточку")
            }
            .museCard()
            .accessibilityElement(children: .contain)
            }
        }
    }
}

private struct VoiceCallButton: View {
    @ObservedObject var model: MuseAppModel

    var body: some View {
        Button(action: model.openVoiceCall) {
            Image(systemName: "phone.fill")
                .font(.headline)
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(MuseTheme.accent)
                .clipShape(Circle())
                .opacity(model.isCallReady && !model.isRecordingVoice ? 1 : 0.4)
        }
        .disabled(!model.isCallReady || model.isRecordingVoice)
        .accessibilityLabel(PalL10n.text("Поговорить с Muse голосом"))
    }
}

private struct MuseVoiceCallView: View {
    @ObservedObject var model: MuseAppModel
    @ObservedObject var call: MuseVoiceCall
    /// On an iPad the call takes the avatar's own place beside the chat, on its background.
    var inline = false
    /// In the wide band of an upright iPad, status and buttons go beside the picture.
    var beside = false
    /// On an iPad the call fills the avatar's square, with its status and buttons over the picture.
    var inSquare = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// An iPhone on its side: too little height for anything under the picture but one line.
    private var phoneSideways: Bool { !inline && verticalSizeClass == .compact }

    /// One line under the picture on a phone held sideways: Muse's latest words while it
    /// speaks, kept at their end so the line moves on as it talks, otherwise the status.
    private var runningLine: String {
        call.phase == .speaking && !call.reply.isEmpty ? call.reply : status
    }

    /// Muse's video comes upright with empty white above and below its avatar; every window
    /// keeps the middle part of the height, so the avatar is larger.
    private static let videoCrop: CGFloat = 0.6
    @Environment(\.colorScheme) private var colorScheme

    private var status: String {
        switch call.phase {
        case .idle, .connecting: return PalL10n.text("Соединяю с Muse…")
        case .listening:
            if call.isMuted { return PalL10n.text("Микрофон выключен") }
            if call.missedSentence { return PalL10n.text("Muse не расслышал, скажите ещё раз") }
            return call.isMuseReady ? PalL10n.text("Говорите, Muse слушает") : PalL10n.text("Muse готовится, сейчас поздоровается…")
        case .thinking: return PalL10n.text("Muse думает…")
        case .speaking: return PalL10n.text("Muse говорит")
        case .ended(let reason): return reason
        }
    }

    /// A call has two looks, as in Muse's own voice mode: at rest, and moving its lips while its
    /// voice is heard. The chat's listening, thinking and gesturing movements are not used here.
    private var avatarAnimation: String {
        if call.phase.isActive, call.isVoiceAudible,
           model.avatarFiles[MuseAppModel.callSpeakingAnimation] != nil {
            return MuseAppModel.callSpeakingAnimation
        }
        return MuseAvatarState.idle.rawValue
    }

    private var statusIcon: String {
        switch call.phase {
        case .speaking: return "speaker.wave.3.fill"
        case .thinking: return "ellipsis"
        case .ended: return "phone.down.fill"
        default: return call.isMuted ? "mic.slash.fill" : "waveform"
        }
    }

    var body: some View {
        Group {
            if inSquare {
                ZStack(alignment: .bottom) {
                    squareFace
                    VStack(spacing: 8) {
                        Label(status, systemImage: statusIcon)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if !call.reply.isEmpty {
                            Text(call.reply)
                                .font(.footnote)
                                .lineLimit(2)
                                .truncationMode(.head)
                        }
                        HStack(spacing: 14) { controlButtons }
                    }
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .padding(.top, 18)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity)
                    .background(
                        LinearGradient(colors: [.clear, Color.black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                    )
                }
            } else if phoneSideways {
                HStack(spacing: 12) {
                    VStack(spacing: 6) {
                        face.frame(maxWidth: .infinity, maxHeight: .infinity)
                        Text(runningLine)
                            .font(.subheadline)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity)
                    }
                    VStack(spacing: 12) { controlButtons }
                }
                .padding(8)
            } else if beside {
                // A wide band (an iPad held upright): the picture as tall as the band, with the
                // status and buttons beside it, so neither leaves the other empty space.
                HStack(spacing: 16) {
                    face.frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack(spacing: 14) {
                        info
                        extras
                        controls
                    }
                    .frame(width: 300)
                }
                .padding(12)
            } else {
                // A tall panel (an iPad lying sideways) or a phone's card: the picture takes all
                // the height the compact status and buttons below it leave.
                VStack(spacing: 12) {
                    face.frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
                    info
                    extras
                    controls
                }
                .padding(12)
                .padding(.bottom, inline ? 0 : 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Group {
            if call.hasVideo { Color.white } else if inline { MuseTheme.bar } else { MuseTheme.background }
        }.ignoresSafeArea())
        // Text and buttons stay readable on the white of Muse's video in dark mode too.
        .environment(\.colorScheme, call.hasVideo ? .light : colorScheme)
        // A swipe must not leave the microphone open behind a closed card.
        .interactiveDismissDisabled(call.phase.isActive)
    }

    /// The whole square: Muse's video filling it, or the avatar moving with the call's voice.
    @ViewBuilder private var squareFace: some View {
        if call.hasVideo {
            Color.white.overlay(MuseVideoSurface(renderer: call.video, fills: true))
        } else {
            ZStack {
                MuseTheme.elevated
                if let data = model.agentAvatar, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                }
                if !model.avatarFiles.isEmpty {
                    MuseAvatarPlayer(files: model.avatarFiles, name: avatarAnimation, version: model.avatarVersion)
                }
            }
        }
    }

    @ViewBuilder private var face: some View {
        if call.hasVideo {
            // Muse's own video in a media call: its avatar, talking in sync with its voice.
            // No frame or corners: on the call's white background Muse's video, which comes
            // on white, blends in instead of sitting in it as a white card.
            MuseVideoSurface(renderer: call.video, fills: true)
                .aspectRatio(call.videoAspect / Self.videoCrop, contentMode: .fit)
                .clipped()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack {
                if let data = model.agentAvatar, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if model.avatarFiles.isEmpty {
                    Image(systemName: "person.wave.2.fill").resizable().scaledToFit().padding(36)
                        .foregroundColor(MuseTheme.accent)
                }
                // Muse's own avatar moves with the call, the way the SDK animates its avatar
                // locally: nothing extra comes from the server for it.
                if !model.avatarFiles.isEmpty {
                    MuseAvatarPlayer(files: model.avatarFiles, name: avatarAnimation, version: model.avatarVersion)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 280, maxHeight: 280)
            .background(MuseTheme.elevated)
            .clipShape(Circle())
            .overlay(Circle().stroke(call.phase == .speaking ? MuseTheme.accent : MuseTheme.stroke, lineWidth: 4))
        }
    }

    private var info: some View {
        VStack(spacing: 8) {
            Label(status, systemImage: statusIcon)
                .font(.headline)
                .multilineTextAlignment(.center)
            if !call.heard.isEmpty {
                Text(PalL10n.format("voice.call_heard_format", call.heard))
                    .font(.subheadline)
                    .foregroundColor(MuseTheme.secondary)
                    .lineLimit(inline ? 2 : nil)
            }
            if !call.reply.isEmpty {
                Text(call.reply)
                    .font(.body)
                    .lineLimit(inline ? 3 : nil)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, inline ? 0 : 24)
    }

    @ViewBuilder private var extras: some View {
        // Voice Isolation needs an A12 chip or later; iOS lets only the person pick it.
        if call.phase.isActive, MuseVoiceCall.canPickMicrophoneMode {
            Button(action: MuseVoiceCall.showMicrophoneModes) {
                Label(PalL10n.text("Режим микрофона"), systemImage: "waveform.badge.mic")
                    .font(.footnote)
            }
        }
        if !call.isVideoCall, model.avatarFiles[MuseAppModel.callSpeakingAnimation] == nil, !model.callAvatarRequested {
            Button(action: model.requestCallAvatar) {
                Label(PalL10n.text("Попросить Muse анимацию губ для звонков"), systemImage: "mouth")
                    .font(.footnote)
            }
            .disabled(!model.canSendToMuse)
        }
    }

    private var controls: some View {
        HStack(spacing: inline ? 16 : 28) { controlButtons }
    }

    @ViewBuilder private var controlButtons: some View {
        Group {
            if call.phase.isActive {
                roundButton(call.isMuted ? "mic.slash.fill" : "mic.fill",
                            label: call.isMuted ? "Включить микрофон" : "Выключить микрофон",
                            color: MuseTheme.elevated) { call.isMuted.toggle() }
                if call.phase == .speaking {
                    roundButton("hand.raised.fill", label: "Перебить", color: MuseTheme.elevated) { call.interrupt() }
                }
                roundButton("phone.down.fill", label: "Завершить разговор", color: .red) { model.closeVoiceCall() }
            } else {
                roundButton("phone.fill", label: "Позвонить снова", color: MuseTheme.accent) { model.startCallInOpenChat() }
                roundButton("xmark", label: "Закрыть", color: MuseTheme.elevated) { model.closeVoiceCall() }
            }
        }
    }

    private func roundButton(_ icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color == MuseTheme.elevated ? .primary : .white)
                .frame(width: inSquare ? 46 : (inline || phoneSideways ? 56 : 68),
                       height: inSquare ? 46 : (inline || phoneSideways ? 56 : 68))
                .background(color)
                .clipShape(Circle())
        }
        .accessibilityLabel(PalL10n.text(label))
    }
}

private struct MuseVideoSurface: UIViewRepresentable {
    let renderer: MuseVideoRenderer
    /// Fill the window and crop what does not fit, instead of fitting the whole picture.
    var fills = false

    func makeUIView(context: Context) -> MuseVideoLayerView {
        let view = MuseVideoLayerView()
        // The space beside the picture shows whatever is behind it, not black bars.
        view.backgroundColor = .clear
        view.clipsToBounds = true
        view.renderer = renderer
        renderer.layer.videoGravity = fills ? .resizeAspectFill : .resizeAspect
        return view
    }

    func updateUIView(_ view: MuseVideoLayerView, context: Context) {
        if view.renderer !== renderer { view.renderer = renderer }
        renderer.layer.videoGravity = fills ? .resizeAspectFill : .resizeAspect
    }
}

private struct VoiceRecordButton: View {
    @ObservedObject var model: MuseAppModel
    @State private var isHeld = false

    private var face: some View {
        Image(systemName: model.isRecordingVoice && model.voiceRecordMode == .tap ? "stop.fill" : "mic.fill")
            .font(.headline)
            .frame(width: 44, height: 44)
            .background(model.isRecordingVoice ? Color.red : MuseTheme.elevated)
            .clipShape(Circle())
            .opacity(model.canSendToMuse || model.isRecordingVoice ? 1 : 0.4)
    }

    var body: some View {
        switch model.voiceRecordMode {
        case .tap:
            Button(action: model.toggleVoiceRecording) { face }
                .disabled(!model.canSendToMuse && !model.isRecordingVoice)
                .accessibilityLabel(model.isRecordingVoice ? "Остановить и отправить" : "Записать голосовую заметку")
        case .hold:
            face
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !isHeld else { return }
                            isHeld = true
                            model.beginHeldVoiceRecording()
                        }
                        .onEnded { _ in
                            isHeld = false
                            model.endHeldVoiceRecording()
                        }
                )
                .onDisappear {
                    isHeld = false
                    model.endHeldVoiceRecording()
                }
                .accessibilityLabel("Удерживайте, чтобы записать голосовую заметку")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { model.toggleVoiceRecording() }
        }
    }
}

private struct ChatBubble: View {
    let text: String
    let isMuse: Bool
    var image: UIImage?

    private var rendered: MuseWidgetMarkup {
        isMuse
            ? MuseWidgetMarkup.parse(text.trimmingCharacters(in: .whitespacesAndNewlines))
            : MuseWidgetMarkup(text: text, widgetIDs: [])
    }

    var body: some View {
        Group {
            if !rendered.text.isEmpty || image != nil {
                HStack {
                    if !isMuse { Spacer(minLength: 45) }
                    VStack(alignment: .leading, spacing: 8) {
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 220, maxHeight: 260)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        if !rendered.text.isEmpty {
                            Group {
                                if isMuse {
                                    Text(MuseChatMarkdown.attributed(rendered.text))
                                } else {
                                    Text(rendered.text)
                                }
                            }
                            .font(.body)
                            .textSelection(.enabled)
                        }
                    }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(isMuse ? MuseTheme.elevated : MuseTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    if isMuse { Spacer(minLength: 45) }
                }
            }
        }
    }
}

/// The studio's mark, the same in every Cognitive Labs app: the mark is twice the type size.
private struct CognitiveLabsLockup: View {
    private let size: CGFloat = 15

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: "COGNITIVE").kerning(0.5)
            Image("cognitiveMark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size * 2, height: size * 2)
            Text(verbatim: "LABS").kerning(0.5)
        }
        .font(.custom("HelveticaNeue-Medium", size: size))
        .foregroundColor(.primary)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: "Cognitive Labs"))
    }
}

private struct MuseSettingsView: View {
    @ObservedObject var model: MuseAppModel
    @ObservedObject var diagnostics: MuseDiagnostics
    @State private var showForgetConfirmation = false
    @State private var showResetConfirmation = false
    @State private var showClearHistoryConfirmation = false
    @State private var showAbout = false
    @State private var showHelp = false
    @State private var showReport = false
    @State private var showShortcuts = false
    @State private var showLocalDevices = false

    private var reportText: String {
        MuseProblemReport.text(
            appVersion: MuseAppVersion.display,
            system: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            model: MuseHapticRoute.machineIdentifier,
            connection: model.runtimeState.shortTitle,
            log: model.diagnostics
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CognitiveLabsLockup()
                    .frame(maxWidth: .infinity)
                StepIntro(
                    eyebrow: "Устройство",
                    title: "Настройки",
                    text: "Всё важное собрано здесь. Технические подробности спрятаны внизу."
                )

                VStack(spacing: 15) {
                    SettingsLine(icon: "checkmark.seal.fill", title: "Пара Muse", value: PalL10n.text("Создана"), tint: MuseTheme.mint)
                    SettingsLine(
                        icon: "network",
                        title: "Muse VM",
                        value: model.runtimeState.shortTitle,
                        tint: model.runtimeState == .registered ? MuseTheme.mint : .yellow
                    )
                    SettingsLine(icon: "iphone", title: "Имя устройства", value: model.deviceName, tint: MuseTheme.blue)
                    SettingsLine(icon: "wifi", title: "Сеть", value: CurrentWiFi.preferredSSID() ?? PalL10n.text("Не указана"), tint: MuseTheme.blue)
                    if let account = model.pairedAccount {
                        SettingsLine(icon: "person.crop.circle", title: "Аккаунт", value: account, tint: MuseTheme.accent)
                    }
                }
                .museCard()

                VStack(alignment: .leading, spacing: 0) {
                    SettingsSectionLabel(title: "MUSE НА ЭТОМ УСТРОЙСТВЕ")
                        .padding(.bottom, 2)
                    CapabilitySettingsRow(
                        icon: "message.fill",
                        title: "Чат и ответы",
                        detail: model.runtimeState == .registered ? PalL10n.text("Подключены и готовы") : model.runtimeState.shortTitle,
                        tint: model.runtimeState == .registered ? MuseTheme.mint : .orange
                    )
                    Divider().overlay(MuseTheme.stroke)
                    Button(action: model.requestAvatar) {
                        CapabilitySettingsRow(
                            icon: "person.crop.circle.fill",
                            title: "Имя и аватар Muse",
                            detail: avatarDetail,
                            tint: model.agentAvatar == nil ? MuseTheme.blue : MuseTheme.mint
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canSendToMuse)
                    if model.agentAvatar != nil {
                        Button("Убрать аватар", action: model.clearAvatar)
                            .font(.subheadline)
                            .padding(.bottom, 8)
                    }
                    Divider().overlay(MuseTheme.stroke)
                    CapabilitySettingsRow(
                        icon: "battery.75",
                        title: "Это устройство",
                        detail: model.batterySummary,
                        tint: MuseTheme.mint
                    )
                    Divider().overlay(MuseTheme.stroke)
                    CapabilitySettingsRow(
                        icon: "speaker.wave.2.fill",
                        title: "Экран и звук",
                        detail: PalL10n.text("Подписи, речь, яркость и вибрация"),
                        tint: MuseTheme.blue
                    )
                    Divider().overlay(MuseTheme.stroke)
                    CapabilitySettingsRow(
                        icon: "camera.metering.center.weighted",
                        title: "Камера и датчики",
                        detail: sensorAccessSummary,
                        tint: sensorAccessCount == 3 ? MuseTheme.mint : .orange
                    )
                    Divider().overlay(MuseTheme.stroke)
                    DisclosureGroup(isExpanded: $showShortcuts) {
                        VStack(alignment: .leading, spacing: 8) {
                            if model.approvedShortcuts.isEmpty {
                                Text(PalL10n.text("Постоянных разрешений пока нет."))
                                    .font(.caption)
                                    .foregroundColor(MuseTheme.secondary)
                            }
                            ForEach(model.approvedShortcuts, id: \.self) { name in
                                GrantRow(icon: "square.stack.3d.up.fill", title: name) {
                                    model.revokeShortcut(name)
                                }
                            }
                        }
                        .padding(.leading, 38)
                        .padding(.bottom, 10)
                    } label: {
                        CapabilitySettingsRow(
                            icon: "square.stack.3d.up.fill",
                            title: "Быстрые команды",
                            detail: model.approvedShortcuts.isEmpty
                                ? PalL10n.text("Спросят подтверждение перед запуском")
                                : PalL10n.format("settings.approved_count_format", model.approvedShortcuts.count),
                            tint: MuseTheme.blue
                        )
                    }
                    .tint(MuseTheme.accent)
                    Divider().overlay(MuseTheme.stroke)
                    DisclosureGroup(isExpanded: $showLocalDevices) {
                        VStack(alignment: .leading, spacing: 8) {
                            if model.approvedDevices.isEmpty {
                                Text(PalL10n.text("Постоянных разрешений пока нет."))
                                    .font(.caption)
                                    .foregroundColor(MuseTheme.secondary)
                            }
                            ForEach(model.approvedDevices) { device in
                                GrantRow(icon: "network", title: device.id) { model.revokeDevice(device) }
                            }
                        }
                        .padding(.leading, 38)
                        .padding(.bottom, 10)
                    } label: {
                        CapabilitySettingsRow(
                            icon: "network",
                            title: "Устройства в локальной сети",
                            detail: localNetworkSummary,
                            tint: (model.permissionStates[.localNetwork] ?? .notDetermined) == .granted ? MuseTheme.mint : .orange
                        )
                    }
                    .tint(MuseTheme.accent)
                }
                .museCard()

                VStack(alignment: .leading, spacing: 13) {
                    SettingsSectionLabel(title: "РАЗРЕШЕНИЯ")
                    ForEach(AppPermission.allCases, id: \.self) { permission in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: permission.icon).frame(width: 24).foregroundColor(MuseTheme.blue)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(permission.localizedTitle).font(.subheadline.weight(.semibold))
                                Text(permission.explanation)
                                    .font(.caption)
                                    .foregroundColor(MuseTheme.secondary)
                            }
                            Spacer()
                            Text((model.permissionStates[permission] ?? .notDetermined).shortTitle)
                                .font(.caption.weight(.semibold))
                                .foregroundColor((model.permissionStates[permission] ?? .notDetermined) == .granted ? MuseTheme.mint : MuseTheme.secondary)
                        }
                    }
                    Button("Открыть системные настройки") {
                        model.openSystemSettings()
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 4)
                }
                .museCard()

                VStack(alignment: .leading, spacing: 14) {
                    SettingsSectionLabel(title: "ПОВЕДЕНИЕ И СИНХРОНИЗАЦИЯ")
                    SettingsSliderRow(
                        title: "Яркость экрана",
                        detail: "Muse тоже может её менять, здесь видно текущее значение",
                        value: Binding(get: { model.screenBrightness }, set: model.setScreenBrightness),
                        range: 0...1
                    )
                    Divider().overlay(MuseTheme.stroke)
                    SettingsSliderRow(
                        title: "Громкость речи",
                        detail: "Для того, что Muse произносит вслух. Кнопки громкости устройства тоже действуют",
                        value: Binding(get: { model.speechVolume }, set: model.setSpeechVolume),
                        range: 0...100
                    )
                    Divider().overlay(MuseTheme.stroke)
                    SettingsChoiceRow(
                        title: "Запись голоса",
                        detail: PalL10n.text(model.voiceRecordMode == .hold
                            ? "Удерживайте кнопку микрофона и говорите. Отпустите, чтобы отправить."
                            : "Нажмите на микрофон, чтобы начать запись. Нажмите ещё раз, чтобы отправить."),
                        selection: $model.voiceRecordMode,
                        isDisabled: model.isRecordingVoice
                    )
                    SettingsToggleRow(
                        title: "Подтверждать отправку",
                        detail: PalL10n.text("Записанная заметка уйдёт только после кнопки «Отправить». Её можно и удалить"),
                        isOn: $model.confirmsVoiceNotes
                    )
                    SettingsToggleRow(
                        title: "Живой разговор с Muse (бета)",
                        detail: PalL10n.text("Кнопка с телефоном рядом с микрофоном: вы говорите, Muse отвечает своим голосом. Голосовые заметки остаются как были. При переключении приложение переподключается к Muse"),
                        isOn: $model.liveVoiceCalls
                    )
                    if model.liveVoiceCalls {
                        SettingsToggleRow(
                            title: "Видео с аватаром Muse (бета)",
                            detail: PalL10n.text("В разговоре Muse показывает своё лицо и говорит губами в такт, как в приложении Muse. Это видеозвонок через медиасервер Meta, около 1 Мбит/с. Выключите, чтобы говорить только голосом"),
                            isOn: $model.videoCallsWithAvatar
                        )
                        SettingsToggleRow(
                            title: "Muse здоровается первым",
                            detail: PalL10n.text("В начале разговора Muse сам здоровается, и слышно, что связь установлена. Работает и с видео, и без него"),
                            isOn: $model.museGreetsFirst
                        )
                    }
                    SettingsToggleRow(
                        title: "Короткие ответы на голос",
                        detail: PalL10n.text("Muse отвечает на голосовые заметки коротко и простыми фразами, как на гаджетах с микрофоном. Выключите, чтобы получать полные ответы, как раньше"),
                        isOn: $model.shortVoiceReplies
                    )
                    Divider().overlay(MuseTheme.stroke)
                    SettingsToggleRow(
                        title: "История чата по Wi-Fi",
                        detail: model.peerSyncStatus,
                        isOn: $model.isPeerSyncEnabled
                    )
                    Divider().overlay(MuseTheme.stroke)
                    SettingsToggleRow(
                        title: "История чата в iCloud",
                        detail: model.cloudSyncStatus,
                        isOn: $model.isCloudSyncEnabled
                    )
                    Divider().overlay(MuseTheme.stroke)
                    SettingsToggleRow(
                        title: "Не гасить экран",
                        detail: PalL10n.text("Камера, микрофон и датчики отвечают Muse, только пока приложение на экране."),
                        isOn: $model.keepScreenAwake
                    )
                }
                .museCard()

                Button { showHelp = true } label: {
                    SettingsNavigationRow(
                        icon: "questionmark.circle.fill",
                        title: "Помощь и руководство",
                        detail: "Подключение, чаты, сообщения, голос и разрешения"
                    )
                }
                .buttonStyle(.plain)
                .museCard()

                Button { showAbout = true } label: {
                    SettingsNavigationRow(
                        icon: "info.circle.fill",
                        title: "О приложении",
                        detail: "Репозиторий, тестирование, участие, конфиденциальность и лицензии"
                    )
                }
                .buttonStyle(.plain)
                .museCard()

                DisclosureGroup("Диагностика") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.diagnostics.isEmpty ? PalL10n.text("Новых событий нет") : model.diagnostics.joined(separator: "\n"))
                            .font(.caption2.monospaced())
                            .foregroundColor(MuseTheme.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.top, 12)
                }
                .museCard()

                VStack(alignment: .leading, spacing: 12) {
                    SettingsSectionLabel(title: "ОТЧЁТЫ О СБОЯХ")
                    SettingsToggleRow(
                        title: "Отправлять диагностику",
                        detail: PalL10n.text("Только отчёты MetricKit о сбоях и зависаниях и безопасные этапы работы. Без текста чата, токенов, файлов, фото и аудио."),
                        isOn: Binding(
                            get: { diagnostics.sharingEnabled },
                            set: diagnostics.setSharingEnabled
                        )
                    )
                    if diagnostics.pendingReportCount > 0 {
                        Text(PalL10n.format("diagnostics.pending_format", diagnostics.pendingReportCount))
                            .font(.caption)
                            .foregroundColor(MuseTheme.secondary)
                    }
                    if let status = diagnostics.lastUploadStatus {
                        Text(PalL10n.format(
                            "diagnostics.last_status_format",
                            status == "sent" ? PalL10n.text("Отправлено")
                                : (status == "offline" ? PalL10n.text("Нет сети") : status)
                        ))
                            .font(.caption)
                            .foregroundColor(MuseTheme.secondary)
                    }
                    Button("Отправить диагностику сейчас") { diagnostics.sendCurrentSnapshot() }
                        .buttonStyle(MuseSecondaryButtonStyle())
                        .disabled(!diagnostics.sharingEnabled)
                }
                .museCard()

                VStack(alignment: .leading, spacing: 6) {
                    Button("Отправить отчёт") { showReport = true }
                        .buttonStyle(MuseSecondaryButtonStyle())
                    Text("Письмо на \(MuseProblemReport.address) с журналом подключения, версией и моделью устройства. Вы увидите его до отправки. Чат и токены в него не входят.")
                        .font(.caption)
                        .foregroundColor(MuseTheme.secondary)
                }
                .sheet(isPresented: $showReport) { MuseReportSheet(body_: reportText) }

                Button("Очистить историю чата", role: .destructive) { showClearHistoryConfirmation = true }
                    .buttonStyle(MuseSecondaryButtonStyle(destructive: true))
                    .disabled(model.chatItems.isEmpty)

                Button("Повторить пошаговую настройку") { model.restartGuide() }
                    .buttonStyle(MuseSecondaryButtonStyle())

                Button("Заменить SDK Token") { model.beginTokenReplacement() }
                    .buttonStyle(MuseSecondaryButtonStyle())

                Button("Удалить пару с Muse", role: .destructive) { showForgetConfirmation = true }
                    .buttonStyle(MuseSecondaryButtonStyle(destructive: true))

                Button("Сбросить приложение", role: .destructive) { showResetConfirmation = true }
                    .buttonStyle(MuseSecondaryButtonStyle(destructive: true))
            }
            .padding(20)
        }
        .background(MuseTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .onAppear { model.refreshPermissions() }
        .sheet(isPresented: $showAbout) {
            PalAboutView()
        }
        .sheet(isPresented: $showHelp) {
            PalHelpView()
        }
        // An alert rather than a confirmation dialog: on iPad the dialog becomes a popover
        // anchored to this whole screen and may never appear.
        .alert(
            "Очистить историю чата?",
            isPresented: $showClearHistoryConfirmation
        ) {
            Button("Очистить", role: .destructive) { model.clearChatHistory() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(PalL10n.key(model.isCloudSyncEnabled || model.isPeerSyncEnabled
                 ? "Сообщения удалятся с этого устройства и с других ваших гаджетов, с которыми включена синхронизация. Переписка в самом Muse останется."
                 : "Сообщения и фото удалятся с этого устройства. Переписка в самом Muse останется."))
        }
        // An alert rather than a confirmation dialog: on iPad the dialog becomes a popover
        // anchored to this whole screen and may never appear.
        .alert(
            "Удалить сохранённую пару?",
            isPresented: $showForgetConfirmation
        ) {
            Button("Удалить пару", role: .destructive) { model.forgetPairing() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("После этого удалите это устройство и в приложении Muse: Settings → Devices. Иначе создать пару заново не получится. SDK Token останется в Связке ключей.")
        }
        .alert(
            "Сбросить приложение?",
            isPresented: $showResetConfirmation
        ) {
            Button("Сбросить", role: .destructive) { model.resetApp() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("С этого устройства удалятся SDK Token, пара с Muse, чат, аватар, файлы, выданные Muse доступы и все настройки. Приложение откроется как после первой установки. Разрешения iOS приложение снять не может: их меняют в Настройках iOS. После сброса удалите это устройство и в приложении Muse: Settings → Devices.")
        }
    }

    private var sensorAccessCount: Int {
        [AppPermission.camera, .location, .motion].filter {
            (model.permissionStates[$0] ?? .notDetermined) == .granted
        }.count
    }

    private var avatarDetail: String {
        if model.avatarsPreparing > 0 { return PalL10n.format("avatar.preparing_format", model.avatarsPreparing) }
        if model.avatarRequested { return PalL10n.text("Запрос отправлен, ответ придёт в чат") }
        return PalL10n.text(model.agentAvatar == nil ? "Нажмите, и Muse поставит имя и аватар" : "Нажмите, чтобы обновить")
    }

    private var sensorAccessSummary: String {
        PalL10n.format("settings.sensor_access_format", sensorAccessCount)
    }

    private var localNetworkSummary: String {
        guard (model.permissionStates[.localNetwork] ?? .notDetermined) == .granted else {
            return PalL10n.text("Нет доступа к локальной сети")
        }
        return model.approvedDevices.isEmpty
            ? PalL10n.text("Доступ есть, новые устройства потребуют подтверждения")
            : PalL10n.format("settings.approved_count_format", model.approvedDevices.count)
    }
}

private struct PalHelpView: View {
    @Environment(\.dismiss) private var dismiss

    private let topics: [(icon: String, title: String, text: String)] = [
        (
            "link.badge.plus",
            "Подключение к Muse",
            "При первом запуске сохраните свой SDK Token, выдайте запрошенные разрешения и добавьте найденный гаджет в приложении Muse. После этого Pal Again подключается автоматически."
        ),
        (
            "bubble.left.and.bubble.right.fill",
            "Основной и дополнительные чаты",
            "«Новый чат» создаёт отдельный чат после первого сообщения. «Подключить чат» принимает ссылку или ID уже существующего чата Muse. «Обновить чаты» перечитывает доступную гаджету историю. Названия подключённых чатов хранятся на этом устройстве, потому что Muse не передаёт гаджету их аккаунтные названия."
        ),
        (
            "plus.circle.fill",
            "Сообщения и вложения",
            "Пишите в нижнем поле. Через плюс можно сделать или выбрать фотографию и отправить небольшой документ. Кнопка справа записывает голосовую заметку или отправляет подготовленное сообщение."
        ),
        (
            "mic.fill",
            "Голосовые заметки",
            "В настройках можно выбрать запись нажатием или удержанием. Если включено подтверждение, после записи на месте микрофона появляется круглая кнопка отправки."
        ),
        (
            "phone.fill",
            "Живой разговор с Muse",
            "Включите «Живой разговор с Muse (бета)» в настройках, и рядом с микрофоном появится кнопка с телефоном. Говорите свободно, Muse отвечает своим голосом. Пока Muse говорит, микрофон закрыт: чтобы остановить ответ, нажмите «Перебить». С настройкой «Видео с аватаром Muse (бета)» разговор идёт как видеозвонок."
        ),
        (
            "arrow.counterclockwise",
            "Сброс и новая пара",
            "«Удалить пару с Muse» убирает только пару, «Сбросить приложение» возвращает гаджет к первому запуску. После любого из них удалите это устройство в приложении Muse (Settings → Devices), иначе создать пару заново не получится. Случайно открытую пошаговую настройку закрывает кнопка «Вернуться»."
        ),
        (
            "hand.raised.fill",
            "Разрешения и команды",
            "Камера, микрофон, геопозиция, Bluetooth и локальная сеть используются только для соответствующих функций. Опасные быстрые команды и новые устройства локальной сети требуют вашего подтверждения."
        ),
        (
            "wrench.and.screwdriver.fill",
            "Если что-то не работает",
            "Сначала проверьте зелёный статус подключения. Затем откройте системные настройки разрешений или нажмите «Обновить чаты». Технический отчёт можно подготовить внизу настроек — сообщения и токены в него не входят."
        )
    ]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    StepIntro(
                        eyebrow: "PAL AGAIN",
                        title: "Помощь и руководство",
                        text: "Короткие ответы о функциях, которые не обязаны быть очевидными с первого запуска."
                    )
                    ForEach(Array(topics.enumerated()), id: \.offset) { _, topic in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: topic.icon)
                                .font(.title3)
                                .foregroundColor(MuseTheme.accent)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(PalL10n.key(topic.title)).font(.headline)
                                Text(PalL10n.key(topic.text))
                                    .font(.subheadline)
                                    .foregroundColor(MuseTheme.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .museCard()
                    }
                }
                .padding(20)
            }
            .background(MuseTheme.background.ignoresSafeArea())
            .navigationTitle(PalL10n.text("Помощь"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(PalL10n.text("Готово")) { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

private struct SettingsChoiceRow: View {
    let title: String
    let detail: String
    @Binding var selection: MuseVoiceRecordMode
    let isDisabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(PalL10n.key(title))
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 12)
                Menu {
                    Picker("Запись голоса", selection: $selection) {
                        ForEach(MuseVoiceRecordMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(selection.title)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(MuseTheme.accent)
                }
                .disabled(isDisabled)
            }
            Text(detail)
                .font(.caption)
                .foregroundColor(MuseTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SettingsNavigationRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(MuseTheme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(PalL10n.key(title))
                    .font(.subheadline.weight(.semibold))
                Text(PalL10n.key(detail))
                    .font(.caption)
                    .foregroundColor(MuseTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundColor(MuseTheme.secondary)
        }
        .contentShape(Rectangle())
    }
}

private struct PalAboutView: View {
    @Environment(\.dismiss) private var dismiss

    private let repositoryURL = URL(string: "https://github.com/exrector/muse-gadget-ios")!
    private let testingURL = URL(string: "https://github.com/exrector/muse-gadget-ios/blob/main/Docs/TESTING.md")!
    private let contributingURL = URL(string: "https://github.com/exrector/muse-gadget-ios/blob/main/CONTRIBUTING.md")!
    private let privacyURL = URL(string: "https://github.com/exrector/muse-gadget-ios/blob/main/PRIVACY.md")!

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(spacing: 10) {
                        MuseMark(size: 70)
                        Text("Pal Again")
                            .font(.title2.bold())
                        Text("Make Old Devices Smart Again.")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(MuseTheme.secondary)
                        Text(appVersion)
                            .font(.caption.monospacedDigit())
                            .foregroundColor(MuseTheme.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .museCard()

                    VStack(alignment: .leading, spacing: 12) {
                        SettingsSectionLabel(title: "ПРОЕКТ")
                        AboutExternalRow(icon: "chevron.left.forwardslash.chevron.right", title: "Исходный код", url: repositoryURL)
                        Divider().overlay(MuseTheme.stroke)
                        AboutExternalRow(icon: "testtube.2", title: "Присоединиться к тестированию", url: testingURL)
                        Divider().overlay(MuseTheme.stroke)
                        AboutExternalRow(icon: "person.2.fill", title: "Помочь проекту", url: contributingURL)
                    }
                    .museCard()

                    VStack(alignment: .leading, spacing: 10) {
                        SettingsSectionLabel(title: "КОНФИДЕНЦИАЛЬНОСТЬ")
                        Text("SDK Token и данные пары хранятся в системной Связке ключей. Сообщения, фото, голос и запрошенные данные устройства передаются Muse только для выбранных вами функций. В Pal Again нет рекламы, поведенческой аналитики и отслеживания; отчёты о сбоях отправляются только с вашего согласия.")
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        AboutExternalRow(icon: "hand.raised.fill", title: "Политика конфиденциальности", url: privacyURL)
                    }
                    .museCard()

                    VStack(alignment: .leading, spacing: 12) {
                        SettingsSectionLabel(title: "ЛИЦЕНЗИИ И ПРАВОВЫЕ СВЕДЕНИЯ")
                        Text("Pal Again — независимый проект сообщества с открытым исходным кодом. Muse и связанные товарные знаки принадлежат их правообладателям.")
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Каждый пользователь вводит собственный SDK Token. Pal Again не содержит общего токена и не продаёт доступ к Muse.")
                            .font(.caption)
                            .foregroundColor(MuseTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Pal Again стоит $1. Эта сумма оплачивает готовую сборку, подпись и доставку через App Store и помогает поддерживать независимую разработку, тестирование на старых устройствах и Apple Developer Program стоимостью около $100 в год. Доступ к Muse не продаётся: каждый пользователь использует собственный SDK Token.")
                            .font(.caption)
                            .foregroundColor(MuseTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Divider().overlay(MuseTheme.stroke)
                        NavigationLink {
                            BundledLegalDocumentView(title: "Apache License 2.0", resourceName: "LICENSE")
                        } label: {
                            AboutNavigationRow(title: "Apache License 2.0")
                        }
                        Divider().overlay(MuseTheme.stroke)
                        NavigationLink {
                            BundledLegalDocumentView(title: "NOTICE", resourceName: "NOTICE")
                        } label: {
                            AboutNavigationRow(title: "NOTICE")
                        }
                    }
                    .museCard()
                }
                .padding(20)
            }
            .background(MuseTheme.background.ignoresSafeArea())
            .navigationTitle("О приложении")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return PalL10n.format(MuseAppVersion.isTestFlight ? "about.version_beta_format" : "about.version_format", version, build)
    }
}

private struct AboutExternalRow: View {
    let icon: String
    let title: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundColor(MuseTheme.accent)
                    .frame(width: 26)
                Text(PalL10n.key(title))
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.bold))
                    .foregroundColor(MuseTheme.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct AboutNavigationRow: View {
    let title: String

    var body: some View {
        HStack {
            Text(PalL10n.key(title))
                .font(.subheadline.weight(.semibold))
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundColor(MuseTheme.secondary)
        }
        .contentShape(Rectangle())
    }
}

private struct BundledLegalDocumentView: View {
    let title: String
    let resourceName: String

    var body: some View {
        ScrollView {
            Text(documentText)
                .font(.caption.monospaced())
                .foregroundColor(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .background(MuseTheme.background.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var documentText: String {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: nil),
              let text = try? String(contentsOf: url) else {
            return PalL10n.text("Документ не найден в сборке.")
        }
        return text
    }
}

private struct CapabilitySettingsRow: View {
    let icon: String
    let title: String
    let detail: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(tint)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(PalL10n.key(title)).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundColor(MuseTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
    }
}

private struct GrantRow: View {
    let icon: String
    let title: String
    let revoke: () -> Void

    var body: some View {
        HStack {
            Image(systemName: icon).frame(width: 24).foregroundColor(MuseTheme.blue)
            Text(title).font(.subheadline).lineLimit(2)
            Spacer()
            Button("Убрать", role: .destructive, action: revoke)
                .font(.caption.weight(.semibold))
        }
    }
}

private struct SettingsSliderRow: View {
    let title: String
    let detail: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(PalL10n.key(title)).font(.subheadline.weight(.semibold))
            Slider(value: $value, in: range)
                .tint(MuseTheme.accent)
                .accessibilityLabel(PalL10n.text(title))
            Text(PalL10n.key(detail))
                .font(.caption)
                .foregroundColor(MuseTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $isOn) {
                Text(PalL10n.key(title)).font(.subheadline.weight(.semibold))
            }
            .tint(MuseTheme.accent)
            Text(detail)
                .font(.caption)
                .foregroundColor(MuseTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SettingsLine: View {
    let icon: String
    let title: String
    let value: String
    let tint: Color
    @Environment(\.sizeCategory) private var sizeCategory

    var body: some View {
        HStack(alignment: sizeCategory.isAccessibilityCategory ? .top : .center, spacing: 12) {
            Image(systemName: icon).foregroundColor(tint).frame(width: 24)
            if sizeCategory.isAccessibilityCategory {
                VStack(alignment: .leading, spacing: 3) {
                    Text(PalL10n.key(title)).font(.subheadline)
                    Text(value).font(.subheadline.weight(.semibold))
                }
            } else {
                Text(PalL10n.key(title)).font(.subheadline)
                Spacer()
                Text(value).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
        }
    }
}

private extension AppPermission {
    var localizedTitle: String {
        switch self {
        case .bluetooth: return "Bluetooth"
        case .localNetwork: return PalL10n.text("Локальная сеть")
        case .camera: return PalL10n.text("Камера")
        case .microphone: return PalL10n.text("Микрофон")
        case .location: return PalL10n.text("Геопозиция")
        case .motion: return PalL10n.text("Датчики движения")
        }
    }

    var explanation: String {
        switch self {
        case .bluetooth: return PalL10n.text("Найти устройство во время создания пары")
        case .localNetwork: return PalL10n.text("Обнаруживать сервисы Muse рядом")
        case .camera: return PalL10n.text("Отправлять фото и снимать для Muse, пока приложение открыто")
        case .microphone: return PalL10n.text("Записывать заметки и голос для Muse, пока приложение открыто")
        case .location: return PalL10n.text("Определить Wi‑Fi и выполнять команды геопозиции")
        case .motion: return PalL10n.text("Использовать акселерометр и движение")
        }
    }

    var icon: String {
        switch self {
        case .bluetooth: return "bolt.horizontal.circle.fill"
        case .localNetwork: return "network"
        case .camera: return "camera.fill"
        case .microphone: return "mic.fill"
        case .location: return "location.fill"
        case .motion: return "gyroscope"
        }
    }
}

private extension PermissionState {
    var shortTitle: String {
        switch self {
        case .notDetermined: return PalL10n.text("Не запрошено")
        case .granted: return PalL10n.text("Разрешено")
        case .denied: return PalL10n.text("Запрещено")
        case .restricted: return PalL10n.text("Ограничено")
        case .unavailable: return PalL10n.text("Недоступно")
        }
    }

    var buttonTitle: String {
        switch self {
        case .notDetermined: return PalL10n.text("Разрешить")
        case .granted: return PalL10n.text("Готово")
        case .denied: return PalL10n.text("Настройки")
        case .restricted: return PalL10n.text("Недоступно")
        case .unavailable: return PalL10n.text("Повторить")
        }
    }
}

private extension PairingCoordinator.State {
    var isBusy: Bool {
        switch self {
        case .bluetooth, .advertising, .connected, .encrypted, .provisioning: return true
        default: return false
        }
    }

    var friendlyTitle: String {
        switch self {
        case .idle: return PalL10n.text("Готово к созданию пары")
        case .needsSDKToken: return PalL10n.text("Сначала добавьте SDK Token")
        case .bluetooth: return PalL10n.text("Включаем Bluetooth…")
        case .advertising: return PalL10n.text("Устройство видно в Muse")
        case .connected: return PalL10n.text("Muse подключается…")
        case .encrypted: return PalL10n.text("Защищаем соединение…")
        case .provisioning: return PalL10n.text("Сохраняем пару…")
        case .paired: return PalL10n.text("Пара создана")
        case .failed(let message): return PalL10n.format("pairing.failed_format", message)
        }
    }
}

private extension MuseRuntimeState {
    var shortTitle: String {
        switch self {
        case .idle: return PalL10n.text("Ожидание")
        case .fetchingVM: return PalL10n.text("Поиск VM")
        case .connecting: return PalL10n.text("Соединение")
        case .handshaking: return PalL10n.text("Шифрование")
        case .registering: return PalL10n.text("Регистрация")
        case .registered: return PalL10n.text("Подключена")
        case .failed: return PalL10n.text("Повторяем")
        }
    }

    var title: String {
        switch self {
        case .registered: return PalL10n.text("Канал Muse VM подключён")
        case .failed: return PalL10n.text("Канал временно недоступен")
        case .idle: return PalL10n.text("Ожидаем данные пары")
        default: return PalL10n.text("Подключаем Muse VM…")
        }
    }

    var detail: String {
        switch self {
        case .registered:
            return PalL10n.text("Noise XX и link.register подтверждены сервером Muse.")
        case .failed(let message):
            return PalL10n.format("runtime.failed_detail_format", message)
        case .idle:
            return PalL10n.text("После создания пары приложение подключится автоматически.")
        case .fetchingVM:
            return PalL10n.text("Получаем виртуальную машину аккаунта.")
        case .connecting:
            return PalL10n.text("Открываем защищённый WebSocket.")
        case .handshaking:
            return PalL10n.text("Выполняем Noise XX с AES-GCM.")
        case .registering:
            return PalL10n.text("Отправляем link.register и ждём подтверждения.")
        }
    }
}
