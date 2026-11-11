#if DEBUG
import Foundation
import Network

/// DEBUG-only device check for steps 1 and 2 of Docs/VIDEO-CALLS-PLAN.md: does Muse admit this
/// gadget to a video call (media endpoint and JOIN), and which transport reaches the media
/// endpoint (an ICE-lite STUN check over UDP and RFC 4571 TCP at once, as the SDK's
/// rtc/media.py does). Started by PAL_V2_VIDEO_PROBE=1 once registered; the call is always
/// ended. Writes Documents/v2-video-probe.json with status codes, field names, transports and
/// round trips, never keys, passwords or credentials.
private func json(_ value: Any?) -> Any { value ?? NSNull() }

final class MuseVideoProbe {
    static let shared = MuseVideoProbe()

    private var result: [String: Any] = [:]
    private var running = false
    private let queue = DispatchQueue(label: "MuseGadgetLegacy.videoProbe")
    private var connections: [NWConnection] = []

    func run(runtime: MuseRuntime) {
        DispatchQueue.main.async {
            guard !self.running else { return }
            self.running = true
            self.result = ["started_at": MuseVoiceTime.rfc3339(Date())]
            self.stage("media_endpoint")
            runtime.requestJSON(method: "GET", path: "/voice/calls/media-endpoint") { response in
                self.mediaEndpoint(runtime: runtime, response: response)
            }
        }
    }

    private func mediaEndpoint(runtime: MuseRuntime, response: Result<(status: Int, body: Data), Error>) {
        guard case .success(let reply) = response else {
            finish(runtime: runtime, callID: nil, note: "media endpoint failed: \(response)")
            return
        }
        let root = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any]
        let endpoint = root?["result"] as? [String: Any]
        result["media_endpoint"] = [
            "status": reply.status,
            "ok": json(root?["ok"]),
            "keys": endpoint?.keys.sorted() ?? [],
            "vip_type": json(endpoint?["vip_type"]),
            "port": json(endpoint?["port"]),
            "host": json(endpoint?["host"]),
            "error": endpoint == nil ? String(decoding: reply.body.prefix(300), as: UTF8.self) : ""
        ]
        guard let host = endpoint?["host"] as? String, !host.isEmpty,
              let port = endpoint?["port"] as? Int, (1...65_535).contains(port),
              let vip = endpoint?["vip_type"] as? String,
              let vipCode = MuseCallJoinOffer.endpointTypes[vip] else {
            finish(runtime: runtime, callID: nil, note: "no usable media endpoint")
            return
        }
        stage("join")
        let offer = MuseCallJoinOffer.make(threadID: nil, edgeHost: host, edgePort: port, vipType: vipCode, video: true)
        let callID = UUID().uuidString.lowercased()
        let startedAt = Date()
        let body: [String: Any] = [
            "payload_b64": offer.payload.base64EncodedString(),
            "call_id": callID,
            "call_media_type": "video",
            "device": "mcu-wearable",
            "device_id": runtime.deviceNodeID,
            "proactive_greeting_enabled": false,
            "enable_media_to_cosmos": (endpoint?["enable_media_to_cosmos"] as? Bool) ?? false
        ]
        result["join_payload_bytes"] = offer.payload.count
        runtime.postJSON(path: "/voice/calls/join", fields: body) { response in
            guard case .success(let reply) = response else {
                self.finish(runtime: runtime, callID: callID, startedAt: startedAt, note: "join failed: \(response)")
                return
            }
            let root = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any]
            let joined = root?["result"] as? [String: Any]
            var join: [String: Any] = [
                "status": reply.status,
                "ok": json(root?["ok"]),
                "keys": joined?.keys.sorted() ?? []
            ]
            if joined == nil { join["error"] = String(decoding: reply.body.prefix(300), as: UTF8.self) }
            guard let encoded = joined?["payload_b64"] as? String, let payload = Data(base64Encoded: encoded) else {
                self.result["join"] = join
                self.finish(runtime: runtime, callID: callID, startedAt: startedAt, note: "no JOIN answer")
                return
            }
            do {
                let answer = try MuseCallJoinAnswer.parse(payload)
                join["answer"] = [
                    "status": json(answer.status),
                    "server_ufrag_length": answer.serverUfrag.count,
                    "has_ipv4": !answer.ipv4.isEmpty,
                    "has_ipv6": !answer.ipv6.isEmpty
                ]
                self.result["join"] = join
                self.stage("connectivity")
                self.checkConnectivity(offer: offer, answer: answer, host: host, port: port) { connectivity in
                    self.result["connectivity"] = connectivity
                    self.finish(runtime: runtime, callID: callID, startedAt: startedAt, note: "done")
                }
            } catch {
                join["parse_error"] = "\(error)"
                self.result["join"] = join
                self.finish(runtime: runtime, callID: callID, startedAt: startedAt, note: "JOIN answer unreadable")
            }
        }
    }

    // MARK: Connectivity

    /// Races STUN checks over UDP and TCP to every address, as MediaSession.connect does, and
    /// reports the first authenticated answer on each transport.
    private func checkConnectivity(offer: MuseCallJoinOffer, answer: MuseCallJoinAnswer, host: String, port: Int,
                                   completion: @escaping ([String: Any]) -> Void) {
        let username = "\(answer.serverUfrag):\(offer.clientUfrag)"
        let tieBreaker = UInt64.random(in: 0...UInt64.max)
        var targets: [String] = []
        if !answer.ipv4.isEmpty { targets.append(answer.ipv4) }
        if !answer.ipv6.isEmpty { targets.append(answer.ipv6) }
        targets.append(host)
        var pending: [Data: (path: String, sent: Date)] = [:]
        var firstAnswer: [String: Int] = [:]
        var states: [String: String] = [:]
        var sentChecks: [String: Int] = [:]
        let started = Date()
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { completion(["error": "bad port"]); return }

        func record(_ path: String, _ data: Data) {
            guard MuseSTUN.isSTUN(data) else { return }
            let id = data.count >= 20 ? Data(data[data.startIndex.advanced(by: 8)..<data.startIndex.advanced(by: 20)]) : Data()
            guard let sent = pending[id], sent.path == path,
                  MuseSTUN.isSuccess(data, transactionID: id, password: offer.serverPassword) else { return }
            pending[id] = nil
            if firstAnswer[path] == nil { firstAnswer[path] = Int(Date().timeIntervalSince(sent.sent) * 1000) }
        }

        func check(_ path: String, send: @escaping (Data) -> Void) {
            let priority: UInt32 = (path.hasPrefix("udp") ? 110 : 90) << 24 | 0xFFFF << 8 | 255
            let request = MuseSTUN.bindingRequest(username: username, password: offer.serverPassword,
                                                  priority: priority, tieBreaker: tieBreaker, nominate: false)
            pending[request.transactionID] = (path, Date())
            sentChecks[path, default: 0] += 1
            send(request.packet)
        }

        var senders: [String: (Data) -> Void] = [:]
        for (index, target) in targets.enumerated() {
            let endpointHost = NWEndpoint.Host(target)
            // UDP
            let udpName = "udp\(index):\(target.contains(":") ? "v6" : (index == targets.count - 1 ? "name" : "v4"))"
            let udp = NWConnection(host: endpointHost, port: nwPort, using: .udp)
            udp.stateUpdateHandler = { state in self.queue.async { states[udpName] = "\(state)" } }
            func receiveUDP() {
                udp.receiveMessage { data, _, _, error in
                    if let data { self.queue.async { record(udpName, data) } }
                    if error == nil { receiveUDP() }
                }
            }
            receiveUDP()
            udp.start(queue: queue)
            connections.append(udp)
            senders[udpName] = { packet in udp.send(content: packet, completion: .contentProcessed { _ in }) }
            // TCP, RFC 4571: a 16-bit length before each packet.
            let tcpName = udpName.replacingOccurrences(of: "udp", with: "tcp")
            let tcp = NWConnection(host: endpointHost, port: nwPort, using: .tcp)
            tcp.stateUpdateHandler = { state in self.queue.async { states[tcpName] = "\(state)" } }
            func receiveTCP() {
                tcp.receive(minimumIncompleteLength: 2, maximumLength: 2) { header, _, _, error in
                    guard let header, header.count == 2, error == nil else { return }
                    let size = Int(header[header.startIndex]) << 8 | Int(header[header.startIndex + 1])
                    tcp.receive(minimumIncompleteLength: size, maximumLength: size) { body, _, _, error in
                        if let body { self.queue.async { record(tcpName, body) } }
                        if error == nil { receiveTCP() }
                    }
                }
            }
            receiveTCP()
            tcp.start(queue: queue)
            connections.append(tcp)
            senders[tcpName] = { packet in
                tcp.send(content: MuseSTUN.be16(UInt16(packet.count)) + packet, completion: .contentProcessed { _ in })
            }
        }

        // Checks every 200 ms on every path for up to 10 s, as the SDK's CHECK_INTERVAL.
        func tick() {
            if Date().timeIntervalSince(started) > 10 || firstAnswer.count == senders.count {
                let report: [String: Any] = [
                    "first_answer_ms": firstAnswer,
                    "checks_sent": sentChecks,
                    "states": states,
                    "targets": targets.count
                ]
                connections.forEach { $0.cancel() }
                connections.removeAll()
                DispatchQueue.main.async { completion(report) }
                return
            }
            for (path, send) in senders { check(path, send: send) }
            queue.asyncAfter(deadline: .now() + 0.2) { tick() }
        }
        queue.asyncAfter(deadline: .now() + 0.3) { tick() }
    }

    // MARK: Finishing

    private func finish(runtime: MuseRuntime, callID: String?, startedAt: Date = Date(), note: String) {
        result["end"] = note
        guard let callID else { done(); return }
        stage("end_call")
        let body: [String: Any] = [
            "call_id": callID,
            "call_started_at": MuseVoiceTime.rfc3339(startedAt),
            "call_ended_at": MuseVoiceTime.rfc3339(max(Date(), startedAt.addingTimeInterval(0.001)))
        ]
        runtime.postJSON(path: "/voice/end-call", fields: body) { response in
            switch response {
            case .success(let reply): self.result["end_call_status"] = reply.status
            case .failure(let error): self.result["end_call_error"] = "\(error)"
            }
            self.done()
        }
    }

    private func done() {
        result["finished_at"] = MuseVoiceTime.rfc3339(Date())
        stage("done")
        running = false
    }


    private func stage(_ name: String) {
        result["stage"] = name
        NSLog("PalVideoProbe stage: %@", name)
        guard JSONSerialization.isValidJSONObject(result),
              let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
              let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? data.write(to: directory.appendingPathComponent("v2-video-probe.json"), options: .atomic)
    }
}
#endif
