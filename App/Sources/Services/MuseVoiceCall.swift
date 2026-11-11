import AVFoundation
import Combine
import Foundation

/// A live, hands-free voice call with Muse over the gadget's Noise connection, as the SDK's
/// realtime voice client runs it: `POST /voice/realtime` with a `hatch.voice.call.start`
/// admission, 40 ms `input_audio_buffer.append` frames of 24 kHz PCM16, Muse's voice back as
/// audio deltas, and `POST /voice/end-call` at the end. Muse's server detects when the person
/// stops talking. As in the SDK's hands-free call, the microphone sends raw audio and is closed
/// while Muse's voice plays, plus the speaker's lag and a short tail, so Muse does not hear
/// itself; replies wait for 600 ms of audio before playing, like the SDK's voice player.
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
    /// True while Muse is answering, for the talking animation: from the first sound of a reply
    /// until Muse's server says that reply's audio is done and the player has played it all.
    /// A stall in delivery mid-sentence does not end it, so the animation does not restart.
    @Published private(set) var isVoiceAudible = false
    private var replyAudioOpen = false
    private var videoSeen = 0
    private var videoBytes = 0
    /// DEBUG only: PAL_CALL_MEDIA_TYPE asks Muse for another media type, to see what
    /// continuous_audio_video.delta's video_delta carries. The SDK always asks for audio.
    private static var callMediaType: String {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["PAL_CALL_MEDIA_TYPE"], !value.isEmpty { return value }
        #endif
        return "audio"
    }
    private var replyHeard = false
    /// True from Muse's server hearing the person start to speak until it hears them stop.
    @Published private(set) var isUserSpeaking = false
    /// False until Muse has greeted or answered: before that its server drops what it hears.
    @Published private(set) var isMuseReady = false
    /// Set for a few seconds when Muse's server dropped a sentence (hatch.voice.input_suppressed).
    @Published private(set) var missedSentence = false
    private var missedReset: DispatchWorkItem?
    private static let readyFallback: TimeInterval = 20
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
    /// The SDK's CALL_SPEAKER_LAG_US: sound leaves the speaker this long after it is queued.
    private static let speakerLag: TimeInterval = 0.12
    private static let audibleRMS: Double = 300
    /// Audio collected before playback starts, so uneven delivery does not cut words: the SDK's
    /// voice player waits for 600 ms (PREBUFFER_BYTES in esp32/main/voice_player.c).
    private static let prebuffer: TimeInterval = 0.6
    private var underruns = 0
    /// How long a reply waits for Muse's server before the call gives up on connecting.
    private static let connectWait: TimeInterval = 15
    private var connectAttemptsUntil = Date()
    private static let speakingSettle: TimeInterval = 1.0
    private var audibleSpans: [(start: TimeInterval, end: TimeInterval)] = []

    private let runtime: MuseRuntime
    private var media: MuseMediaSession?
    /// Muse's own video in a media call: its avatar, talking in sync, drawn by the server.
    let video = MuseVideoRenderer()
    @Published private(set) var hasVideo = false
    /// Width over height of Muse's video, so its window has no bars.
    @Published private(set) var videoAspect: CGFloat = 9.0 / 16.0
    static let videoCallsKey = "videoCallsWithAvatar"
    private static let mediaTimeout: TimeInterval = 10
    /// The "Video with Muse's avatar (Beta)" setting, on unless turned off: a call over the
    /// video-call media path, with Muse's own video. Off keeps the realtime voice call.
    static var usesMedia: Bool {
        #if DEBUG
        if let forced = ProcessInfo.processInfo.environment["PAL_CALL_TRANSPORT"] { return forced == "media" }
        #endif
        return UserDefaults.standard.object(forKey: videoCallsKey) as? Bool ?? true
    }

    /// Fixed for the length of one call, so changing the setting mid-call changes nothing.
    @Published private(set) var isVideoCall = false
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
    /// Buffers handed to the player that it has not played yet, counted from its own callbacks.
    /// The clock estimate drifted from real playback, so silence was inserted mid-sentence.
    private var unplayed = 0
    /// Audible buffers not played yet, and when the last one finished, for the talking animation.
    private var audibleUnplayed = 0
    private var lastAudiblePlayed: TimeInterval = 0
    private static let talkingHold: TimeInterval = 0.6
    /// Bumped when playback is flushed, so callbacks for discarded buffers are ignored.
    private var playbackGeneration = 0
    private var fenced = false
    private var stopRequested = false
    private var timer: Timer?
    private var engineRunning = false
    private var routeObserver: NSObjectProtocol?

    // Shared with the audio thread, under `lock`.
    private let lock = NSLock()
    private var gateStream: MuseDuplexStream?
    /// Video-call media (Docs/VIDEO-CALLS-PLAN.md step 3): SRTP straight to Muse's media
    /// endpoint instead of the realtime stream. Audio only for now.
    private var gateMedia: MuseMediaSession?
    private var lastMicSpeech: TimeInterval = 0
    private var gateReady = false
    private var gateMuted = false
    private var gatePlayingUntil: TimeInterval = 0
    private var micBuffer = Data()
    /// Append lines waiting to go out together. One socket message per 40 ms frame was more
    /// than an iPhone 6s could send, so its audio reached Muse later and later; five frames
    /// per message keeps up, for at most 200 ms of extra delay.
    private var pendingLines = Data()
    private var pendingFrames = 0
    private static let framesPerMessage = 5
    // Microphone levels for the diagnostics log only: the device's noise floor, and `silenced`
    // counting frames near it. Nothing is altered.
    private var noiseFloor: Double = 120
    private var floorFrames = 0
    private var lastSpeech: TimeInterval = 0
    private var rmsSum: Double = 0
    private var rmsCount = 0
    private var silenced = 0
    private var micSent = 0
    private var micClosed = 0
    private var audibleIn = 0
    private var quietIn = 0
    private var lastCounters = Date()

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

    /// Whether this device offers microphone modes such as Voice Isolation (A12 chips and later).
    static var canPickMicrophoneMode: Bool {
        guard #available(iOS 15.0, *) else { return false }
        return AVCaptureDevice.activeMicrophoneMode != .standard || supportsMicrophoneModes
    }

    private static var supportsMicrophoneModes: Bool {
        var info = utsname()
        uname(&info)
        let model = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        // Older than A12: iPhone 8/X and before are iPhone10,x or lower; iPad 7 and before iPad7,x.
        guard let major = Int(model.drop { !$0.isNumber }.prefix { $0.isNumber }) else { return false }
        if model.hasPrefix("iPhone") { return major >= 11 }
        if model.hasPrefix("iPad") { return major >= 11 }
        return false
    }

    static func showMicrophoneModes() {
        if #available(iOS 15.0, *) {
            AVCaptureDevice.showSystemUserInterface(.microphoneModes)
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
        isVideoCall = Self.usesMedia
        if isVideoCall {
            connectAttemptsUntil = Date().addingTimeInterval(Self.connectWait)
            connectMedia()
            return
        }
        let admission = MuseVoiceEvents.line([
            "type": "hatch.voice.call.start",
            "call_id": callID,
            "call_media_type": Self.callMediaType,
            "device": "mcu-wearable",
            "device_id": runtime.deviceNodeID,
            // Muse greets once it can listen. For its first 12-15 s a call answered every
            // sentence with hatch.voice.input_suppressed, so the greeting is the signal to talk.
            "proactive_greeting_enabled": true
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
        connectAttemptsUntil = Date().addingTimeInterval(Self.connectWait)
        openCallStream(admission: admission, handlers: handlers)
    }

    /// Media endpoint, JOIN, then SRTP straight to the endpoint, as the SDK's VideoCall._start.
    private func connectMedia() {
        trace("media_endpoint")
        runtime.requestJSON(method: "GET", path: "/voice/calls/media-endpoint") { [weak self] response in
            guard let self, self.phase == .connecting else { return }
            guard case .success(let reply) = response else {
                if Date() < self.connectAttemptsUntil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.connectMedia() }
                } else {
                    self.end(PalL10n.text("Muse сейчас не подключён"), notify: false)
                }
                return
            }
            let endpoint = ((try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any])?["result"] as? [String: Any]
            guard let host = endpoint?["host"] as? String, !host.isEmpty,
                  let port = endpoint?["port"] as? Int, (1...65_535).contains(port),
                  let vip = endpoint?["vip_type"] as? String, let code = MuseCallJoinOffer.endpointTypes[vip] else {
                self.end(PalL10n.format("voice.call_refused_format", reply.status), notify: false)
                return
            }
            self.join(host: host, port: port, vipCode: code, cosmos: (endpoint?["enable_media_to_cosmos"] as? Bool) ?? false)
        }
    }

    private func join(host: String, port: Int, vipCode: Int32, cosmos: Bool) {
        trace("join")
        let offer = MuseCallJoinOffer.make(threadID: nil, edgeHost: host, edgePort: port, vipType: vipCode, video: true)
        let body: [String: Any] = [
            "payload_b64": offer.payload.base64EncodedString(),
            "call_id": callID,
            "call_media_type": "video",
            "device": "mcu-wearable",
            "device_id": runtime.deviceNodeID,
            "proactive_greeting_enabled": false,
            "enable_media_to_cosmos": cosmos
        ]
        runtime.postJSON(path: "/voice/calls/join", fields: body) { [weak self] response in
            guard let self, self.phase == .connecting else { return }
            guard case .success(let reply) = response,
                  let joined = ((try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any])?["result"] as? [String: Any],
                  let encoded = joined["payload_b64"] as? String, let payload = Data(base64Encoded: encoded),
                  let answer = try? MuseCallJoinAnswer.parse(payload) else {
                let status = (try? response.get().status) ?? 0
                self.end(PalL10n.format("voice.call_refused_format", status))
                return
            }
            let media: MuseMediaSession
            do {
                media = try MuseMediaSession(offer: offer, answer: answer, host: host, port: port)
            } catch {
                // Opus comes from AudioToolbox; an iOS without it cannot make this call.
                self.trace("media_unavailable=\(MuseDiagnostics.label(error))")
                self.end(PalL10n.text("Не удалось включить микрофон и динамик"))
                return
            }
            self.media = media
            media.onAudio = { [weak self] pcm48 in
                let pcm = MuseVoiceCall.downsample48to24(pcm48)
                DispatchQueue.main.async { self?.play(pcm) }
            }
            media.onVideo = { [weak self] nals in
                DispatchQueue.main.async { self?.show(nals) }
            }
            self.video.onNeedsKeyframe = { [weak media] in media?.requestKeyframe() }
            self.video.onSize = { [weak self] size in self?.videoAspect = size.width / size.height }
            media.onLost = { [weak self] in
                DispatchQueue.main.async { self?.end(PalL10n.text("Связь с Muse прервалась")) }
            }
            self.trace("ice")
            media.connect(timeout: 10) { [weak self] transport in
                guard let self, self.phase == .connecting else { return }
                guard let transport else {
                    self.end(PalL10n.text("Связь с Muse прервалась"))
                    return
                }
                self.trace("media=\(transport)")
                self.withGate {
                    self.gateMedia = media
                    self.gateReady = true
                }
                media.requestKeyframe()
                self.isMuseReady = true
                self.lastActivity = Date()
                self.phase = .listening
                self.timer?.invalidate()
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
            }
        }
    }

    private func openCallStream(admission: Data, handlers: MuseDuplexHandlers) {
        runtime.openDuplexStream(
            path: "/voice/realtime?call_id=\(callID)",
            contentType: "application/x-ndjson; charset=utf-8",
            accept: "application/x-ndjson",
            firstBody: admission,
            handlers: handlers
        ) { [weak self] stream in
            guard let self else { return }
            guard let stream else {
                // Turning live calls on reconnects; wait for Muse instead of failing a tap.
                if Date() < self.connectAttemptsUntil, self.phase == .connecting {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.openCallStream(admission: admission, handlers: handlers) }
                } else {
                    self.end(PalL10n.text("Muse сейчас не подключён"), notify: false)
                }
                return
            }
            self.withGate { self.gateStream = stream }
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    private func end(_ reason: String, notify: Bool = true) {
        guard phase.isActive else { return }
        timer?.invalidate()
        timer = nil
        let stream = withGate { () -> MuseDuplexStream? in
            let stream = gateStream
            gateStream = nil
            gateMedia = nil
            gateReady = false
            return stream
        }
        if let media {
            let stats = media.stats
            trace("media_total[transport=\(stats.transport),in=\(stats.bytesIn),audio=\(stats.rtpAudio),video=\(stats.rtpVideo),rtcp=\(stats.rtcp),srtp_errors=\(stats.srtpErrors),decode_errors=\(stats.decodeErrors),late=\(stats.lateAudio),sent=\(stats.audioSent),units=\(stats.videoUnits)]")
            media.close()
            self.media = nil
        }
        trace("video_shown=\(video.framesShown)")
        video.reset()
        hasVideo = false
        stopAudio()
        audibleSpans.removeAll()
        isVoiceAudible = false
        replyAudioOpen = false
        replyHeard = false
        isUserSpeaking = false
        isMuseReady = false
        missedSentence = false
        trace("video_total[count=\(videoSeen),chars=\(videoBytes),media=\(Self.callMediaType)]")
        trace("ended")
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
        if !isMuseReady, phase == .listening, now.timeIntervalSince(startedAt) > Self.readyFallback {
            isMuseReady = true
        }
        let clock = uptime()
        audibleSpans.removeAll { $0.end + Self.speakingSettle < clock }
        // The media path has no reply events: Muse talks while its audio is audible.
        // Lips move while audible audio is actually playing, as the SDK's mouth follows the voice
        // level, and for a short hold after it so pauses between words do not restart the clip.
        // Muse's quiet background stream between replies no longer counts.
        let talking = audibleUnplayed > 0 || clock - lastAudiblePlayed < Self.talkingHold
        if let media, phase.isActive, phase != .connecting {
            if now.timeIntervalSince(media.lastMedia) > Self.mediaTimeout {
                end(PalL10n.text("Связь с Muse прервалась"))
                return
            }
            let spoke = withGate { lastMicSpeech }
            if clock - spoke < 0.5 { lastActivity = now }
        }
        if talking != isVoiceAudible { isVoiceAudible = talking }
        if !talking, !replyAudioOpen { replyHeard = false }
        if now.timeIntervalSince(lastCounters) >= 5 {
            lastCounters = now
            let counts = withGate { () -> String in
                let average = rmsCount > 0 ? Int(rmsSum / Double(rmsCount)) : 0
                let text = "sent=\(micSent),closed=\(micClosed),silenced=\(silenced),rms=\(average),floor=\(Int(noiseFloor)),until=\(Int(max(0, gatePlayingUntil - uptime()) * 1000))"
                micSent = 0
                micClosed = 0
                silenced = 0
                rmsSum = 0
                rmsCount = 0
                return text
            }
            trace("mic[\(counts),backlog=\(runtime.outboundBacklog),loud=\(audibleIn),quiet=\(quietIn),lead=\(Int(Self.prebuffer * 1000)),gaps=\(underruns),phase=\(MuseDiagnostics.label(phase))]")
            audibleIn = 0
            quietIn = 0
        }
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
            if type == "error", let error = event["error"] as? [String: Any] {
                trace("error_code=\(MuseDiagnostics.label(error["code"] as? String ?? error["type"] as? String ?? "?"))")
            }
        case "continuous_audio_video.delta", "response.audio.delta", "response.output_audio.delta",
             "response.audio_transcript.delta", "response.output_audio_transcript.delta":
            break
        default:
            // Every other event's type, never its content: the first sentence of a call was being
            // dropped by the server without any event this log knew about.
            trace("event=\(String(type.prefix(64)))")
        }
        switch type {
        case "hatch.voice.session":
            threadID = event["thread_id"] as? String
            withGate { gateReady = true }
            lastActivity = Date()
            phase = .listening
        case "hatch.voice.input_suppressed":
            isUserSpeaking = false
            missedSentence = true
            missedReset?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.missedSentence = false }
            missedReset = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
        case "error":
            let code = (event["error"] as? [String: Any])?["code"] as? String
            if phase == .connecting || code == "session_dead" {
                end(PalL10n.text("Muse не смог начать разговор"))
            }
        case "input_audio_buffer.speech_started":
            isUserSpeaking = true
            fenced = false
            lastActivity = Date()
            if phase != .speaking { phase = .listening }
        case "input_audio_buffer.speech_stopped", "input_audio_buffer.committed":
            isUserSpeaking = false
        case "conversation.item.input_audio_transcription.completed":
            if let text = event["transcript"] as? String, !text.isEmpty { heard = text }
        case "hatch.voice.turn_started":
            isMuseReady = true
            missedSentence = false
            fenced = false
            reply = ""
            lastActivity = Date()
            if phase == .listening { phase = .thinking }
        case "response.audio_transcript.delta", "response.output_audio_transcript.delta":
            if !fenced, let delta = event["delta"] as? String { reply += delta }
        case "response.output_audio.start", "response.created":
            replyAudioOpen = true
        case "response.output_audio.done", "response.done":
            replyAudioOpen = false
        case "conversation.item.added":
            let item = event["item"] as? [String: Any]
            if item?["type"] as? String == "session_control",
               (item?["name"] as? String)?.lowercased() == "stop" {
                stopRequested = true
                if phase != .speaking { end(PalL10n.text("Muse завершил разговор")) }
            }
        default:
            if let video = event["video_delta"] as? [String: Any] {
                // Names and sizes only, never the content: does Muse send its avatar as video?
                if videoSeen < 3 {
                    let shape = video.keys.sorted().map { key -> String in
                        if let text = video[key] as? String { return "\(key):\(text.count)" }
                        if let object = video[key] as? [String: Any] { return "\(key){\(object.keys.sorted().joined(separator: ","))}" }
                        return "\(key):\(Swift.type(of: video[key]!))"
                    }.joined(separator: ",")
                    trace("video[\(shape)]")
                }
                videoSeen += 1
                videoBytes += (video.values.compactMap { $0 as? String }.map(\.count).reduce(0, +))
            }
            if let pcm = MuseVoiceEvents.audio(from: event) { play(pcm) }
        }
    }

    // MARK: Audio

    private func startAudio() throws {
        let session = AVAudioSession.sharedInstance()
        // Plain play-and-record on the loudspeaker at media volume. The voice modes switch an
        // iPhone to its quieter call volume, and their processing kept Muse's server from hearing
        // the end of speech; the SDK relies on half duplex, not device processing, against echo.
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        routeToSpeakerIfBuiltIn()
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.routeToSpeakerIfBuiltIn() }
        if !engine.attachedNodes.contains(player) {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        }
        let input = engine.inputNode
        if input.isVoiceProcessingEnabled {
            try? input.setVoiceProcessingEnabled(false)
        }
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
            self?.capture(buffer)
        }
        engine.prepare()
        try engine.start()
        routeToSpeakerIfBuiltIn()
        let route = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue).joined(separator: "+")
        trace("route=\(route),volume=\(Int(AVAudioSession.sharedInstance().outputVolume * 100))")
        player.play()
        engineRunning = true
        queueEnd = 0
        unplayed = 0
        audibleUnplayed = 0
        lastAudiblePlayed = 0
        playbackGeneration += 1
        underruns = 0
        withGate {
            gatePlayingUntil = 0
            gateMuted = isMuted
            micBuffer.removeAll()
            noiseFloor = 120
            floorFrames = 0
            lastSpeech = 0
        }
    }

    /// A gadget on a desk is a speakerphone: an iPhone's loudspeaker is used, not its earpiece,
    /// unless headphones or Bluetooth are on.
    private func routeToSpeakerIfBuiltIn() {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map(\.portType)
        guard outputs.contains(.builtInReceiver) || outputs.isEmpty else { return }
        try? session.overrideOutputAudioPort(.speaker)
    }

    private func stopAudio() {
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
            self.routeObserver = nil
        }
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
        if let media = withGate({ gateMedia }) {
            captureForMedia(pcm, media: media)
            return
        }
        var frames: [Data] = []
        let stream: MuseDuplexStream? = withGate {
            guard let stream = gateStream, gateReady, !gateMuted, uptime() >= gatePlayingUntil else {
                // Audio captured while closed is dropped, never sent late.
                micBuffer.removeAll()
                pendingLines.removeAll()
                pendingFrames = 0
                micClosed += 1
                return nil
            }
            micBuffer.append(pcm)
            let now = uptime()
            while micBuffer.count >= MuseVoiceEvents.frameBytes {
                let frame = micBuffer.prefix(MuseVoiceEvents.frameBytes)
                micBuffer.removeFirst(MuseVoiceEvents.frameBytes)
                let level = Self.rms(frame)
                rmsSum += level
                rmsCount += 1
                // The first half second sets the floor; after that it drops at once and rises
                // only on frames that are not speech, so talking never raises it.
                floorFrames += 1
                if floorFrames <= 12 {
                    noiseFloor += (level - noiseFloor) / Double(floorFrames)
                } else if level < noiseFloor {
                    noiseFloor = level
                } else if level < noiseFloor * 3 {
                    noiseFloor += (level - noiseFloor) * 0.02
                }
                if level >= max(12, noiseFloor * 3) { lastSpeech = now } else if now - lastSpeech > 0.4 { silenced += 1 }
                // Raw audio, as the SDK's hands-free call sends it: Muse's server finds the end
                // of speech itself. Levels are only measured for the diagnostics log.
                frames.append(frame)
            }
            micSent += frames.count
            return stream
        }
        guard let stream, !frames.isEmpty else { return }
        let batch: Data? = withGate {
            for frame in frames { pendingLines.append(MuseVoiceEvents.appendLine(frame)) }
            pendingFrames += frames.count
            guard pendingFrames >= Self.framesPerMessage else { return nil }
            let batch = pendingLines
            pendingLines = Data()
            pendingFrames = 0
            return batch
        }
        if let batch { stream.send(batch) }
    }

    /// The video-call path, as the SDK's video_call.py: 20 ms Opus frames at 48 kHz, and while
    /// Muse's voice plays (or the mic is muted) silence instead of the microphone, so the stream
    /// keeps its timing.
    private func captureForMedia(_ pcm: Data, media: MuseMediaSession) {
        var frames: [Data] = []
        withGate {
            guard gateReady else { micBuffer.removeAll(); return }
            let open = !gateMuted && uptime() >= gatePlayingUntil
            if !open { micClosed += 1 }
            micBuffer.append(open ? pcm : Data(count: pcm.count))
            while micBuffer.count >= MuseVoiceEvents.frameBytes {
                let frame = micBuffer.prefix(MuseVoiceEvents.frameBytes)
                micBuffer.removeFirst(MuseVoiceEvents.frameBytes)
                let level = Self.rms(frame)
                rmsSum += level
                rmsCount += 1
                if level >= Self.audibleRMS { lastMicSpeech = uptime() }
                frames.append(frame)
            }
            micSent += frames.count
        }
        for frame in frames {
            let wide = MuseVoiceCall.upsample24to48(frame)
            media.sendAudio(wide.prefix(1_920))
            media.sendAudio(wide.suffix(from: wide.startIndex + 1_920))
        }
    }

    private func show(_ nals: [Data]) {
        guard phase.isActive, media != nil else { return }
        video.enqueue(nals)
        if !hasVideo, video.framesShown > 0 {
            hasVideo = true
            trace("video_first")
            // A player may lose the first keyframe while it starts; ask again a moment later,
            // as the SDK's VideoCall does.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.media?.requestKeyframe() }
        }
    }

    /// 24 kHz to 48 kHz by linear interpolation, as the SDK's _upsample24_to_48.
    static func upsample24to48(_ pcm: Data) -> Data {
        let input = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        var output = [Int16](repeating: 0, count: input.count * 2)
        for index in 0..<input.count {
            let current = Int32(input[index])
            let next = Int32(index + 1 < input.count ? input[index + 1] : input[index])
            output[2 * index] = Int16(current)
            output[2 * index + 1] = Int16((current + next) / 2)
        }
        return output.withUnsafeBytes { Data($0) }
    }

    /// 48 kHz to 24 kHz by averaging each pair of samples.
    static func downsample48to24(_ pcm: Data) -> Data {
        let input = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        var output = [Int16](repeating: 0, count: input.count / 2)
        for index in 0..<output.count {
            output[index] = Int16((Int32(input[2 * index]) + Int32(input[2 * index + 1])) / 2)
        }
        return output.withUnsafeBytes { Data($0) }
    }

    private func play(_ pcm: Data) {
        guard !fenced, engineRunning, !pcm.isEmpty else { return }
        let count = pcm.count / 2
        let rms = Self.rms(pcm)
        if rms >= Self.audibleRMS { audibleIn += 1 } else { quietIn += 1 }
        // Muse streams silence between answers; it is not worth queueing or closing the mic for.
        guard rms > 0 || unplayed > 0 else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<count { channel[index] = Float(Int16(littleEndian: samples[index])) / 32_768 }
        }
        // When nothing is queued, hold the start back a little: a short underrun mid-sentence
        // then becomes a slightly later start instead of a gap in the words.
        // Whenever playback would start from an empty queue, quiet onset included, it first
        // waits 600 ms, so the opening words have audio behind them.
        if unplayed == 0 {
            if let last = audibleSpans.last, uptime() - last.end < 1.0 { underruns += 1 }
            if let lead = AVAudioPCMBuffer(pcmFormat: playbackFormat,
                                           frameCapacity: AVAudioFrameCount(Self.prebuffer * Double(MuseVoiceEvents.sampleRate))) {
                lead.frameLength = lead.frameCapacity
                if let channel = lead.floatChannelData?[0] { channel.update(repeating: 0, count: Int(lead.frameLength)) }
                schedule(lead)
                queueEnd = uptime() + Self.prebuffer
            }
        }
        schedule(buffer, audible: rms >= Self.audibleRMS)
        let duration = Double(count) / Double(MuseVoiceEvents.sampleRate)
        let startsAt = max(uptime(), queueEnd)
        queueEnd = startsAt + duration
        if rms >= Self.audibleRMS {
            if let last = audibleSpans.last, startsAt - last.end < 0.05 {
                audibleSpans[audibleSpans.count - 1].end = queueEnd
            } else {
                audibleSpans.append((startsAt, queueEnd))
            }
            if firstAudioOfTurn {
                firstAudioOfTurn = false
                trace("reply_audio")
            }
            replyHeard = true
            isMuseReady = true
            let until = queueEnd + Self.speakerLag + Self.settle
            withGate { gatePlayingUntil = until; micBuffer.removeAll() }
            lastActivity = Date()
            phase = .speaking
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, audible: Bool = false) {
        unplayed += 1
        if audible { audibleUnplayed += 1 }
        let generation = playbackGeneration
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, generation == self.playbackGeneration, self.unplayed > 0 else { return }
                self.unplayed -= 1
                if audible, self.audibleUnplayed > 0 {
                    self.audibleUnplayed -= 1
                    self.lastAudiblePlayed = self.uptime()
                }
            }
        }
    }

    private func flushPlayback() {
        player.stop()
        player.play()
        queueEnd = 0
        unplayed = 0
        audibleUnplayed = 0
        lastAudiblePlayed = 0
        playbackGeneration += 1
        audibleSpans.removeAll()
        isVoiceAudible = false
        replyAudioOpen = false
        replyHeard = false
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
