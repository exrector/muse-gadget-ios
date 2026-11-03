import CryptoKit
import Foundation
import Network
import os

/// What gadgets holding the same SDK token share. The token itself never leaves the device.
struct MusePeerKeys {
    let symmetric: SymmetricKey
    /// Advertised so gadgets can tell their own group apart; it reveals nothing about the token.
    let groupID: String

    init(token: String) {
        let material = SymmetricKey(data: Data(token.utf8))
        let salt = Data("muse-gadget-peer-sync-v1".utf8)
        symmetric = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: material,
            salt: salt,
            info: Data("chat-key".utf8),
            outputByteCount: 32
        )
        let group = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: material,
            salt: salt,
            info: Data("group-id".utf8),
            outputByteCount: 8
        )
        groupID = group.withUnsafeBytes { bytes in bytes.map { String(format: "%02x", $0) }.joined() }
    }
}

enum MusePeerFrameError: Error {
    case oversized
    case unreadable
}

/// Length-prefixed ChaCha20-Poly1305 frames. A replayed frame is harmless: histories merge idempotently.
struct MusePeerFrameCodec {
    static let maxFrameBytes = 4 * 1024 * 1024

    private let key: SymmetricKey
    private var buffer = Data()

    init(key: SymmetricKey) {
        self.key = key
    }

    func seal(_ payload: Data) throws -> Data {
        let sealed = try ChaChaPoly.seal(payload, using: key).combined
        guard sealed.count <= Self.maxFrameBytes else { throw MusePeerFrameError.oversized }
        var length = UInt32(sealed.count).bigEndian
        return Data(bytes: &length, count: 4) + sealed
    }

    mutating func open(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var payloads: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= Self.maxFrameBytes else { throw MusePeerFrameError.oversized }
            guard buffer.count >= 4 + length else { break }
            let frame = buffer.dropFirst(4).prefix(length)
            buffer = Data(buffer.dropFirst(4 + length))
            guard let box = try? ChaChaPoly.SealedBox(combined: frame),
                  let payload = try? ChaChaPoly.open(box, using: key) else {
                throw MusePeerFrameError.unreadable
            }
            payloads.append(payload)
        }
        return payloads
    }
}

/// Shares the chat text directly between gadgets on one Wi-Fi network, for devices that are not on
/// the same Apple ID. Works only while the app is open: iOS suspends listeners in the background.
final class MuseChatPeerSync {
    private final class Peer {
        let connection: NWConnection
        let name: String?
        var codec: MusePeerFrameCodec
        var isReady = false
        var lastSent: Data?
        var answerWatchdog: DispatchWorkItem?

        init(connection: NWConnection, name: String?, key: SymmetricKey) {
            self.connection = connection
            self.name = name
            codec = MusePeerFrameCodec(key: key)
        }
    }

    private enum PayloadType: UInt8 {
        case history = 1
        case received = 2
    }

    /// Exactly one side dials, so two gadgets never hold two connections to each other.
    static func shouldDial(local: String, remote: String) -> Bool {
        local < remote
    }

    var onHistory: ((MuseSyncedHistory) -> Void)?
    var onPeerCountChange: ((Int) -> Void)?
    var onLog: ((String) -> Void)?

    private static let maxPeers = 4
    private static let maxSnapshotBytes = 2 * 1024 * 1024
    private static let answerTimeout: TimeInterval = 8

    private let serviceName: String
    private let serviceType: String
    private let publishDelay: TimeInterval
    private let queue = DispatchQueue(label: "MuseGadgetLegacy.peerSync")
    private let logger = Logger(subsystem: "com.exrector.MuseGadgetLegacy", category: "peerSync")
    private var keys: MusePeerKeys?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var peers: [ObjectIdentifier: Peer] = [:]
    private var snapshot: Data?
    private var pendingPublish: DispatchWorkItem?
    private var retry: DispatchWorkItem?
    private var generation = 0

    init(serviceName: String, serviceType: String = "_muse-gadget._tcp", publishDelay: TimeInterval = 1) {
        self.serviceName = serviceName
        self.serviceType = serviceType
        self.publishDelay = publishDelay
    }

    func start(token: String) {
        queue.async {
            self.tearDown()
            self.generation += 1
            self.keys = MusePeerKeys(token: token)
            self.startListener()
            self.startBrowser()
        }
    }

    func stop() {
        queue.async {
            self.generation += 1
            self.tearDown()
            self.keys = nil
        }
    }

    func publish(_ items: [MuseChatItem], clearedBefore: Date?) {
        queue.async {
            self.pendingPublish?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.snapshot = MuseChatMerge.encoded(
                    items: items,
                    clearedBefore: clearedBefore,
                    maxBytes: Self.maxSnapshotBytes
                )
                self.peers.values.forEach(self.sendSnapshot)
            }
            self.pendingPublish = work
            self.queue.asyncAfter(deadline: .now() + self.publishDelay, execute: work)
        }
    }

    // MARK: - Advertising and browsing

    private static func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular]
        return parameters
    }

    private func startListener() {
        guard let keys else { return }
        do {
            let listener = try NWListener(using: Self.parameters())
            listener.service = NWListener.Service(
                name: serviceName,
                type: serviceType,
                domain: nil,
                txtRecord: NWTXTRecord(["g": keys.groupID])
            )
            let startedGeneration = generation
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, startedGeneration == self.generation else { return }
                switch state {
                case .ready: self.log("Peer sync: advertising on the local network")
                case .failed(let error):
                    self.log("Peer sync: listener failed: \(error)")
                    self.scheduleRestart()
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, startedGeneration == self.generation else {
                    connection.cancel()
                    return
                }
                self.accept(connection, name: nil)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            log("Peer sync: could not start listening: \(error)")
            scheduleRestart()
        }
    }

    private func startBrowser() {
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: serviceType, domain: nil),
            using: Self.parameters()
        )
        let startedGeneration = generation
        browser.stateUpdateHandler = { [weak self] state in
            guard let self, startedGeneration == self.generation else { return }
            if case .failed(let error) = state {
                self.log("Peer sync: browser failed: \(error)")
                self.scheduleRestart()
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, startedGeneration == self.generation else { return }
            self.dial(results)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func dial(_ results: Set<NWBrowser.Result>) {
        guard let keys else { return }
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint, name != serviceName,
                  Self.shouldDial(local: serviceName, remote: name),
                  case .bonjour(let record) = result.metadata, record["g"] == keys.groupID,
                  !peers.values.contains(where: { $0.name == name }) else { continue }
            accept(NWConnection(to: result.endpoint, using: Self.parameters()), name: name)
        }
    }

    private func scheduleRestart() {
        retry?.cancel()
        let restartGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, restartGeneration == self.generation, self.keys != nil else { return }
            self.listener?.cancel()
            self.listener = nil
            self.browser?.cancel()
            self.browser = nil
            self.startListener()
            self.startBrowser()
        }
        retry = work
        queue.asyncAfter(deadline: .now() + 5, execute: work)
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection, name: String?) {
        guard let keys, peers.count < Self.maxPeers else {
            connection.cancel()
            return
        }
        let peer = Peer(connection: connection, name: name, key: keys.symmetric)
        peers[ObjectIdentifier(peer)] = peer
        connection.stateUpdateHandler = { [weak self, weak peer] state in
            guard let self, let peer else { return }
            switch state {
            case .ready:
                peer.isReady = true
                self.log("Peer sync: connected to a gadget")
                self.reportPeerCount()
                self.receive(on: peer)
                self.sendSnapshot(to: peer)
            case .failed(let error):
                self.log("Peer sync: connection failed: \(error)")
                self.remove(peer)
            case .cancelled:
                self.remove(peer)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on peer: Peer) {
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak peer] data, _, isComplete, error in
            guard let self, let peer else { return }
            if let data, !data.isEmpty {
                do {
                    let payloads = try peer.codec.open(data)
                    if !payloads.isEmpty {
                        peer.answerWatchdog?.cancel()
                        peer.answerWatchdog = nil
                    }
                    for payload in payloads { self.handle(payload, from: peer) }
                } catch {
                    // Most often a gadget with another SDK token, whose frames this key cannot open.
                    self.log("Peer sync: dropped a connection: \(error)")
                    peer.connection.cancel()
                    return
                }
            }
            if isComplete || error != nil {
                peer.connection.cancel()
            } else {
                self.receive(on: peer)
            }
        }
    }

    private func handle(_ payload: Data, from peer: Peer) {
        // Unknown types are skipped so that an older version can talk to a newer one.
        guard let first = payload.first, PayloadType(rawValue: first) == .history,
              let history = MuseChatMerge.decoded(Data(payload.dropFirst())) else { return }
        log("Peer sync: received \(history.messages.count) messages")
        send(Data([PayloadType.received.rawValue]), to: peer)
        DispatchQueue.main.async { self.onHistory?(history) }
    }

    private func sendSnapshot(to peer: Peer) {
        guard peer.isReady, let snapshot, snapshot != peer.lastSent else { return }
        guard send(Data([PayloadType.history.rawValue]) + snapshot, to: peer) else { return }
        peer.lastSent = snapshot
        watchForAnswer(from: peer)
    }

    @discardableResult
    private func send(_ payload: Data, to peer: Peer) -> Bool {
        guard let keys else { return false }
        do {
            let frame = try MusePeerFrameCodec(key: keys.symmetric).seal(payload)
            peer.connection.send(content: frame, completion: .contentProcessed { [weak peer] error in
                if error != nil { peer?.connection.cancel() }
            })
            return true
        } catch {
            log("Peer sync: could not encode a message: \(error)")
            return false
        }
    }

    /// A connection can look ready while nothing crosses it. An unanswered history closes it, and the
    /// dialing side connects again and resends, since a new connection starts with no `lastSent`.
    private func watchForAnswer(from peer: Peer) {
        guard peer.answerWatchdog == nil else { return }
        let work = DispatchWorkItem { [weak self, weak peer] in
            guard let peer else { return }
            self?.log("Peer sync: no answer from a gadget, reconnecting")
            peer.connection.cancel()
        }
        peer.answerWatchdog = work
        queue.asyncAfter(deadline: .now() + Self.answerTimeout, execute: work)
    }

    private func remove(_ peer: Peer) {
        guard peers.removeValue(forKey: ObjectIdentifier(peer)) != nil else { return }
        peer.answerWatchdog?.cancel()
        peer.connection.stateUpdateHandler = nil
        reportPeerCount()
        guard keys != nil else { return }
        // The gadget may still be there, so look again rather than waiting for a browse change.
        let retryGeneration = generation
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, retryGeneration == self.generation, let results = self.browser?.browseResults else { return }
            self.dial(results)
        }
    }

    private func tearDown() {
        retry?.cancel()
        retry = nil
        pendingPublish?.perform()
        pendingPublish?.cancel()
        pendingPublish = nil
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        let current = peers.values
        peers.removeAll()
        for peer in current {
            peer.answerWatchdog?.cancel()
            peer.connection.stateUpdateHandler = nil
            peer.connection.cancel()
        }
        reportPeerCount()
    }

    private func reportPeerCount() {
        let count = peers.values.filter(\.isReady).count
        DispatchQueue.main.async { self.onPeerCountChange?(count) }
    }

    private func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        DispatchQueue.main.async { self.onLog?(message) }
    }
}
