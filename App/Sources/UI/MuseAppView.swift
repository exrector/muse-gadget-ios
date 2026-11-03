import SwiftUI
import UIKit

struct MuseChatItem: Identifiable {
    enum Author: Equatable { case user, muse, system }

    let id: UUID
    let author: Author
    var text: String
    var image: UIImage?
    var museMessageID: String?

    init(
        id: UUID = UUID(),
        author: Author,
        text: String,
        image: UIImage? = nil,
        museMessageID: String? = nil
    ) {
        self.id = id
        self.author = author
        self.text = text
        self.image = image
        self.museMessageID = museMessageID
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
        didSet { environment.chatStore.scheduleSave(chatItems) }
    }
    @Published var isSendingChat = false
    @Published var isAwaitingReply = false
    @Published var museActivity: String?
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
        keepScreenAwake = UserDefaults.standard.object(forKey: Self.keepScreenAwakeKey) as? Bool ?? true
        let hasToken = environment.credentialStore.loadSDKToken() != nil
        let hasPairing = environment.credentialStore.loadDeviceCredentials() != nil
        tokenSaved = hasToken
        isPaired = hasPairing
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
        environment.runtime.onChatRecord = { [weak self] record in
            guard let self else { return }
            self.apply(self.chatTimeline.feed(record))
        }
        applyIdleTimerPolicy()
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.environment.chatStore.flush()
            }
        }
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
            alertMessage = "В буфере обмена нет текста. Скопируйте SDK Token и попробуйте ещё раз."
            return
        }
        tokenDraft = value.trimmingCharacters(in: .whitespacesAndNewlines)
        saveToken()
    }

    func saveToken() {
        let candidate = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try environment.pairing.saveSDKToken(candidate)
            if UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) == candidate {
                UIPasteboard.general.string = ""
            }
            tokenDraft = ""
            tokenSaved = true
            isEditingToken = false
        } catch {
            alertMessage = "Этот SDK Token не похож на действующий ключ Muse. Скопируйте его целиком, без пробелов."
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
        alertMessage = "Камера недоступна. Разрешите доступ к камере в системных настройках."
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
            alertMessage = "Микрофон недоступен. Разрешите доступ к микрофону в системных настройках."
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
            chatItems.append(MuseChatItem(author: .system, text: "Не удалось записать голосовую заметку."))
            return
        }
        let durationMS = result.value["duration_ms"] as? Int ?? 0
        guard durationMS >= 500, canSendToMuse else { return }
        chatItems.append(MuseChatItem(author: .user, text: "🎙 Голосовая заметка · \(max(durationMS / 1_000, 1)) с"))
        beginRequest()
        environment.runtime.sendVoiceNote(wav: wav) { [weak self] result in
            self?.finishRequest(result)
        }
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
            return "Файл слишком большой для отправки в Muse."
        case MuseRuntimeError.requestTimedOut:
            return "Muse не подтвердил сообщение вовремя. Попробуйте ещё раз."
        case MuseRuntimeError.requestFailed(let status):
            return "Muse отклонил сообщение (HTTP \(status))."
        default:
            return "Не удалось отправить сообщение. Канал Muse переподключится автоматически."
        }
    }

    func clearChatHistory() {
        chatItems.removeAll()
        replyItemIDs.removeAll()
        environment.chatStore.clear()
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
            } else {
                MuseOnboarding(model: model)
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .alert("Muse Gadget", isPresented: Binding(
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
    static let violet = Color(red: 0.48, green: 0.36, blue: 0.98)
    static let blue = Color(red: 0.20, green: 0.63, blue: 1.00)
    static let mint = Color(red: 0.25, green: 0.87, blue: 0.73)
    static let card = Color.white.opacity(0.09)
    static let stroke = Color.white.opacity(0.12)
    static let secondary = Color.white.opacity(0.66)
    static let background = LinearGradient(
        colors: [
            Color(red: 0.035, green: 0.045, blue: 0.10),
            Color(red: 0.08, green: 0.055, blue: 0.17),
            Color(red: 0.025, green: 0.08, blue: 0.13)
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
                    colors: [MuseTheme.violet, MuseTheme.blue],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .opacity(pressedOpacity)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
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
                    Text("Muse Gadget").font(.headline)
                    Text("настройка устройства").font(.caption).foregroundColor(MuseTheme.secondary)
                }
                Spacer()
                Text("\(model.setupStep + 1) / 5")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(MuseTheme.secondary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule()
                        .fill(LinearGradient(colors: [MuseTheme.violet, MuseTheme.blue], startPoint: .leading, endPoint: .trailing))
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
            Circle().fill(LinearGradient(colors: [MuseTheme.violet, MuseTheme.blue], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: MuseTheme.violet.opacity(0.45), radius: 14, y: 5)
        .accessibilityHidden(true)
    }
}

private struct StepIntro: View {
    let eyebrow: String
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(eyebrow.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1.2)
                .foregroundColor(MuseTheme.mint)
            Text(title)
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            Text(text)
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
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundColor(MuseTheme.secondary)
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
                Label(model.tokenSaved ? "Ключ сохранён" : "SDK Token", systemImage: model.tokenSaved ? "checkmark.circle.fill" : "key.fill")
                    .font(.headline)
                    .foregroundColor(model.tokenSaved ? MuseTheme.mint : .white)

                if !model.tokenSaved || model.isEditingToken {
                    SecureField("mgst_…", text: $model.tokenDraft)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .padding(14)
                        .background(Color.black.opacity(0.22))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Button {
                        model.pasteToken()
                    } label: {
                        Label("Вставить из буфера", systemImage: "doc.on.clipboard")
                            .frame(maxWidth: .infinity, minHeight: 46)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MuseTheme.violet)

                    Button("Сохранить введённый ключ") { model.saveToken() }
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
                    if permission != AppPermission.allCases.last { Divider().overlay(Color.white.opacity(0.08)) }
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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: permission.icon)
                .foregroundColor(state == .granted ? MuseTheme.mint : MuseTheme.blue)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.russianTitle).font(.subheadline.weight(.semibold))
                Text(permission.explanation).font(.caption).foregroundColor(MuseTheme.secondary)
            }
            Spacer(minLength: 8)
            Button(state.buttonTitle, action: action)
                .font(.caption.weight(.bold))
                .buttonStyle(.bordered)
                .tint(state == .granted ? MuseTheme.mint : MuseTheme.blue)
                .disabled(state == .granted || state == .restricted)
        }
        .padding(.vertical, 9)
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
                        Text(model.currentSSIDWasDetected ? "Сеть найдена" : "Имя сети")
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
                .background(Color.black.opacity(0.20))
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
                PairInstruction(number: "3", text: "Нажмите + и выберите \(model.deviceName).")
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
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .buttonStyle(.bordered)
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
                .background(MuseTheme.violet.opacity(0.26))
                .clipShape(Circle())
            Text(text).font(.body)
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
                            Label(
                                model.runtimeState == .registered ? "Подключено к Muse VM" : "Пара создана",
                                systemImage: model.runtimeState == .registered ? "network" : "checkmark.circle.fill"
                            )
                                .font(.caption.weight(.semibold)).foregroundColor(MuseTheme.mint)
                        }
                        Spacer()
                    }
                    .padding(.top, 8)

                    StatusBanner(state: model.runtimeState)

                    ChatBubble(
                        text: model.runtimeState == .registered
                            ? "Гаджет зарегистрирован в Muse. Сетевой канал активен и готов принимать команды."
                            : "Пара создана и сохранена. Подключаем защищённый канал Muse VM…",
                        isMuse: true
                    )

                    if !model.caption.isEmpty {
                        ChatBubble(text: model.caption, isMuse: true)
                    }

                    ForEach(model.chatItems) { item in
                        ChatBubble(text: item.text, isMuse: item.author != .user, image: item.image)
                    }

                    if model.isAwaitingReply {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(model.museActivity ?? "Muse отвечает…")
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
                        Text("Запись · \(model.recordingSeconds) с из 40")
                            .font(.subheadline.monospacedDigit())
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 15)
                    .frame(minHeight: 46)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())
                    Button(action: model.toggleVoiceRecording) {
                        Image(systemName: "stop.fill")
                            .font(.headline)
                            .frame(width: 44, height: 44)
                            .background(Color.red)
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("Остановить и отправить")
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
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                        .disabled(model.runtimeState != .registered)
                        .submitLabel(.send)
                        .onSubmit(sendDraft)

                    if hasDraft {
                        Button(action: sendDraft) {
                            Image(systemName: model.isSendingChat ? "ellipsis" : "arrow.up")
                                .font(.headline)
                                .frame(width: 44, height: 44)
                                .background(canSend ? MuseTheme.violet : Color.white.opacity(0.10))
                                .clipShape(Circle())
                        }
                        .disabled(!canSend)
                        .accessibilityLabel("Отправить")
                    } else {
                        Button(action: model.toggleVoiceRecording) {
                            Image(systemName: "mic.fill")
                                .font(.headline)
                                .frame(width: 44, height: 44)
                                .background(Color.white.opacity(0.10))
                                .clipShape(Circle())
                        }
                        .disabled(!model.canSendToMuse)
                        .accessibilityLabel("Записать голосовую заметку")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) {
                Text(model.runtimeState == .registered ? "Защищённый чат Muse активен" : "Ждём регистрации в Muse VM")
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
                .background(isMuse ? Color.white.opacity(0.10) : MuseTheme.violet)
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
        ("network", "Локальная сеть", "Поиск сервисов рядом с устройством", "Пока только разрешение")
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
                            Text(item.1).font(.headline)
                            Text(item.2).font(.subheadline).foregroundColor(MuseTheme.secondary)
                            Text(item.3.uppercased())
                                .font(.caption2.weight(.bold)).tracking(0.8)
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
                    SettingsLine(icon: "checkmark.seal.fill", title: "Пара Muse", value: "Создана", tint: MuseTheme.mint)
                    SettingsLine(
                        icon: "network",
                        title: "Muse VM",
                        value: model.runtimeState.shortTitle,
                        tint: model.runtimeState == .registered ? MuseTheme.mint : .yellow
                    )
                    SettingsLine(icon: "iphone", title: "Имя устройства", value: model.deviceName, tint: MuseTheme.blue)
                    SettingsLine(icon: "wifi", title: "Сеть", value: CurrentWiFi.preferredSSID() ?? "Не указана", tint: MuseTheme.blue)
                    if let account = model.pairedAccount {
                        SettingsLine(icon: "person.crop.circle", title: "Аккаунт", value: account, tint: MuseTheme.violet)
                    }
                }
                .museCard()

                VStack(alignment: .leading, spacing: 13) {
                    Text("РАЗРЕШЕНИЯ").font(.caption.weight(.bold)).tracking(1).foregroundColor(MuseTheme.secondary)
                    ForEach(AppPermission.allCases, id: \.self) { permission in
                        HStack {
                            Image(systemName: permission.icon).frame(width: 24).foregroundColor(MuseTheme.blue)
                            Text(permission.russianTitle).font(.subheadline)
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

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Не гасить экран", isOn: $model.keepScreenAwake)
                        .font(.subheadline)
                    Text("Камера, микрофон и датчики отвечают Muse, только пока приложение на экране.")
                        .font(.caption)
                        .foregroundColor(MuseTheme.secondary)
                }
                .museCard()

                DisclosureGroup("Диагностика") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.diagnostics.isEmpty ? "Новых событий нет" : model.diagnostics.joined(separator: "\n"))
                            .font(.caption2.monospaced())
                            .foregroundColor(MuseTheme.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.top, 12)
                }
                .museCard()

                Button("Очистить историю чата", role: .destructive) { showClearHistoryConfirmation = true }
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(model.chatItems.isEmpty)

                Button("Повторить пошаговую настройку") { model.restartGuide() }
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .buttonStyle(.bordered)

                Button("Заменить SDK Token") { model.beginTokenReplacement() }
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .buttonStyle(.bordered)

                Button("Удалить пару с Muse", role: .destructive) { showForgetConfirmation = true }
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .buttonStyle(.bordered)
                    .tint(.red)
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
            Text("Сообщения и фото удалятся с этого устройства. Переписка в самом Muse останется.")
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

private struct SettingsLine: View {
    let icon: String
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundColor(tint).frame(width: 24)
            Text(title).font(.subheadline)
            Spacer()
            Text(value).font(.subheadline.weight(.semibold)).lineLimit(1)
        }
    }
}

private extension AppPermission {
    var russianTitle: String {
        switch self {
        case .bluetooth: return "Bluetooth"
        case .localNetwork: return "Локальная сеть"
        case .camera: return "Камера"
        case .microphone: return "Микрофон"
        case .speechRecognition: return "Распознавание речи"
        case .location: return "Геопозиция"
        case .motion: return "Датчики движения"
        }
    }

    var explanation: String {
        switch self {
        case .bluetooth: return "Найти устройство во время создания пары"
        case .localNetwork: return "Обнаруживать сервисы Muse рядом"
        case .camera: return "Сделать фото только по вашей команде"
        case .microphone: return "Записать голосовую заметку"
        case .speechRecognition: return "Превратить речь в текст"
        case .location: return "Определить Wi‑Fi и выполнять команды геопозиции"
        case .motion: return "Использовать акселерометр и движение"
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
        case .notDetermined: return "Не запрошено"
        case .granted: return "Разрешено"
        case .denied: return "Запрещено"
        case .restricted: return "Ограничено"
        case .unavailable: return "Недоступно"
        }
    }

    var buttonTitle: String {
        switch self {
        case .notDetermined: return "Разрешить"
        case .granted: return "Готово"
        case .denied: return "Настройки"
        case .restricted: return "Недоступно"
        case .unavailable: return "Повторить"
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
        case .idle: return "Готово к созданию пары"
        case .needsSDKToken: return "Сначала добавьте SDK Token"
        case .bluetooth: return "Включаем Bluetooth…"
        case .advertising: return "Устройство видно в Muse"
        case .connected: return "Muse подключается…"
        case .encrypted: return "Защищаем соединение…"
        case .provisioning: return "Сохраняем пару…"
        case .paired: return "Пара создана"
        case .failed(let message): return "Не получилось: \(message)"
        }
    }
}

private extension MuseRuntimeState {
    var shortTitle: String {
        switch self {
        case .idle: return "Ожидание"
        case .fetchingVM: return "Поиск VM"
        case .connecting: return "Соединение"
        case .handshaking: return "Шифрование"
        case .registering: return "Регистрация"
        case .registered: return "Подключена"
        case .failed: return "Повторяем"
        }
    }

    var title: String {
        switch self {
        case .registered: return "Канал Muse VM подключён"
        case .failed: return "Канал временно недоступен"
        case .idle: return "Ожидаем данные пары"
        default: return "Подключаем Muse VM…"
        }
    }

    var detail: String {
        switch self {
        case .registered:
            return "Noise XX и link.register подтверждены сервером Muse."
        case .failed(let message):
            return "\(message). Приложение повторит подключение автоматически."
        case .idle:
            return "После создания пары приложение подключится автоматически."
        case .fetchingVM:
            return "Получаем виртуальную машину аккаунта."
        case .connecting:
            return "Открываем защищённый WebSocket."
        case .handshaking:
            return "Выполняем Noise XX с AES-GCM."
        case .registering:
            return "Отправляем link.register и ждём подтверждения."
        }
    }
}
