// Ported from the Muse Gadget SDK, branch anantn/linux-video-calls (commit 77c7e27),
// linux/src/musegadget/rtc/media.py. Copyright (c) Meta Platforms, Inc. and affiliates.
// Licensed under the Apache License, Version 2.0.

import Foundation
import Network

/// Call media over ICE-lite: UDP with ICE-TCP (RFC 4571) as the fallback on the same port, SRTP,
/// RTP. Everything runs on one private queue; callbacks arrive on it too.
final class MuseMediaSession {
    static let opusPayloadType: UInt8 = 111
    static let h264PayloadType: UInt8 = 127
    static let clientAudioSSRC: UInt32 = 100
    static let clientVideoSSRC: UInt32 = 101
    static let serverAudioSSRC: UInt32 = 200
    static let serverVideoSSRC: UInt32 = 201
    private static let checkInterval: TimeInterval = 0.2
    private static let consentInterval: TimeInterval = 4
    private static let consentTimeout: TimeInterval = 30
    private static let checkResponseWindow: TimeInterval = 5

    struct Stats {
        var transport = ""
        var bytesIn = 0
        var rtpAudio = 0
        var rtpVideo = 0
        var rtcp = 0
        var srtpErrors = 0
        var decodeErrors = 0
        var lateAudio = 0
        var audioSent = 0
        var videoUnits = 0
    }

    private final class Path {
        let kind: String
        let connection: NWConnection
        let framed: Bool

        init(kind: String, connection: NWConnection, framed: Bool) {
            self.kind = kind
            self.connection = connection
            self.framed = framed
        }

        func send(_ data: Data) {
            let packet = framed ? MuseSTUN.be16(UInt16(data.count)) + data : data
            connection.send(content: packet, completion: .contentProcessed { _ in })
        }
    }

    /// Mono 48 kHz PCM16 decoded from Muse's Opus packets.
    var onAudio: ((Data) -> Void)?
    /// Muse's video: the NAL units of each complete H.264 access unit.
    var onVideo: (([Data]) -> Void)?
    /// Connectivity was lost: no consent answers for 30 s, or the chosen TCP path closed.
    var onLost: (() -> Void)?
    let queue = DispatchQueue(label: "MuseGadgetLegacy.media", qos: .userInteractive)
    private(set) var stats = Stats()
    private(set) var lastMedia = Date()

    private let offer: MuseCallJoinOffer
    private let answer: MuseCallJoinAnswer
    private let host: String
    private let port: UInt16
    private let srtp: MuseSRTPSession
    private let username: String
    private let tieBreaker = UInt64.random(in: 0...UInt64.max)
    private var paths: [Path] = []
    private var pending: [Data: (path: Path, sent: Date)] = [:]
    private var selected: Path?
    private var connected: ((String?) -> Void)?
    private let h264 = MuseH264Depacketizer()
    private var decoder: MuseOpusDecoder?
    private var encoder: MuseOpusEncoder?
    private var sequence = UInt16.random(in: 0...UInt16.max)
    private var timestamp = UInt32.random(in: 0...UInt32.max)
    private var audioSequence: UInt16?
    private var lastConsent = Date()
    private var lastPLI = Date.distantPast
    private var closed = false

    init(offer: MuseCallJoinOffer, answer: MuseCallJoinAnswer, host: String, port: Int) throws {
        self.offer = offer
        self.answer = answer
        self.host = host
        self.port = UInt16(port)
        srtp = try MuseSRTPSession(keyAndSalt: offer.srtpKey)
        username = "\(answer.serverUfrag):\(offer.clientUfrag)"
        decoder = try MuseOpusDecoder()
        encoder = try MuseOpusEncoder()
    }

    /// Races the checks on every path and completes with the winning transport, or nil after `timeout`.
    func connect(timeout: TimeInterval = 10, completion: @escaping (String?) -> Void) {
        queue.async {
            self.connected = completion
            var targets: [String] = []
            if !self.answer.ipv4.isEmpty { targets.append(self.answer.ipv4) }
            if !self.answer.ipv6.isEmpty { targets.append(self.answer.ipv6) }
            targets.append(self.host)
            guard let nwPort = NWEndpoint.Port(rawValue: self.port) else { self.finishConnect(nil); return }
            for target in targets {
                let endpoint = NWEndpoint.Host(target)
                self.open(Path(kind: "udp", connection: NWConnection(host: endpoint, port: nwPort, using: .udp), framed: false))
                self.open(Path(kind: "tcp", connection: NWConnection(host: endpoint, port: nwPort, using: .tcp), framed: true))
            }
            self.runChecks()
            self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.selected == nil else { return }
                self.finishConnect(nil)
            }
        }
    }

    /// Sends 20 ms of mono 48 kHz PCM16 as one Opus packet.
    func sendAudio(_ pcm: Data) {
        queue.async {
            guard !self.closed, let path = self.selected, let encoder = self.encoder,
                  let opus = try? encoder.encode(pcm) else { return }
            let packet = MuseRTPPacket.build(payloadType: Self.opusPayloadType, sequence: self.sequence,
                                             timestamp: self.timestamp, ssrc: Self.clientAudioSSRC, payload: opus)
            self.sequence &+= 1
            self.timestamp &+= MuseOpus.frameSamples
            if let protected = try? self.srtp.protectRTP(packet) {
                path.send(protected)
                self.stats.audioSent += 1
            }
        }
    }

    func requestKeyframe() {
        queue.async {
            guard !self.closed, Date().timeIntervalSince(self.lastPLI) >= 1, let path = self.selected,
                  let pli = try? self.srtp.protectRTCP(MuseRTPPacket.pictureLossIndication(
                      sender: Self.clientVideoSSRC, media: Self.serverVideoSSRC)) else { return }
            self.lastPLI = Date()
            path.send(pli)
        }
    }

    func close() {
        queue.async {
            self.closed = true
            self.paths.forEach { $0.connection.cancel() }
            self.paths.removeAll()
            self.selected = nil
            self.encoder = nil
            self.decoder = nil
        }
    }

    // MARK: Paths

    private func open(_ path: Path) {
        paths.append(path)
        path.connection.start(queue: queue)
        receive(on: path)
    }

    private func receive(on path: Path) {
        if path.framed {
            path.connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { [weak self] header, _, _, error in
                guard let self, let header, header.count == 2, error == nil else { self?.pathClosed(path); return }
                let size = Int(header[header.startIndex]) << 8 | Int(header[header.startIndex + 1])
                path.connection.receive(minimumIncompleteLength: size, maximumLength: size) { [weak self] body, _, _, error in
                    guard let self, let body, error == nil else { self?.pathClosed(path); return }
                    self.handle(body, on: path)
                    self.receive(on: path)
                }
            }
        } else {
            path.connection.receiveMessage { [weak self] data, _, _, error in
                guard let self else { return }
                if let data { self.handle(data, on: path) }
                if error == nil, !self.closed { self.receive(on: path) }
            }
        }
    }

    private func pathClosed(_ path: Path) {
        guard !closed, path === selected else { return }
        selected = nil
        onLost?()
    }

    private func check(_ path: Path, nominate: Bool = false) {
        let priority: UInt32 = (path.kind == "udp" ? 110 : 90) << 24 | 0xFFFF << 8 | 255
        let request = MuseSTUN.bindingRequest(username: username, password: offer.serverPassword,
                                              priority: priority, tieBreaker: tieBreaker, nominate: nominate)
        pending[request.transactionID] = (path, Date())
        if pending.count > 64, let oldest = pending.min(by: { $0.value.sent < $1.value.sent })?.key { pending[oldest] = nil }
        path.send(request.packet)
    }

    private func runChecks() {
        guard selected == nil, !closed, connected != nil else { return }
        paths.forEach { check($0) }
        queue.asyncAfter(deadline: .now() + Self.checkInterval) { [weak self] in self?.runChecks() }
    }

    private func finishConnect(_ transport: String?) {
        guard let completion = connected else { return }
        connected = nil
        if let transport, let selected {
            // Racing checks only test paths; nominate the one that won and drop the rest.
            for path in paths where path !== selected { path.connection.cancel() }
            paths = [selected]
            stats.transport = transport
            lastMedia = Date()
            lastConsent = Date()
            check(selected, nominate: true)
            scheduleConsent()
        } else {
            paths.forEach { $0.connection.cancel() }
            paths.removeAll()
        }
        DispatchQueue.main.async { completion(transport) }
    }

    private func scheduleConsent() {
        queue.asyncAfter(deadline: .now() + Self.consentInterval) { [weak self] in
            guard let self, !self.closed else { return }
            guard let selected = self.selected, Date().timeIntervalSince(self.lastConsent) <= Self.consentTimeout else {
                self.selected = nil
                self.onLost?()
                return
            }
            self.check(selected, nominate: true)
            self.scheduleConsent()
        }
    }

    // MARK: Receiving

    private func handle(_ data: Data, on path: Path) {
        guard !closed else { return }
        stats.bytesIn += data.count
        if MuseSTUN.isSTUN(data) {
            let id = Data(data[data.startIndex.advanced(by: 8)..<data.startIndex.advanced(by: 20)])
            guard let sent = pending[id], sent.path === path,
                  Date().timeIntervalSince(sent.sent) <= Self.checkResponseWindow,
                  MuseSTUN.isSuccess(data, transactionID: id, password: offer.serverPassword) else { return }
            pending[id] = nil
            if path === selected { lastConsent = Date() }
            if selected == nil {
                selected = path
                finishConnect(path.kind)
            }
            return
        }
        guard path === selected, data.count >= 12 else { return }
        if MuseRTPPacket.isRTCP(data) {
            // The endpoint's reports carry nothing this client acts on.
            stats.rtcp += 1
            return
        }
        // Media only from the endpoint's two streams; that also drops our own reflected packets.
        let bytes = [UInt8](data.prefix(12))
        let ssrc = MuseSTUN.read32(bytes, 8)
        guard ssrc == Self.serverAudioSSRC || ssrc == Self.serverVideoSSRC else { return }
        guard let packet = try? MuseRTPPacket.parse(try srtp.unprotectRTP(data)) else {
            stats.srtpErrors += 1
            return
        }
        lastMedia = Date()
        switch packet.payloadType {
        case Self.opusPayloadType:
            stats.rtpAudio += 1
            // Over UDP a packet can arrive after a later one; play in order by dropping it.
            if let last = audioSequence, (packet.sequence &- last) >= 0x8000 {
                stats.lateAudio += 1
                return
            }
            audioSequence = packet.sequence
            guard let decoder, let pcm = try? decoder.decode(packet.payload) else {
                stats.decodeErrors += 1
                return
            }
            onAudio?(pcm)
        case Self.h264PayloadType:
            stats.rtpVideo += 1
            let unit = h264.push(packet)
            // Drops resume at a keyframe, asked for with a PLI at most once a second.
            if h264.needsKeyframe { requestKeyframe() }
            if let unit {
                stats.videoUnits += 1
                onVideo?(unit)
            }
        default:
            break
        }
    }
}
