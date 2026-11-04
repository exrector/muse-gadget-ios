import Foundation
import os
import UIKit

enum MuseAppVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var userAgent: String { "muse-gadget-ios/\(current)" }
}

struct MuseVM: Decodable {
    let url: String
    let authorizationToken: String
    let name: String
    let identifier: String
    let isDefault: Bool

    init?(wire: [String: Any]) {
        guard let url = (wire["vm_ws_url"] ?? wire["vm_url"]) as? String,
              let token = wire["vm_auth_token"] as? String else { return nil }
        self.url = url
        self.authorizationToken = token
        self.name = wire["vm_name"] as? String ?? ""
        self.identifier = wire["vm_id"] as? String ?? ""
        self.isDefault = wire["default"] as? Bool ?? false
    }
}

enum MuseAPIError: Error {
    case invalidURL
    case invalidResponse
    case unauthorized
    case server(Int)
}

struct MuseRotatedTokens: Equatable {
    let accessToken: String
    let refreshToken: String
}

final class MuseAPIClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchVMs(credentials: DeviceCredentials, completion: @escaping (Result<[MuseVM], Error>) -> Void) {
        let root = credentials.apiURLV2.isEmpty ? "https://api.muse.ai" : credentials.apiURLV2
        guard let url = URL(string: root.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/fetch_vms") else {
            completion(.failure(MuseAPIError.invalidURL)); return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("1.0.0", forHTTPHeaderField: "X-API-Version")
        request.setValue(MuseAppVersion.userAgent, forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(MuseAPIError.invalidResponse)); return
            }
            if http.statusCode == 401 { completion(.failure(MuseAPIError.unauthorized)); return }
            guard (200..<300).contains(http.statusCode), let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = object["vm_list"] as? [[String: Any]] else {
                completion(.failure(MuseAPIError.server(http.statusCode))); return
            }
            completion(.success(list.compactMap(MuseVM.init(wire:))))
        }.resume()
    }

    /// Rotates the token pair with the refresh token only; the SDK never presents the access token
    /// here because the server can answer 200 with replacements that every endpoint then rejects.
    func refreshTokens(
        credentials: DeviceCredentials,
        deviceID: String,
        sdkToken: String?,
        completion: @escaping (Result<MuseRotatedTokens, Error>) -> Void
    ) {
        let root = credentials.apiURLV2.isEmpty ? "https://api.muse.ai" : credentials.apiURLV2
        guard let url = URL(string: root.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/device_token/refresh") else {
            completion(.failure(MuseAPIError.invalidURL)); return
        }
        var body = ["device_id": deviceID]
        if let sdkToken, !sdkToken.isEmpty { body["sdk_token"] = sdkToken }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.setValue(Self.refreshAuthorization(credentials.refreshToken), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(MuseAppVersion.userAgent, forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(MuseAPIError.invalidResponse)); return
            }
            if http.statusCode == 401 { completion(.failure(MuseAPIError.unauthorized)); return }
            guard (200..<300).contains(http.statusCode), let data,
                  let tokens = Self.parseRotatedTokens(data) else {
                completion(.failure(MuseAPIError.server(http.statusCode))); return
            }
            completion(.success(tokens))
        }.resume()
    }

    /// Stored refresh tokens may already carry the `hatch_refresh:` prefix; doubling it is rejected.
    static func refreshAuthorization(_ refreshToken: String) -> String {
        let raw = refreshToken.split(separator: ":", omittingEmptySubsequences: false).last.map(String.init) ?? refreshToken
        return "Bearer hatch_refresh:\(raw)"
    }

    static func parseRotatedTokens(_ data: Data) -> MuseRotatedTokens? {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let payload = object["payload"] as? [String: Any] { object = payload }
        guard let access = object["access_token"] as? String, !access.isEmpty,
              let refresh = object["refresh_token"] as? String, !refresh.isEmpty else { return nil }
        return MuseRotatedTokens(accessToken: access, refreshToken: refresh)
    }
}

enum MuseRuntimeState: Equatable {
    case idle
    case fetchingVM
    case connecting
    case handshaking
    case registering
    case registered
    case failed(String)
}

enum MuseRuntimeError: Error {
    case notConnected
    case requestTimedOut
    case requestFailed(Int)
    case connectionEnded
    case invalidResponse
    case payloadTooLarge
}

private struct MuseHTTPResult {
    let status: Int
    let body: Data
}

struct MuseAgentIdentity: Equatable {
    let name: String

    /// The daemon wraps the identity as `{"ok":true,"result":{"name":...}}`.
    static func parse(_ data: Data) -> MuseAgentIdentity? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let result = root["result"] as? [String: Any] ?? root
        let name = (result["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : MuseAgentIdentity(name: name)
    }
}

/// The name Muse gave itself, kept on the device. /identity refuses this gadget's credential, so
/// Muse sets it by command instead, or through its list on the VM.
enum MuseAgentName {
    private static let key = "agentName"

    static var saved: String? { UserDefaults.standard.string(forKey: key) }

    /// Returns false for a name that is empty, too long for the header, or more than one line.
    @discardableResult
    static func save(_ raw: String) -> Bool {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, !name.contains(where: \.isNewline) else { return false }
        UserDefaults.standard.set(name, forKey: key)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .museAgentNameChanged, object: name)
        }
        return true
    }
}

extension Notification.Name {
    static let museAgentNameChanged = Notification.Name("MuseGadgetLegacy.agentNameChanged")
}

enum MuseVMFileError: Error {
    case status(Int)
    case tooLarge
}

private struct PendingHTTPRequest {
    var status: Int?
    var body = Data()
    let timeout: DispatchWorkItem
    let completion: (Result<MuseHTTPResult, Error>) -> Void
}

private struct MuseOutboundMessage {
    let data: Data
    let generation: Int
    let socket: URLSessionWebSocketTask
    let completion: () -> Void
}

private final class MuseNoiseTransport {
    private let send: MuseNoiseCipherState
    private let receive: MuseNoiseCipherState
    private let frameDecoder = MuseNoiseFrameDecoder()

    init(send: MuseNoiseCipherState, receive: MuseNoiseCipherState) {
        self.send = send
        self.receive = receive
    }

    func encrypt(_ serviceRequest: Data) throws -> Data {
        try send.encrypt(ad: Data(), plaintext: MuseNoiseWire.noiseFrame(payload: serviceRequest))
    }

    func decrypt(_ ciphertext: Data) throws -> MuseInboundServiceFrame? {
        let plainFrame = try receive.decrypt(ad: Data(), ciphertext: ciphertext)
        guard let serviceResponse = try frameDecoder.decode(plainFrame) else { return nil }
        return try MuseNoiseWire.decodeServiceFrame(serviceResponse)
    }
}

final class MuseRuntime: NSObject {
    var onStateChange: ((MuseRuntimeState) -> Void)?
    var onLog: ((String) -> Void)?
    var onUnpaired: (() -> Void)?
    var onChatRecord: (([String: Any]) -> Void)?
    var onAgentIdentity: ((MuseAgentIdentity) -> Void)?
    var onCommandFinished: ((String, Bool) -> Void)?
    var onRegistered: (() -> Void)?

    private let identity: DeviceIdentity
    private let commands: IOSCommandRegistry
    private let api: MuseAPIClient
    private let credentialStore: CredentialStore
    private let logger = Logger(subsystem: "com.exrector.MuseGadgetLegacy", category: "runtime")
    private let queue = DispatchQueue(label: "MuseGadgetLegacy.runtime")
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private var webSocket: URLSessionWebSocketTask?
    private var credentials: DeviceCredentials?
    private var handshake: MuseNoiseXXInitiator?
    private var transport: MuseNoiseTransport?
    private var controlDecoder = MuseControlMessageDecoder()
    private var registerID = ""
    private var reconnect: DispatchWorkItem?
    private var ping: DispatchWorkItem?
    private var generation = 0
    private var activeInvokes: Set<String> = []
    private let maxConcurrentInvokes = 4
    private var nextStreamID: Int64 = 2
    private var pendingRequests: [Int64: PendingHTTPRequest] = [:]
    private var chatSubscriptionID: Int64?
    private var chatDecoder = MuseNDJSONDecoder()
    private var outboundMessages: [MuseOutboundMessage] = []
    private var isSendingMessage = false
    private var reconnectFailures = 0
    private var registeredAt: Date?
    private var lastRefreshAttempt: Date?
    private var tokenRejected = false

    private static let tokenRefreshAge: TimeInterval = 3 * 3600
    private static let tokenRetryInterval: TimeInterval = 300
    private static let authBackoffFloor: TimeInterval = 15
    private static let healthySession: TimeInterval = 30
    private static let maxInlineRequestBytes = 64 * 1024
    private static let maxControlMessageBytes = 256 * 1024
    private static let maxMediaBytes = 2 * 1024 * 1024

    private(set) var state: MuseRuntimeState = .idle {
        didSet { DispatchQueue.main.async { self.onStateChange?(self.state) } }
    }

    init(
        identity: DeviceIdentity,
        commands: IOSCommandRegistry,
        credentialStore: CredentialStore,
        api: MuseAPIClient = MuseAPIClient()
    ) {
        self.identity = identity
        self.commands = commands
        self.credentialStore = credentialStore
        self.api = api
        super.init()
    }

    func start(credentials: DeviceCredentials) {
        queue.async {
            self.credentials = credentials
            self.generation += 1
            self.reconnectFailures = 0
            self.tokenRejected = false
            self.resetConnection()
            self.fetchVM(generation: self.generation)
        }
    }

    /// Called when the app returns to the foreground: a suspended socket may be dead by now.
    func resumeIfNeeded() {
        queue.async {
            guard self.credentials != nil else { return }
            switch self.state {
            case .failed:
                guard self.reconnect != nil else { return }
                self.reconnect?.cancel()
                self.reconnect = nil
                self.reconnectFailures = 0
                self.fetchVM(generation: self.generation)
            case .registered:
                self.ping?.cancel()
                self.sendPing()
            default:
                break
            }
        }
    }

    func stop() {
        queue.async {
            self.credentials = nil
            self.generation += 1
            self.resetConnection()
            self.state = .idle
        }
    }

    func sendChat(_ message: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let clean = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            completion(.failure(MuseRuntimeError.invalidResponse))
            return
        }
        postChat(["message": clean, "output_modality": "text"], completion: completion)
    }

    func sendImage(
        jpeg: Data,
        message: String = "",
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        postMedia(
            item: [
                "type": "image",
                "mime_type": "image/jpeg",
                "filename": "photo.jpg",
                "data_base64": jpeg.base64EncodedString()
            ],
            byteCount: jpeg.count,
            message: message,
            completion: completion
        )
    }

    func sendVoiceNote(
        wav: Data,
        message: String = "",
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        postMedia(
            item: [
                "type": "file",
                "mime_type": "audio/wav",
                "filename": "voice_note.wav",
                "data_base64": wav.base64EncodedString()
            ],
            byteCount: wav.count,
            message: message,
            completion: completion
        )
    }

    private func postMedia(
        item: [String: Any],
        byteCount: Int,
        message: String,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        guard byteCount > 0, byteCount <= Self.maxMediaBytes else {
            completion(.failure(MuseRuntimeError.payloadTooLarge))
            return
        }
        // Muse reads only the items of a request that has any, so text goes first as its own item.
        let clean = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let text: [[String: Any]] = clean.isEmpty ? [] : [["type": "text", "text": clean]]
        postChat(
            ["message": clean, "output_modality": "text", "items": text + [item]],
            completion: completion
        )
    }

    private func postChat(
        _ fields: [String: Any],
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        queue.async {
            guard self.state == .registered else {
                DispatchQueue.main.async { completion(.failure(MuseRuntimeError.notConnected)) }
                return
            }
            do {
                var request = fields
                request["device_id"] = self.identity.nodeID
                let body = try JSONSerialization.data(withJSONObject: request)
                self.performRequest(
                    method: "POST",
                    path: "/chat/stream",
                    body: body,
                    headers: [MuseHTTPHeader(name: "Content-Type", value: "application/json")]
                ) { result in
                    let mapped: Result<[String: Any], Error> = result.flatMap { response in
                        guard (200..<300).contains(response.status) else {
                            return .failure(MuseRuntimeError.requestFailed(response.status))
                        }
                        if response.body.isEmpty { return .success([:]) }
                        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
                            return .failure(MuseRuntimeError.invalidResponse)
                        }
                        return .success(object)
                    }
                    DispatchQueue.main.async { completion(mapped) }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func fetchVM(generation: Int) {
        guard let credentials, generation == self.generation else { return }
        state = .fetchingVM
        if Date().timeIntervalSince(credentials.savedAt) >= Self.tokenRefreshAge, refreshAllowed() {
            refreshTokens(generation: generation) { [weak self] _ in
                self?.lookUpVM(generation: generation)
            }
        } else {
            lookUpVM(generation: generation)
        }
    }

    private func refreshAllowed() -> Bool {
        guard let last = lastRefreshAttempt else { return true }
        return Date().timeIntervalSince(last) >= Self.tokenRetryInterval
    }

    private func lookUpVM(generation: Int) {
        guard let credentials, generation == self.generation else { return }
        log("Fetching the paired account's Muse VM")
        api.fetchVMs(credentials: credentials) { [weak self] result in
            self?.queue.async {
                guard let self, generation == self.generation else { return }
                switch result {
                case .success(let vms):
                    self.tokenRejected = false
                    guard let vm = vms.first(where: { $0.isDefault }) ?? vms.first else {
                        self.fail("Muse returned no usable VM", reconnect: true)
                        return
                    }
                    self.connect(vm: vm, credentials: credentials, generation: generation)
                case .failure(MuseAPIError.unauthorized):
                    self.handleRejectedAccessToken(generation: generation)
                case .failure(let error):
                    self.fail("VM lookup failed: \(self.safeError(error))", reconnect: true)
                }
            }
        }
    }

    private func handleRejectedAccessToken(generation: Int) {
        log("Device token rejected by Muse; refreshing")
        // Allow one immediate retry with the refreshed token; repeated rejection must back off.
        let alreadyRejected = tokenRejected
        tokenRejected = true
        refreshTokens(generation: generation) { [weak self] refreshed in
            guard let self, generation == self.generation else { return }
            if refreshed, !alreadyRejected {
                self.lookUpVM(generation: generation)
            } else {
                self.fail("Muse rejected the device token", reconnect: true, floor: Self.authBackoffFloor)
            }
        }
    }

    /// Completes on `queue`. Credentials are kept when Muse revokes them, so nothing is lost if the
    /// rejection was wrong; the user decides whether to remove the pairing and pair again.
    private func refreshTokens(generation: Int, completion: @escaping (Bool) -> Void) {
        guard let current = credentials else { completion(false); return }
        lastRefreshAttempt = Date()
        api.refreshTokens(
            credentials: current,
            deviceID: identity.nodeID,
            sdkToken: credentialStore.loadSDKToken()
        ) { [weak self] result in
            self?.queue.async {
                guard let self, generation == self.generation, self.credentials == current else { return }
                switch result {
                case .success(let tokens):
                    let rotated = DeviceCredentials(
                        accessToken: tokens.accessToken,
                        refreshToken: tokens.refreshToken,
                        username: current.username,
                        apiURL: current.apiURL,
                        apiURLV2: current.apiURLV2,
                        noiseHost: current.noiseHost,
                        savedAt: Date()
                    )
                    self.credentials = rotated
                    do {
                        try self.credentialStore.saveDeviceCredentials(rotated)
                        self.log("Device token rotated")
                    } catch {
                        self.log("Rotated device token could not be saved: \(self.safeError(error))")
                    }
                    completion(true)
                case .failure(MuseAPIError.unauthorized):
                    self.fail("Muse revoked this pairing; pair the device again", reconnect: false)
                case .failure(let error):
                    self.log("Device token refresh failed: \(self.safeError(error))")
                    completion(false)
                }
            }
        }
    }

    private func connect(vm: MuseVM, credentials: DeviceCredentials, generation: Int) {
        let rawHost = credentials.noiseHost.isEmpty ? "hatch.metaaivm.com" : credentials.noiseHost
        let host = URL(string: rawHost)?.host ?? rawHost
            .replacingOccurrences(of: "wss://", with: "")
            .replacingOccurrences(of: "https://", with: "")
            .split(separator: "/").first.map(String.init) ?? rawHost
        let vmID = vm.identifier.isEmpty ? vm.name : vm.identifier
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.path = "/v1/noise"
        components.queryItems = [URLQueryItem(name: "vm_id", value: vmID)]
        guard let url = components.url else {
            fail("Invalid Noise host", reconnect: false)
            return
        }

        state = .connecting
        log("Connecting to Muse VM")
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(vm.authorizationToken)", forHTTPHeaderField: "Authorization")
        request.setValue(MuseAppVersion.userAgent, forHTTPHeaderField: "User-Agent")
        let task = session.webSocketTask(with: request)
        task.taskDescription = String(generation)
        webSocket = task
        task.resume()
    }

    private func beginHandshake() {
        do {
            state = .handshaking
            let handshake = MuseNoiseXXInitiator()
            try handshake.initialize()
            self.handshake = handshake
            try sendBinary(handshake.writeMessage1()) { [weak self] in
                self?.receiveHandshakeMessage2()
            }
        } catch {
            fail("Noise handshake could not start", reconnect: true)
        }
    }

    private func receiveHandshakeMessage2() {
        receiveBinary { [weak self] result in
            guard let self else { return }
            do {
                let message2 = try result.get()
                guard let handshake = self.handshake else { throw MuseNoiseError.invalidState }
                _ = try handshake.readMessage2(message2)
                let message3 = try handshake.writeMessage3()
                let split = try handshake.split()
                self.handshake = nil
                self.transport = MuseNoiseTransport(send: split.send, receive: split.receive)
                self.log("Noise XX session established")
                try self.sendBinary(message3) { [weak self] in self?.openControlStream() }
            } catch {
                self.fail("Noise handshake failed: \(self.safeError(error))", reconnect: true)
            }
        }
    }

    private func openControlStream() {
        do {
            guard transport != nil else { throw MuseNoiseError.invalidState }
            state = .registering
            receiveLoop()
            try sendEncrypted(MuseNoiseWire.startControlStream(streamID: 1)) { [weak self] in
                self?.sendRegistration()
            }
        } catch {
            fail("Control stream failed: \(safeError(error))", reconnect: true)
        }
    }

    private func sendRegistration() {
        registerID = UUID().uuidString.lowercased()
        let params: [String: Any] = [
            "node_id": identity.nodeID,
            "display_name": identity.displayName,
            "platform": "ios",
            "version": MuseAppVersion.current,
            "device_family": "homehub",
            "model_id": UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone",
            "is_wakeup_supported": false,
            "commands_v2": commands.commandSpecs
        ]
        let message: [String: Any] = [
            "type": "req",
            "id": registerID,
            "method": "link.register",
            "params": params
        ]
        do {
            let body = try MuseNoiseWire.controlMessage(message)
            try sendEncrypted(MuseNoiseWire.bodyChunk(streamID: 1, data: body)) { [weak self] in
                self?.log("Sent link.register")
            }
        } catch {
            fail("link.register could not be encoded", reconnect: true)
        }
    }

    private func receiveLoop() {
        receiveBinary { [weak self] result in
            guard let self else { return }
            do {
                let data = try result.get()
                if let frame = try self.transport?.decrypt(data) {
                    try self.handle(frame)
                }
                self.receiveLoop()
            } catch {
                self.fail("Muse VM connection ended: \(self.safeError(error))", reconnect: true)
            }
        }
    }

    private func handle(_ frame: MuseInboundServiceFrame) throws {
        switch frame {
        case .response(let id, let response):
            if id == 1 {
                guard (200..<300).contains(response.status) else { throw MuseWireError.malformed }
                for message in try controlDecoder.feed(response.body) { handleControl(message) }
                if response.endBody { throw MuseRuntimeError.connectionEnded }
            } else {
                try handleHTTPResponse(streamID: id, response: response)
            }
        case .body(let id, let chunk):
            if id == 1 {
                for message in try controlDecoder.feed(chunk.data) { handleControl(message) }
                if chunk.endBody { throw MuseRuntimeError.connectionEnded }
            } else {
                try handleHTTPBody(streamID: id, chunk: chunk)
            }
        case .reset(let id, let reason):
            if id == 1 {
                throw NSError(domain: "MuseLink", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
            }
            handleHTTPReset(streamID: id)
        }
    }

    private func performRequest(
        method: String,
        path: String,
        body: Data,
        headers: [MuseHTTPHeader],
        includeStandardHeaders: Bool = true,
        completion: @escaping (Result<MuseHTTPResult, Error>) -> Void
    ) {
        guard transport != nil else {
            completion(.failure(MuseRuntimeError.notConnected))
            return
        }
        let streamID = allocateStreamID()
        var requestHeaders = headers
        if includeStandardHeaders {
            requestHeaders.append(MuseHTTPHeader(name: "x-request-id", value: UUID().uuidString.lowercased()))
            requestHeaders.append(MuseHTTPHeader(name: "x-app-id", value: "musegadget"))
        }
        let uploadInParts = body.count > Self.maxInlineRequestBytes
        let timeout = DispatchWorkItem { [weak self] in
            self?.resetStream(streamID, reason: "request ended")
            self?.finishRequest(streamID: streamID, result: .failure(MuseRuntimeError.requestTimedOut))
        }
        pendingRequests[streamID] = PendingHTTPRequest(timeout: timeout, completion: completion)
        // The SDK's 60 s starts after the upload; slow links must not lose the reply to a long send.
        queue.asyncAfter(deadline: .now() + (uploadInParts ? 240 : 60), execute: timeout)
        do {
            let start = MuseNoiseWire.applicationRequest(
                streamID: streamID,
                method: method,
                path: path,
                headers: requestHeaders,
                body: uploadInParts ? Data() : body,
                endBody: !uploadInParts
            )
            try sendEncrypted(start) { [weak self] in self?.log("Sent Muse chat request") }
            if uploadInParts {
                for chunk in MuseNoiseWire.bodyChunks(streamID: streamID, data: body, endBody: true) {
                    try sendEncrypted(chunk, completion: {})
                }
            }
        } catch {
            finishRequest(streamID: streamID, result: .failure(error))
        }
    }

    private func resetStream(_ streamID: Int64, reason: String) {
        guard transport != nil else { return }
        try? sendEncrypted(MuseNoiseWire.reset(streamID: streamID, reason: reason), completion: {})
    }

    private func openChatSubscription() {
        guard state == .registered, chatSubscriptionID == nil else { return }
        let streamID = allocateStreamID()
        chatSubscriptionID = streamID
        chatDecoder = MuseNDJSONDecoder()
        do {
            let body = try JSONSerialization.data(withJSONObject: [:])
            let frame = MuseNoiseWire.applicationRequest(
                streamID: streamID,
                method: "POST",
                path: "/chat/subscribe",
                headers: [
                    MuseHTTPHeader(name: "Content-Type", value: "application/json"),
                    MuseHTTPHeader(name: "Accept", value: "application/x-ndjson"),
                    MuseHTTPHeader(name: "x-request-id", value: UUID().uuidString.lowercased()),
                    MuseHTTPHeader(name: "x-app-id", value: "musegadget")
                ],
                body: body,
                endBody: true
            )
            try sendEncrypted(frame) { [weak self] in self?.log("Subscribed to Muse chat") }
        } catch {
            chatSubscriptionID = nil
            scheduleChatSubscriptionReconnect()
        }
    }

    private func handleHTTPResponse(streamID: Int64, response: MuseApplicationResponse) throws {
        if streamID == chatSubscriptionID {
            guard (200..<300).contains(response.status) else {
                log("Muse chat subscription returned HTTP \(response.status)")
                closeChatSubscription(streamID: streamID, reconnect: true)
                return
            }
            handleChatData(response.body, end: response.endBody, streamID: streamID)
            if response.endBody { closeChatSubscription(streamID: streamID, reconnect: true) }
            return
        }
        guard var pending = pendingRequests[streamID] else { return }
        pending.status = response.status
        try append(response.body, to: &pending)
        pendingRequests[streamID] = pending
        if response.endBody {
            finishRequest(
                streamID: streamID,
                result: .success(MuseHTTPResult(status: response.status, body: pending.body))
            )
        }
    }

    private func handleHTTPBody(streamID: Int64, chunk: MuseBodyChunk) throws {
        if streamID == chatSubscriptionID {
            handleChatData(chunk.data, end: chunk.endBody, streamID: streamID)
            if chunk.endBody { closeChatSubscription(streamID: streamID, reconnect: true) }
            return
        }
        guard var pending = pendingRequests[streamID] else { return }
        try append(chunk.data, to: &pending)
        pendingRequests[streamID] = pending
        if chunk.endBody {
            finishRequest(
                streamID: streamID,
                result: .success(MuseHTTPResult(status: pending.status ?? 0, body: pending.body))
            )
        }
    }

    private func handleHTTPReset(streamID: Int64) {
        if streamID == chatSubscriptionID {
            closeChatSubscription(streamID: streamID, reconnect: true)
        } else {
            finishRequest(streamID: streamID, result: .failure(MuseRuntimeError.connectionEnded))
        }
    }

    private func append(_ data: Data, to request: inout PendingHTTPRequest) throws {
        guard request.body.count + data.count <= 1024 * 1024 else { throw MuseWireError.oversized }
        request.body.append(data)
    }

    private func finishRequest(streamID: Int64, result: Result<MuseHTTPResult, Error>) {
        guard let request = pendingRequests.removeValue(forKey: streamID) else { return }
        request.timeout.cancel()
        request.completion(result)
    }

    private func handleChatData(_ data: Data, end: Bool, streamID: Int64) {
        do {
            for record in try chatDecoder.feed(data, end: end) where record["type"] as? String == "event" {
                DispatchQueue.main.async { self.onChatRecord?(record) }
            }
        } catch {
            // An oversized chat event must not take the control stream down with it.
            log("Dropped Muse chat stream: \(safeError(error))")
            resetStream(streamID, reason: "consumer closed")
            closeChatSubscription(streamID: streamID, reconnect: true)
        }
    }

    private func closeChatSubscription(streamID: Int64, reconnect: Bool) {
        guard chatSubscriptionID == streamID else { return }
        chatSubscriptionID = nil
        chatDecoder = MuseNDJSONDecoder()
        if reconnect { scheduleChatSubscriptionReconnect() }
    }

    private func scheduleChatSubscriptionReconnect() {
        let reconnectGeneration = generation
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, reconnectGeneration == self.generation else { return }
            self.openChatSubscription()
        }
    }

    private func allocateStreamID() -> Int64 {
        let result = nextStreamID
        nextStreamID = nextStreamID == Int64.max ? 2 : nextStreamID + 1
        return result
    }

    private func handleControl(_ message: [String: Any]) {
        if message["id"] as? String == registerID, message["method"] == nil {
            if message["error"] != nil || message["ok"] as? Bool == false {
                fail("Muse rejected link.register", reconnect: false)
            } else {
                state = .registered
                registeredAt = Date()
                log("Registered with Muse")
                schedulePing()
                openChatSubscription()
                fetchAgentIdentity()
                DispatchQueue.main.async { self.onRegistered?() }
            }
            return
        }
        if let event = message["event"] as? String,
           event == "link.unpaired" || event == "node.unpaired" {
            log("Muse removed this device")
            DispatchQueue.main.async { self.onUnpaired?() }
            stop()
            return
        }
        guard message["method"] as? String == "link.invoke",
              let invokeID = message["id"] as? String else { return }
        guard activeInvokes.insert(invokeID).inserted else {
            sendInvokeFailure(id: invokeID, error: "duplicate invoke")
            return
        }
        guard activeInvokes.count <= maxConcurrentInvokes else {
            activeInvokes.remove(invokeID)
            sendInvokeFailure(id: invokeID, error: "device busy")
            return
        }
        let invokeGeneration = generation
        let command = message["command"] as? String ?? ""
        let arguments = message["params"] as? [String: Any] ?? [:]
        commands.invoke(name: command, arguments: arguments) { [weak self] result in
            self?.queue.async {
                guard let self else { return }
                self.activeInvokes.remove(invokeID)
                guard invokeGeneration == self.generation else { return }
                let outcome = result.success ? "ok" : result.value["error"] as? String ?? "failed"
                self.log("Command \(command): \(outcome)")
                DispatchQueue.main.async { self.onCommandFinished?(command, result.success) }
                var response: [String: Any] = [
                    "method": "link.result",
                    "id": invokeID,
                    "ok": result.success
                ]
                if result.success { response["payload"] = result.value }
                else { response["error"] = result.value["error"] as? String ?? "command failed" }
                self.sendControl(response)
            }
        }
    }

    private func sendInvokeFailure(id: String, error: String) {
        sendControl(["method": "link.result", "id": id, "ok": false, "error": error])
    }

    private func sendControl(_ message: [String: Any]) {
        do {
            var body = try MuseNoiseWire.controlMessage(message)
            if body.count > Self.maxControlMessageBytes, let id = message["id"] {
                body = try MuseNoiseWire.controlMessage([
                    "method": "link.result", "id": id, "ok": false, "error": "payload_too_large"
                ])
            }
            for chunk in MuseNoiseWire.bodyChunks(streamID: 1, data: body) {
                try sendEncrypted(chunk, completion: {})
            }
        } catch {
            fail("Could not send link.result", reconnect: true)
        }
    }

    /// Asks for the agent's name once, as the SDK's firmware does. A refusal only leaves the name
    /// unknown: Muse answers 403 to this gadget's credential, and the route carries no avatar anyway.
    private func fetchAgentIdentity() {
        performRequest(
            method: "GET",
            path: "/identity",
            body: Data(),
            headers: [],
            includeStandardHeaders: false
        ) { [weak self] result in
            guard let self else { return }
            guard case .success(let response) = result else {
                self.log("Muse identity request failed")
                return
            }
            guard (200..<300).contains(response.status),
                  let identity = MuseAgentIdentity.parse(response.body) else {
                self.log("Muse identity unavailable, HTTP \(response.status)")
                return
            }
            DispatchQueue.main.async { self.onAgentIdentity?(identity) }
        }
    }

    /// Reads a VM file in ranges, as the SDK's `display.draw_file` does: the daemon may send a whole
    /// reply in one frame, and a reply here is limited to 1 MiB. Completes on `queue`.
    func readVMFile(path: String, maxBytes: Int, completion: @escaping (Result<Data, Error>) -> Void) {
        queue.async {
            guard let encoded = path.addingPercentEncoding(withAllowedCharacters: Self.vmPathCharacters) else {
                completion(.failure(MuseVMFileError.status(0)))
                return
            }
            self.readVMRange(path: "/fs/raw/\(encoded)", received: Data(), maxBytes: maxBytes, completion: completion)
        }
    }

    private func readVMRange(
        path: String,
        received: Data,
        maxBytes: Int,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        let chunk = Self.vmFileChunkBytes
        performRequest(
            method: "GET",
            path: path,
            body: Data(),
            headers: [MuseHTTPHeader(name: "Range", value: "bytes=\(received.count)-\(received.count + chunk - 1)")],
            includeStandardHeaders: false
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let response):
                switch response.status {
                case 200 where received.isEmpty:
                    // The daemon ignored Range and sent the whole file.
                    completion(response.body.count <= maxBytes
                        ? .success(response.body)
                        : .failure(MuseVMFileError.tooLarge))
                case 206:
                    let total = received + response.body
                    if total.count > maxBytes {
                        completion(.failure(MuseVMFileError.tooLarge))
                    } else if response.body.count < chunk {
                        completion(.success(total))
                    } else {
                        self.readVMRange(path: path, received: total, maxBytes: maxBytes, completion: completion)
                    }
                case 416 where !received.isEmpty:
                    // The file ended exactly on the last range.
                    completion(.success(received))
                default:
                    completion(.failure(MuseVMFileError.status(response.status)))
                }
            }
        }
    }

    private static let vmFileChunkBytes = 256 * 1024

    private static let vmPathCharacters: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/")
        return allowed
    }()

    private func sendEncrypted(_ plaintext: Data, completion: @escaping () -> Void) throws {
        guard let transport else { throw MuseNoiseError.invalidState }
        try sendBinary(transport.encrypt(plaintext), completion: completion)
    }

    private func sendBinary(_ data: Data, completion: @escaping () -> Void) throws {
        guard let webSocket else { throw MuseNoiseError.invalidState }
        outboundMessages.append(MuseOutboundMessage(
            data: data,
            generation: generation,
            socket: webSocket,
            completion: completion
        ))
        drainOutboundMessages()
    }

    private func drainOutboundMessages() {
        guard !isSendingMessage, let message = outboundMessages.first else { return }
        guard message.socket === webSocket, message.generation == generation else {
            outboundMessages.removeFirst()
            drainOutboundMessages()
            return
        }
        isSendingMessage = true
        message.socket.send(.data(message.data)) { [weak self] error in
            self?.queue.async {
                guard let self,
                      message.socket === self.webSocket,
                      message.generation == self.generation else { return }
                self.isSendingMessage = false
                if !self.outboundMessages.isEmpty { self.outboundMessages.removeFirst() }
                if let error { self.fail("WebSocket send failed: \(self.safeError(error))", reconnect: true) }
                else {
                    message.completion()
                    self.drainOutboundMessages()
                }
            }
        }
    }

    private func receiveBinary(completion: @escaping (Result<Data, Error>) -> Void) {
        guard let webSocket else { completion(.failure(MuseNoiseError.invalidState)); return }
        let socket = webSocket
        let receiveGeneration = generation
        webSocket.receive { [weak self] result in
            self?.queue.async {
                guard let self, socket === self.webSocket, receiveGeneration == self.generation else { return }
                completion(result.flatMap { message in
                    switch message {
                    case .data(let data): return .success(data)
                    case .string: return .failure(MuseWireError.malformed)
                    @unknown default: return .failure(MuseWireError.malformed)
                    }
                })
            }
        }
    }

    private func schedulePing() {
        ping?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sendPing() }
        ping = work
        queue.asyncAfter(deadline: .now() + 20, execute: work)
    }

    private func sendPing() {
        guard let socket = webSocket else { return }
        let pingGeneration = generation
        socket.sendPing { [weak self] error in
            self?.queue.async {
                guard let self, socket === self.webSocket, pingGeneration == self.generation else { return }
                if let error { self.fail("Muse VM ping failed: \(self.safeError(error))", reconnect: true) }
                else { self.schedulePing() }
            }
        }
    }

    private func fail(_ message: String, reconnect shouldReconnect: Bool, floor: TimeInterval = 0) {
        log(message)
        state = .failed(message)
        if let registeredAt, Date().timeIntervalSince(registeredAt) >= Self.healthySession {
            reconnectFailures = 0
        }
        registeredAt = nil
        resetConnection()
        guard shouldReconnect, credentials != nil else { return }
        let generation = self.generation
        let work = DispatchWorkItem { [weak self] in self?.fetchVM(generation: generation) }
        reconnect = work
        let delay = Self.reconnectDelay(failures: reconnectFailures, floor: floor)
        reconnectFailures += 1
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 2, 4, 8 ... up to 60 seconds, matching the SDK's service loop.
    static func reconnectDelay(failures: Int, floor: TimeInterval = 0) -> TimeInterval {
        max(min(2 * pow(2, Double(min(failures, 16))), 60), floor)
    }

    private func resetConnection() {
        reconnect?.cancel()
        reconnect = nil
        ping?.cancel()
        ping = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        handshake = nil
        transport = nil
        registerID = ""
        controlDecoder = MuseControlMessageDecoder()
        activeInvokes.removeAll()
        outboundMessages.removeAll()
        isSendingMessage = false
        nextStreamID = 2
        chatSubscriptionID = nil
        chatDecoder = MuseNDJSONDecoder()
        let requests = pendingRequests
        pendingRequests.removeAll()
        for request in requests.values {
            request.timeout.cancel()
            request.completion(.failure(MuseRuntimeError.connectionEnded))
        }
    }

    private func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        DispatchQueue.main.async { self.onLog?(message) }
    }

    private func safeError(_ error: Error) -> String {
        String(describing: type(of: error))
    }
}

extension MuseRuntime: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        queue.async {
            guard webSocketTask === self.webSocket else { return }
            self.beginHandshake()
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        queue.async {
            guard webSocketTask === self.webSocket, self.credentials != nil else { return }
            self.fail("Muse VM closed the connection", reconnect: true)
        }
    }
}

