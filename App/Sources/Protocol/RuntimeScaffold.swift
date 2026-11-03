import Foundation
import os
import UIKit

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
        request.setValue("muse-gadget-ios/0.1.0", forHTTPHeaderField: "User-Agent")

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

    private let identity: DeviceIdentity
    private let commands: IOSCommandRegistry
    private let api: MuseAPIClient
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

    private(set) var state: MuseRuntimeState = .idle {
        didSet { DispatchQueue.main.async { self.onStateChange?(self.state) } }
    }

    init(identity: DeviceIdentity, commands: IOSCommandRegistry, api: MuseAPIClient = MuseAPIClient()) {
        self.identity = identity
        self.commands = commands
        self.api = api
        super.init()
    }

    func start(credentials: DeviceCredentials) {
        queue.async {
            self.credentials = credentials
            self.generation += 1
            self.resetConnection()
            self.fetchVM(generation: self.generation)
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

    private func fetchVM(generation: Int) {
        guard let credentials, generation == self.generation else { return }
        state = .fetchingVM
        log("Fetching the paired account's Muse VM")
        api.fetchVMs(credentials: credentials) { [weak self] result in
            self?.queue.async {
                guard let self, generation == self.generation else { return }
                switch result {
                case .success(let vms):
                    guard let vm = vms.first(where: { $0.isDefault }) ?? vms.first else {
                        self.fail("Muse returned no usable VM", reconnect: true)
                        return
                    }
                    self.connect(vm: vm, credentials: credentials, generation: generation)
                case .failure(let error):
                    self.fail("VM lookup failed: \(self.safeError(error))", reconnect: true)
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
        request.setValue("muse-gadget-ios/0.3.0", forHTTPHeaderField: "User-Agent")
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
            "display_name": UIDevice.current.name,
            "platform": "ios",
            "version": "0.3.0",
            "device_family": "homehub",
            "model_id": "iphone",
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
        let streamID: Int64
        let data: Data
        let ended: Bool
        switch frame {
        case .response(let id, let response):
            streamID = id
            guard (200..<300).contains(response.status) else {
                throw MuseWireError.malformed
            }
            data = response.body
            ended = response.endBody
        case .body(let id, let chunk):
            streamID = id
            data = chunk.data
            ended = chunk.endBody
        case .reset(_, let reason):
            throw NSError(domain: "MuseLink", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
        }
        guard streamID == 1 else { return }
        for message in try controlDecoder.feed(data) { handleControl(message) }
        if ended { throw NSError(domain: "MuseLink", code: 2) }
    }

    private func handleControl(_ message: [String: Any]) {
        if message["id"] as? String == registerID, message["method"] == nil {
            if message["error"] != nil || message["ok"] as? Bool == false {
                fail("Muse rejected link.register", reconnect: false)
            } else {
                state = .registered
                log("Registered with Muse")
                schedulePing()
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
            let body = try MuseNoiseWire.controlMessage(message)
            try sendEncrypted(MuseNoiseWire.bodyChunk(streamID: 1, data: body), completion: {})
        } catch {
            fail("Could not send link.result", reconnect: true)
        }
    }

    private func sendEncrypted(_ plaintext: Data, completion: @escaping () -> Void) throws {
        guard let transport else { throw MuseNoiseError.invalidState }
        try sendBinary(transport.encrypt(plaintext), completion: completion)
    }

    private func sendBinary(_ data: Data, completion: @escaping () -> Void) throws {
        guard let webSocket else { throw MuseNoiseError.invalidState }
        let socket = webSocket
        let sendGeneration = generation
        webSocket.send(.data(data)) { [weak self] error in
            self?.queue.async {
                guard let self, socket === self.webSocket, sendGeneration == self.generation else { return }
                if let error { self.fail("WebSocket send failed: \(self.safeError(error))", reconnect: true) }
                else { completion() }
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
        let work = DispatchWorkItem { [weak self] in
            guard let self, let socket = self.webSocket else { return }
            let pingGeneration = self.generation
            socket.sendPing { [weak self] error in
                self?.queue.async {
                    guard let self, socket === self.webSocket, pingGeneration == self.generation else { return }
                    if let error { self.fail("Muse VM ping failed: \(self.safeError(error))", reconnect: true) }
                    else { self.schedulePing() }
                }
            }
        }
        ping = work
        queue.asyncAfter(deadline: .now() + 20, execute: work)
    }

    private func fail(_ message: String, reconnect shouldReconnect: Bool) {
        log(message)
        state = .failed(message)
        resetConnection()
        guard shouldReconnect, credentials != nil else { return }
        let generation = self.generation
        let work = DispatchWorkItem { [weak self] in self?.fetchVM(generation: generation) }
        reconnect = work
        queue.asyncAfter(deadline: .now() + 3, execute: work)
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

