import AVFoundation
import Combine
import Foundation

/// A live, hands-free voice call with Muse over the gadget's Noise connection, as the SDK's
/// realtime voice client runs it: `POST /voice/realtime` with a `hatch.voice.call.start`
/// admission, 40 ms `input_audio_buffer.append` frames of 24 kHz PCM16, Muse's voice back as
/// audio deltas, and `POST /voice/end-call` at the end. Muse's server detects when the person
/// stops talking. The microphone is closed while Muse's voice plays and for 200 ms after,
/// the SDK's half-duplex default, so Muse does not hear itself on a speaker.
final class MuseVoiceCall: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case listening
        case thinking
        case speaking
        case ended(String)

        var isActive: Bool {
            switch self {
            case .connecting, .listening, .thinking, .speaking: return true
            case .idle, .ended: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    /// What Muse heard the person say last.
    @Published private(set) var heard = ""
    /// What Muse is saying, from its transcript events.
    @Published private(set) var reply = ""
    /// Content-free timing of each step, for finding where a call loses time: an event name
    /// and the milliseconds since the call started. Set by the app to its diagnostics log.
    var onTrace: ((String) -> Void)?
    private var firstAudioOfTurn = true

    @Published var isMuted = false {
        didSet { withGate { gateMuted = isMuted } }
    }

    private static let readyTimeout: TimeInterval = 40
    private static let idleTimeout: TimeInterval = 45
    private static let maxDuration: TimeInterval = 15 * 60
    private static let settle: TimeInterval = 0.2
    private static let audibleRMS: Double = 300

    private let runtime: MuseRuntime
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(MuseVoiceEvents.sampleRate),
        channels: 1,
        interleaved: false
    )!
    private let resampler = MuseVoiceResampler()
    private var lines = MuseNDJSONLines()
    private var callID = ""
    private var threadID: String?
    private var startedAt = Date()
    private var lastActivity = Date()
    private var queueEnd: TimeInterval = 0
    private var fenced = false
    private var stopRequested = false
    private var timer: Timer?
    private var engineRunning = false

    // Shared with the audio thread, under `lock`.
    private let lock = NSLock()
    private var gateStream: MuseDuplexStream?
    private var gateReady = false
    private var gateMuted = false
    private var gatePlayingUntil: TimeInterval = 0
    private var micBuffer = Data()

    init(runtime: MuseRuntime) {
        self.runtime = runtime
    }

    // MARK: Starting and ending

    func start() {
        guard !phase.isActive else { return }
        heard = ""
        reply = ""
        phase = .connecting
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard granted else {
                    self.phase = .ended(PalL10n.text("Нет доступа к микрофону. Разрешите его в настройках iOS."))
                    return
                }
                self.connect()
            }
        }
    }

    func hangUp() {
        end(PalL10n.text("Разговор завершён"))
    }

    /// Stops Muse mid-sentence. The rest of that answer is dropped until the person speaks again.
    func interrupt() {
        guard phase == .speaking else { return }
        fenced = true
        flushPlayback()
        phase = .listening
    }

    private func connect() {
        callID = UUID().uuidString.lowercased()
        threadID = nil
        startedAt = Date()
        lastActivity = Date()
        stopRequested = false
        fenced = false
        lines = MuseNDJSONLines()
        do {
            try startAudio()
        } catch {
            stopAudio()
            phase = .ended(PalL10n.text("Не удалось включить микрофон и динамик"))
            return
        }
        let admission = MuseVoiceEvents.line([
            "type": "hatch.voice.call.start",
            "call_id": callID,
            "call_media_type": "audio",
            "device": "mcu-wearable",
            "device_id": runtime.deviceNodeID,
            "proactive_greeting_enabled": false
        ]) + MuseVoiceEvents.line(["type": "hatch.voice.capability.offer", "end_call_stop": 1])

        var handlers = MuseDuplexHandlers()
        handlers.onStatus = { [weak self] status in
            guard !(200..<300).contains(status) else { return }
            DispatchQueue.main.async {
                self?.end(PalL10n.format("voice.call_refused_format", status), notify: false)
            }
        }
        handlers.onData = { [weak self] data in
            guard let self else { return }
            let records = self.lines.feed(data)
            DispatchQueue.main.async { records.forEach(self.handle) }
        }
        handlers.onClose = { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.phase.isActive else { return }
                self.end(error == nil ? PalL10n.text("Muse завершил разговор")
                                      : PalL10n.text("Связь с Muse прервалась"))
            }
        }
        runtime.openDuplexStream(
            path: "/voice/realtime?call_id=\(callID)",
            contentType: "application/x-ndjson; charset=utf-8",
            accept: "application/x-ndjson",
            firstBody: admission,
            handlers: handlers
        ) { [weak self] stream in
            guard let self else { return }
            guard let stream else {
                self.end(PalL10n.text("Muse сейчас не подключён"), notify: false)
                return
            }
            self.withGate { self.gateStream = stream }
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    private func end(_ reason: String, notify: Bool = true) {
        guard phase.isActive else { return }
        timer?.invalidate()
        timer = nil
        let stream = withGate { () -> MuseDuplexStream? in
            let stream = gateStream
            gateStream = nil
            gateReady = false
            return stream
        }
        stopAudio()
        phase = .ended(reason)
        guard notify else { stream?.cancel(); return }
        // The SDK always tells Muse the call is over, even when the stream already broke.
        var body: [String: Any] = [
            "call_id": callID,
            "call_started_at": MuseVoiceTime.rfc3339(startedAt),
            "call_ended_at": MuseVoiceTime.rfc3339(max(Date(), startedAt.addingTimeInterval(0.001)))
        ]
        if let threadID { body["thread_id"] = threadID }
        runtime.postJSON(path: "/voice/end-call", fields: body) { _ in stream?.cancel() }
    }

    private func tick() {
        let now = Date()
        if phase == .connecting, now.timeIntervalSince(startedAt) > Self.readyTimeout {
            end(PalL10n.text("Muse не ответил на звонок"))
        } else if now.timeIntervalSince(startedAt) > Self.maxDuration {
            end(PalL10n.text("Разговор длился 15 минут и завершён"))
        } else if phase == .listening, now.timeIntervalSince(lastActivity) > Self.idleTimeout {
            end(PalL10n.text("Разговор завершён после 45 секунд тишины"))
        } else if phase == .speaking, uptime() > withGate({ gatePlayingUntil }) {
            if stopRequested {
                end(PalL10n.text("Muse завершил разговор"))
            } else {
                phase = .listening
            }
        }
    }

    // MARK: Events from Muse

    private func trace(_ name: String) {
        onTrace?("\(name)@\(Int(Date().timeIntervalSince(startedAt) * 1000))")
    }

    private func handle(_ event: [String: Any]) {
        guard phase.isActive else { return }
        let type = event["type"] as? String ?? ""
        switch type {
        case "hatch.voice.session", "input_audio_buffer.speech_started", "input_audio_buffer.speech_stopped",
             "input_audio_buffer.committed", "conversation.item.input_audio_transcription.completed",
             "hatch.voice.turn_started", "hatch.voice.turn_settled", "response.created", "response.done",
             "hatch.voice.switch_input_hold", "error":
            trace(type.replacingOccurrences(of: "input_audio_buffer.", with: "mic.")
                      .replacingOccurrences(of: "conversation.item.input_audio_transcription.", with: "heard.")
                      .replacingOccurrences(of: "hatch.voice.", with: ""))
            if type == "hatch.voice.turn_started" || type == "response.created" { firstAudioOfTurn = true }
        default: break
        }
        switch type {
        case "hatch.voice.session":
            threadID = event["thread_id"] as? String
            withGate { gateReady = true }
            lastActivity = Date()
            phase = .listening
        case "error":
            let code = (event["error"] as? [String: Any])?["code"] as? String
            if phase == .connecting || code == "session_dead" {
                end(PalL10n.text("Muse не смог начать разговор"))
            }
        case "input_audio_buffer.speech_started":
            fenced = false
            lastActivity = Date()
            if phase != .speaking { phase = .listening }
        case "conversation.item.input_audio_transcription.completed":
            if let text = event["transcript"] as? String, !text.isEmpty { heard = text }
        case "hatch.voice.turn_started":
            fenced = false
            reply = ""
            lastActivity = Date()
            if phase == .listening { phase = .thinking }
        case "response.audio_transcript.delta", "response.output_audio_transcript.delta":
            if !fenced, let delta = event["delta"] as? String { reply += delta }
        case "conversation.item.added":
            let item = event["item"] as? [String: Any]
            if item?["type"] as? String == "session_control",
               (item?["name"] as? String)?.lowercased() == "stop" {
                stopRequested = true
                if phase != .speaking { end(PalL10n.text("Muse завершил разговор")) }
            }
        default:
            if let pcm = MuseVoiceEvents.audio(from: event) { play(pcm) }
        }
    }

    // MARK: Audio

    private func startAudio() throws {
        let session = AVAudioSession.sharedInstance()
        // voiceChat turns on the system's echo cancellation for the built-in mic and speaker.
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        if !engine.attachedNodes.contains(player) {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
            self?.capture(buffer)
        }
        engine.prepare()
        try engine.start()
        player.play()
        engineRunning = true
        queueEnd = 0
        withGate {
            gatePlayingUntil = 0
            gateMuted = isMuted
            micBuffer.removeAll()
        }
    }

    private func stopAudio() {
        if engineRunning {
            engine.inputNode.removeTap(onBus: 0)
            player.stop()
            engine.stop()
            engineRunning = false
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Runs on the audio thread: sends whole 40 ms frames while the microphone is open.
    private func capture(_ buffer: AVAudioPCMBuffer) {
        let pcm = resampler.convert(buffer)
        var frames: [Data] = []
        let stream: MuseDuplexStream? = withGate {
            guard let stream = gateStream, gateReady, !gateMuted, uptime() >= gatePlayingUntil else {
                // Audio captured while closed is dropped, never sent late.
                micBuffer.removeAll()
                return nil
            }
            micBuffer.append(pcm)
            while micBuffer.count >= MuseVoiceEvents.frameBytes {
                frames.append(micBuffer.prefix(MuseVoiceEvents.frameBytes))
                micBuffer.removeFirst(MuseVoiceEvents.frameBytes)
            }
            return stream
        }
        guard let stream, !frames.isEmpty else { return }
        stream.send(frames.map(MuseVoiceEvents.appendLine).reduce(Data(), +))
    }

    private func play(_ pcm: Data) {
        guard !fenced, engineRunning, !pcm.isEmpty else { return }
        let count = pcm.count / 2
        let rms = Self.rms(pcm)
        // Muse streams silence between answers; it is not worth queueing or closing the mic for.
        guard rms > 0 || uptime() < queueEnd else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<count { channel[index] = Float(Int16(littleEndian: samples[index])) / 32_768 }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
        let duration = Double(count) / Double(MuseVoiceEvents.sampleRate)
        queueEnd = max(uptime(), queueEnd) + duration
        if rms >= Self.audibleRMS {
            if firstAudioOfTurn {
                firstAudioOfTurn = false
                trace("reply_audio")
            }
            let until = queueEnd + Self.settle
            withGate { gatePlayingUntil = until; micBuffer.removeAll() }
            lastActivity = Date()
            phase = .speaking
        }
    }

    private func flushPlayback() {
        player.stop()
        player.play()
        queueEnd = 0
        withGate { gatePlayingUntil = 0 }
    }

    private static func rms(_ pcm: Data) -> Double {
        pcm.withUnsafeBytes { raw -> Double in
            let samples = raw.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return 0 }
            let sum = samples.reduce(0.0) { total, sample in
                let value = Double(Int16(littleEndian: sample))
                return total + value * value
            }
            return (sum / Double(samples.count)).squareRoot()
        }
    }

    private func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    @discardableResult
    private func withGate<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
