import SwiftUI
import UIKit

struct MuseChatItem: Identifiable {
    enum Author: Equatable { case user, muse, system }

    let id: UUID
    let author: Author
    var text: String {
        didSet { updatedAt = Date() }
    }
    var image: UIImage?
    var museMessageID: String?
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
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        hasRemoteImage: Bool = false
    ) {
        self.id = id
        self.author = author
        self.text = text
        self.image = image
        self.museMessageID = museMessageID
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.hasRemoteImage = hasRemoteImage
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
    @Published var card: MuseCard?
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
    private var voiceHintReset: DispatchWorkItem?
    private var waitingForSettingsReturn = false
    private let chatTimeline = MuseChatTimeline()
    private var replyItemIDs: [String: UUID] = [:]
    private var replyTimeout: DispatchWorkItem?
    private var recordingTimer: Timer?

    init(environment: AppEnvironment) {
        self.environment = environment
        let history = environment.chatStore.load()
        chatItems = history
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
    }

    var deviceName: String { environment.identity.bluetoothName }

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
            if state == .paired {
                withAnimation(.easeInOut) { self.isPaired = true }
                self.applyIdleTimerPolicy()
            }
        }
        environment.pairing.onLog = { [weak self] message in
            guard let self else { return }
            self.diagnostics.append(message)
            if self.diagnostics.count > 80 { self.diagnostics.removeFirst() }
        }
        environment.runtime.onStateChange = { [weak self] state in
            self?.runtimeState = state
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
        environment.runtime.onChatRecord = { [weak self] record in
            guard let self else { return }
            self.apply(self.chatTimeline.feed(record))
        }
        applyIdleTimerPolicy()
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
        if permissionStates[permission] == .denied {
            openSystemSettings()
            return
        }
        environment.permissions.request(permission) { [weak self] state in
            self?.permissionStates[permission] = state
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
        environment.pairing.start()
    }

    func stopPairing() {
        environment.pairing.stop()
    }

    func sendChat(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, canSendToMuse else { return }
        chatItems.append(MuseChatItem(author: .user, text: clean))
        beginRequest()
        environment.runtime.sendChat(clean) { [weak self] result in
            self?.finishRequest(result)
        }
    }

    func sendPhoto(_ image: UIImage, caption: String) {
        guard canSendToMuse else { return }
        let clean = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        beginRequest()
        DispatchQueue.global(qos: .userInitiated).async {
            let original = image.jpegData(compressionQuality: 0.95)
            let jpeg = original.flatMap { MuseJPEG.bounded($0, maxBytes: 1_048_576, maxDimension: 1_600) }
            let preview = jpeg
                .flatMap { MuseJPEG.bounded($0, maxBytes: 128 * 1024, maxDimension: 640) }
                .flatMap(UIImage.init(data:))
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let jpeg else {
                    self.finishRequest(.failure(MuseRuntimeError.payloadTooLarge))
                    return
                }
                self.chatItems.append(MuseChatItem(author: .user, text: clean, image: preview))
                self.environment.runtime.sendImage(jpeg: jpeg, message: clean) { [weak self] result in
                    self?.finishRequest(result)
                }
            }
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
        chatItems.append(MuseChatItem(author: .user, text: PalL10n.format("voice.note_format", max(durationMS / 1_000, 1))))
        beginRequest()
        environment.runtime.sendVoiceNote(wav: wav) { [weak self] result in
            self?.finishRequest(result)
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

    private func beginRequest() {
        chatTimeline.expectRequest()
        isSendingChat = true
        isAwaitingReply = true
        museActivity = nil
    }

    private func finishRequest(_ result: Result<[String: Any], Error>) {
        isSendingChat = false
        switch result {
        case .success(let response):
            apply(chatTimeline.acknowledge(response))
            if isAwaitingReply { scheduleReplyTimeout() }
        case .failure(let error):
            chatTimeline.abandonRequest()
            finishWaitingForReply()
            chatItems.append(MuseChatItem(author: .system, text: Self.describe(error)))
        }
    }

    private func scheduleReplyTimeout() {
        replyTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finishWaitingForReply() }
        replyTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: work)
    }

    private func finishWaitingForReply() {
        replyTimeout?.cancel()
        replyTimeout = nil
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
                    let item = MuseChatItem(author: .muse, text: text, museMessageID: messageID)
                    replyItemIDs[messageID] = item.id
                    chatItems.append(item)
                }
                if done { finishWaitingForReply() }
                else if !text.isEmpty { museActivity = nil }
            case .activity(let text):
                museActivity = text?.isEmpty == false ? text : nil
            case .finished:
                finishWaitingForReply()
            }
        }
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
}

struct MuseAppView: View {
    @StateObject private var model: MuseAppModel

    init(environment: AppEnvironment) {
        _model = StateObject(wrappedValue: MuseAppModel(environment: environment))
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
    }
}

private enum MuseTheme {
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
        .background(.ultraThinMaterial)
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
        .shadow(color: MuseTheme.accent.opacity(0.35), radius: 14, y: 5)
        .accessibilityHidden(true)
    }
}

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
                title: "Старый iPhone — новый гаджет для Muse",
                text: "Пять простых шагов. Мы спрячем Bluetooth, ключи и протоколы под капот и будем объяснять только то, что нужно нажать."
            )

            VStack(spacing: 16) {
                FeatureLine(icon: "message.fill", title: "Muse как чат", text: "Сообщения и ответы — на главном экране.")
                FeatureLine(icon: "square.grid.2x2.fill", title: "Возможности iPhone", text: "Экран, голос, камера, геопозиция и датчики.")
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
                text: "Muse и этот iPhone должны видеть одну сеть. Мы подставим её имя автоматически, когда iOS это разрешает."
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

private struct MuseMainTabs: View {
    @ObservedObject var model: MuseAppModel

    var body: some View {
        TabView {
            NavigationView { MuseChatView(model: model) }
                .navigationViewStyle(.stack)
                .tabItem { Label("Muse", systemImage: "message.fill") }

            NavigationView { CapabilitiesView(model: model) }
                .navigationViewStyle(.stack)
                .tabItem { Label("Возможности", systemImage: "square.grid.2x2.fill") }

            NavigationView { MuseSettingsView(model: model) }
                .navigationViewStyle(.stack)
                .tabItem { Label("Настройки", systemImage: "gearshape.fill") }
        }
        .accentColor(MuseTheme.mint)
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

    private static let bottomAnchor = "chat-bottom"

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 18) {
                    HStack {
                        MuseMark(size: 46)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Muse").font(.title2.bold())
                            Label {
                                Text(PalL10n.key(model.runtimeState == .registered ? "Подключено к Muse VM" : "Пара создана"))
                            } icon: {
                                Image(systemName: model.runtimeState == .registered ? "network" : "checkmark.circle.fill")
                            }
                                .font(.caption.weight(.semibold)).foregroundColor(MuseTheme.mint)
                        }
                        Spacer()
                    }
                    .padding(.top, 8)

                    StatusBanner(state: model.runtimeState)

                    ChatBubble(
                        text: PalL10n.text(model.runtimeState == .registered
                            ? "Гаджет зарегистрирован в Muse. Сетевой канал активен и готов принимать команды."
                            : "Пара создана и сохранена. Подключаем защищённый канал Muse VM…"),
                        isMuse: true
                    )

                    if let card = model.card {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(card.title).font(.headline)
                                if !card.body.isEmpty {
                                    Text(card.body)
                                        .font(.subheadline)
                                        .foregroundColor(MuseTheme.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            Button { model.card = nil } label: {
                                Image(systemName: "xmark").font(.caption.weight(.bold))
                            }
                            .accessibilityLabel("Закрыть карточку")
                        }
                        .museCard()
                    }

                    if !model.caption.isEmpty {
                        ChatBubble(text: model.caption, isMuse: true)
                    }

                    ForEach(model.chatItems) { item in
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
            .onAppear {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
            .onChange(of: model.chatItems.count) { _ in
                withAnimation { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            }
            .onChange(of: model.chatItems.last?.text) { _ in
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
                    } label: {
                        Image(systemName: "plus")
                            .font(.headline)
                            .frame(width: 40, height: 44)
                    }
                    .disabled(!model.canSendToMuse)
                    .accessibilityLabel("Добавить фото")

                    TextField("Сообщение для Muse", text: $draft)
                        .padding(.horizontal, 15)
                        .frame(minHeight: 46)
                        .background(MuseTheme.elevated)
                        .clipShape(Capsule())
                        .disabled(model.runtimeState != .registered)
                        .submitLabel(.send)
                        .onSubmit(sendDraft)
                }

                // Stays the same view across recording, or a held press would be cancelled.
                if hasDraft && !model.isRecordingVoice {
                    Button(action: sendDraft) {
                        Image(systemName: model.isSendingChat ? "ellipsis" : "arrow.up")
                            .font(.headline)
                            .frame(width: 44, height: 44)
                            .background(canSend ? MuseTheme.accent : MuseTheme.elevated)
                            .clipShape(Circle())
                    }
                    .disabled(!canSend)
                    .accessibilityLabel("Отправить")
                } else {
                    VoiceRecordButton(model: model)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) {
                Text(model.voiceHint ?? PalL10n.text(model.runtimeState == .registered ? "Защищённый чат Muse активен" : "Ждём регистрации в Muse VM"))
                    .font(.caption2)
                    .foregroundColor(MuseTheme.secondary)
                    .offset(y: -17)
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

private struct StatusBanner: View {
    let state: MuseRuntimeState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: state == .registered ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                .foregroundColor(state == .registered ? MuseTheme.mint : .yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.title).font(.subheadline.weight(.semibold))
                Text(state.detail)
                    .font(.caption).foregroundColor(MuseTheme.secondary)
            }
            Spacer(minLength: 0)
        }
        .museCard()
    }
}

private struct ChatBubble: View {
    let text: String
    let isMuse: Bool
    var image: UIImage?

    var body: some View {
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
                if !text.isEmpty {
                    Text(text).font(.body).textSelection(.enabled)
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

private struct CapabilitiesView: View {
    @ObservedObject var model: MuseAppModel

    private let capabilities: [(String, String, String, String)] = [
        ("display", "Экран", "Показывает подписи и карточки Muse", "Готово, ждёт проверки с Muse"),
        ("waveform", "Голос и звук", "Озвучивание и голосовые заметки", "Готово, ждёт проверки с Muse"),
        ("camera.fill", "Камера", "Фото только после явного разрешения", "Готово, ждёт проверки с Muse"),
        ("location.fill", "Геопозиция", "Положение только во время работы", "Готово, ждёт проверки с Muse"),
        ("gyroscope", "Датчики движения", "Снимок движения по команде", "Готово, ждёт проверки с Muse"),
        ("flashlight.on.fill", "Фонарик и яркость", "Фонарик и яркость экрана по команде", "Готово, ждёт проверки с Muse"),
        ("square.text.square", "Карточка на экране", "Заголовок и текст поверх чата", "Готово, ждёт проверки с Muse"),
        ("square.stack.3d.up.fill", "Быстрые команды", "Запуск только тех, что вы разрешили", "Готово, ждёт проверки с Muse"),
        ("network", "Локальная сеть", "Поиск устройств и HTTP только к разрешённым", "Готово, ждёт проверки с Muse")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                StepIntro(
                    eyebrow: "iOS Gadget",
                    title: "Возможности",
                    text: "Команды Linux, Raspberry Pi и ESP32 здесь заменяются безопасными возможностями iOS. Каждая работает только в рамках разрешений Apple."
                )

                ForEach(capabilities, id: \.1) { item in
                    HStack(alignment: .top, spacing: 15) {
                        Image(systemName: item.0)
                            .font(.title3)
                            .foregroundColor(MuseTheme.mint)
                            .frame(width: 42, height: 42)
                            .background(MuseTheme.mint.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(PalL10n.key(item.1)).font(.headline)
                            Text(PalL10n.key(item.2)).font(.subheadline).foregroundColor(MuseTheme.secondary)
                            Text(PalL10n.key(item.3))
                                .font(.caption2.weight(.bold))
                                .foregroundColor(MuseTheme.blue)
                                .padding(.top, 3)
                        }
                        Spacer(minLength: 0)
                    }
                    .museCard()
                }
            }
            .padding(20)
        }
        .background(MuseTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
    }
}

private struct MuseSettingsView: View {
    @ObservedObject var model: MuseAppModel
    @State private var showForgetConfirmation = false
    @State private var showClearHistoryConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
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

                VStack(alignment: .leading, spacing: 13) {
                    SettingsSectionLabel(title: "РАЗРЕШЕНИЯ")
                    ForEach(AppPermission.allCases, id: \.self) { permission in
                        HStack {
                            Image(systemName: permission.icon).frame(width: 24).foregroundColor(MuseTheme.blue)
                            Text(permission.localizedTitle).font(.subheadline)
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

                VStack(alignment: .leading, spacing: 13) {
                    SettingsSectionLabel(title: "РАЗРЕШЕНО ДЛЯ MUSE")
                    if model.approvedShortcuts.isEmpty && model.approvedDevices.isEmpty {
                        Text("Пока ничего. Когда Muse попросит запустить Быструю команду или обратиться к устройству в сети, приложение спросит вас.")
                            .font(.caption)
                            .foregroundColor(MuseTheme.secondary)
                    }
                    ForEach(model.approvedShortcuts, id: \.self) { name in
                        GrantRow(icon: "square.stack.3d.up.fill", title: name) { model.revokeShortcut(name) }
                    }
                    ForEach(model.approvedDevices) { device in
                        GrantRow(icon: "network", title: device.id) { model.revokeDevice(device) }
                    }
                }
                .museCard()

                VStack(alignment: .leading, spacing: 8) {
                    SettingsSectionLabel(title: "ЗАПИСЬ ГОЛОСА")
                    Picker("Запись голоса", selection: $model.voiceRecordMode) {
                        ForEach(MuseVoiceRecordMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isRecordingVoice)
                    Text(PalL10n.text(model.voiceRecordMode == .hold
                         ? "Удерживайте кнопку микрофона и говорите. Отпустите, чтобы отправить."
                         : "Нажмите на микрофон, чтобы начать запись. Нажмите ещё раз, чтобы отправить."))
                        .font(.caption)
                        .foregroundColor(MuseTheme.secondary)
                }
                .museCard()

                VStack(alignment: .leading, spacing: 14) {
                    SettingsSectionLabel(title: "СИНХРОНИЗАЦИЯ И РАБОТА")
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

                Button("Очистить историю чата", role: .destructive) { showClearHistoryConfirmation = true }
                    .buttonStyle(MuseSecondaryButtonStyle(destructive: true))
                    .disabled(model.chatItems.isEmpty)

                Button("Повторить пошаговую настройку") { model.restartGuide() }
                    .buttonStyle(MuseSecondaryButtonStyle())

                Button("Заменить SDK Token") { model.beginTokenReplacement() }
                    .buttonStyle(MuseSecondaryButtonStyle())

                Button("Удалить пару с Muse", role: .destructive) { showForgetConfirmation = true }
                    .buttonStyle(MuseSecondaryButtonStyle(destructive: true))
            }
            .padding(20)
        }
        .background(MuseTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .onAppear { model.refreshPermissions() }
        .confirmationDialog(
            "Очистить историю чата?",
            isPresented: $showClearHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("Очистить", role: .destructive) { model.clearChatHistory() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(PalL10n.key(model.isCloudSyncEnabled || model.isPeerSyncEnabled
                 ? "Сообщения удалятся с этого устройства и с других ваших гаджетов, с которыми включена синхронизация. Переписка в самом Muse останется."
                 : "Сообщения и фото удалятся с этого устройства. Переписка в самом Muse останется."))
        }
        .confirmationDialog(
            "Удалить сохранённую пару?",
            isPresented: $showForgetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Удалить пару", role: .destructive) { model.forgetPairing() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Потребуется снова добавить устройство в приложении Muse. SDK Token останется в Связке ключей.")
        }
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
        case .speechRecognition: return PalL10n.text("Распознавание речи")
        case .location: return PalL10n.text("Геопозиция")
        case .motion: return PalL10n.text("Датчики движения")
        }
    }

    var explanation: String {
        switch self {
        case .bluetooth: return PalL10n.text("Найти устройство во время создания пары")
        case .localNetwork: return PalL10n.text("Обнаруживать сервисы Muse рядом")
        case .camera: return PalL10n.text("Сделать фото только по вашей команде")
        case .microphone: return PalL10n.text("Записать голосовую заметку")
        case .speechRecognition: return PalL10n.text("Превратить речь в текст")
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
        case .speechRecognition: return "waveform"
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
