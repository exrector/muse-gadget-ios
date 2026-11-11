#if DEBUG
import AVFoundation
import Foundation

/// DEBUG-only device check for the SDK's two voice routes before any UI is built on them:
/// streaming dictation (`/api/voice/dictation`) and a live voice call (`/voice/realtime`).
/// It speaks a fixed English sentence with the iOS synthesizer, sends that audio, and writes
/// what came back to Documents/v2-realtime-probe.json: status codes, event types, counts and
/// the transcript of the probe's own sentence. It stores no tokens and no reply text.
final class MuseVoiceProbe {
    static let shared = MuseVoiceProbe()

    private static let phrase = "Hello Muse. What is two plus two?"
    private let synthesizer = AVSpeechSynthesizer()
    private var result: [String: Any] = ["started_at": ISO8601DateFormatter().string(from: Date())]
    private var running = false

    func run(runtime: MuseRuntime) {
        DispatchQueue.main.async {
            guard !self.running else { return }
            self.running = true
            self.stage("started")
            var rendered = false
            // The synthesizer has been seen to never call back; fall back after a few seconds.
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                guard !rendered else { return }
                rendered = true
                self.stage("speech_timed_out")
                self.result["speech_bytes"] = 0
                self.continueProbe(runtime: runtime, pcm: Self.tone())
            }
            MuseSpeechPCM.render(Self.phrase, with: self.synthesizer) { pcm in
                guard !rendered else { return }
                rendered = true
                self.stage("speech_ready")
                self.result["speech_bytes"] = pcm.count
                self.continueProbe(runtime: runtime, pcm: pcm.isEmpty ? Self.tone() : pcm)
            }
        }
    }

    private func continueProbe(runtime: MuseRuntime, pcm: Data) {
        stage("dictation")
        probeDictation(runtime: runtime, pcm: pcm) {
            self.stage("call")
            self.probeCall(runtime: runtime, pcm: pcm) {
                self.stage("done")
                self.result["finished_at"] = ISO8601DateFormatter().string(from: Date())
                self.save()
                self.running = false
            }
        }
    }

    private func stage(_ name: String) {
        result["stage"] = name
        NSLog("PalVoiceProbe stage: %@", name)
        save()
    }

    /// Two seconds of a 440 Hz tone: no words, but enough to see whether a route accepts audio.
    private static func tone() -> Data {
        var data = Data(capacity: 24_000 * 2 * 2)
        for index in 0..<(24_000 * 2) {
            let sample = Int16(8_000 * sin(2 * Double.pi * 440 * Double(index) / 24_000))
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    // MARK: Dictation

    private func probeDictation(runtime: MuseRuntime, pcm: Data, done: @escaping () -> Void) {
        var report: [String: Any] = [:]
        var types: [String: Int] = [:]
        var lines = MuseNDJSONLines()
        var finished = false
        let started = Date()
        func finish(_ note: String?) {
            guard !finished else { return }
            finished = true
            if let note { report["end"] = note }
            report["types"] = types
            report["ms"] = Int(Date().timeIntervalSince(started) * 1000)
            self.result["dictation"] = report
            self.save()
            done()
        }
        var handlers = MuseDuplexHandlers()
        handlers.onStatus = { status in DispatchQueue.main.async { report["status"] = status } }
        handlers.onData = { data in
            let records = lines.feed(data)
            let raw = String(decoding: data.prefix(400), as: UTF8.self)
            DispatchQueue.main.async {
                if report["first_body"] == nil { report["first_body"] = raw }
                for record in records {
                    let type = record["type"] as? String ?? "?"
                    types[type, default: 0] += 1
                    if type == "final" || type == "partial", let text = record["text"] as? String {
                        report["last_\(type)"] = text
                    }
                    if type == "error" { report["error_code"] = (record["error"] as? [String: Any])?["code"] ?? record["code"] ?? "?" }
                }
            }
        }
        handlers.onClose = { error in
            DispatchQueue.main.async { finish(error.map { "closed: \($0)" } ?? "server finished") }
        }
        runtime.openDuplexStream(
            path: "/api/voice/dictation?sample_rate_hz=24000",
            accept: "application/x-ndjson",
            handlers: handlers
        ) { stream in
            guard let stream else { finish("not connected"); return }
            self.stream(pcm, chunk: 8_192, to: stream, raw: true) {
                stream.send(Data(), end: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                    stream.cancel()
                    finish("timed out after half-close")
                }
            }
        }
    }

    // MARK: Live call

    private func probeCall(runtime: MuseRuntime, pcm: Data, done: @escaping () -> Void) {
        var report: [String: Any] = [:]
        var types: [String: Int] = [:]
        var lines = MuseNDJSONLines()
        var audioBytes = 0
        var finished = false
        var stream: MuseDuplexStream?
        var threadID: String?
        let callID = UUID().uuidString.lowercased()
        let startedAt = Date()
        func finish(_ note: String) {
            guard !finished else { return }
            finished = true
            report["end"] = note
            report["types"] = types
            report["reply_audio_ms"] = audioBytes * 1000 / (24_000 * 2)
            report["ms"] = Int(Date().timeIntervalSince(startedAt) * 1000)
            var end: [String: Any] = [
                "call_id": callID,
                "call_started_at": MuseVoiceTime.rfc3339(startedAt),
                "call_ended_at": MuseVoiceTime.rfc3339(Date())
            ]
            if let threadID { end["thread_id"] = threadID }
            runtime.postJSON(path: "/voice/end-call", fields: end) { response in
                switch response {
                case .success(let reply): report["end_call_status"] = reply.status
                case .failure(let error): report["end_call_error"] = "\(error)"
                }
                stream?.cancel()
                self.result["call"] = report
                self.save()
                done()
            }
        }
        var handlers = MuseDuplexHandlers()
        handlers.onStatus = { status in DispatchQueue.main.async { report["status"] = status } }
        handlers.onData = { data in
            let records = lines.feed(data)
            let raw = String(decoding: data.prefix(400), as: UTF8.self)
            DispatchQueue.main.async {
                if report["first_body"] == nil { report["first_body"] = raw }
                for record in records {
                    let type = record["type"] as? String ?? "?"
                    types[type, default: 0] += 1
                    if let pcm = MuseVoiceEvents.audio(from: record) { audioBytes += pcm.count }
                    switch type {
                    case "hatch.voice.session":
                        threadID = record["thread_id"] as? String
                        report["ready_ms"] = Int(Date().timeIntervalSince(startedAt) * 1000)
                        if let stream { self.stream(pcm, chunk: 1_920, to: stream, raw: false) {
                            self.streamSilence(seconds: 3, to: stream) {}
                        } }
                    case "conversation.item.input_audio_transcription.completed":
                        report["heard"] = record["transcript"] as? String
                    case "error":
                        report["error_code"] = (record["error"] as? [String: Any])?["code"] ?? "?"
                    default: break
                    }
                }
            }
        }
        handlers.onClose = { error in
            DispatchQueue.main.async { finish(error.map { "closed: \($0)" } ?? "server finished") }
        }
        let admission = [
            ["type": "hatch.voice.call.start", "call_id": callID, "call_media_type": "audio",
             "device": "mcu-wearable", "device_id": runtime.deviceNodeID, "proactive_greeting_enabled": false],
            ["type": "hatch.voice.capability.offer", "end_call_stop": 1]
        ].compactMap { try? JSONSerialization.data(withJSONObject: $0) }
            .reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
        runtime.openDuplexStream(
            path: "/voice/realtime?call_id=\(callID)",
            contentType: "application/x-ndjson; charset=utf-8",
            accept: "application/x-ndjson",
            firstBody: admission,
            handlers: handlers
        ) { opened in
            guard let opened else { finish("not connected"); return }
            stream = opened
            DispatchQueue.main.asyncAfter(deadline: .now() + 40) { finish("probe window over") }
        }
    }

    // MARK: Sending audio

    /// Paces audio like a live microphone. `raw` sends PCM bytes (dictation), otherwise
    /// `input_audio_buffer.append` lines of 960 samples (a call).
    private func stream(_ pcm: Data, chunk: Int, to stream: MuseDuplexStream, raw: Bool, done: @escaping () -> Void) {
        var offset = 0
        func next() {
            guard offset < pcm.count else { done(); return }
            let end = min(offset + chunk, pcm.count)
            let piece = pcm.subdata(in: offset..<end)
            offset = end
            stream.send(raw ? piece : MuseVoiceEvents.appendLine(piece))
            let seconds = Double(piece.count) / Double(24_000 * 2)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { next() }
        }
        next()
    }

    private func streamSilence(seconds: Double, to stream: MuseDuplexStream, done: @escaping () -> Void) {
        let frames = Int(seconds / 0.04)
        self.stream(Data(count: frames * 1_920), chunk: 1_920, to: stream, raw: false, done: done)
    }

    private func save() {
        guard JSONSerialization.isValidJSONObject(result),
              let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
              let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? data.write(to: directory.appendingPathComponent("v2-realtime-probe.json"), options: .atomic)
    }
}
#endif
