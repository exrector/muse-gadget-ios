import AVFoundation
import Foundation

/// Splits a streamed NDJSON body into JSON objects. Lines that are not objects are skipped, and a
/// line that grows past the limit is dropped instead of buffering without end.
struct MuseNDJSONLines {
    private var buffer = Data()
    private let maxLine: Int

    init(maxLine: Int = 1024 * 1024) {
        self.maxLine = maxLine
    }

    mutating func feed(_ data: Data) -> [[String: Any]] {
        buffer.append(data)
        var records: [[String: Any]] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                records.append(object)
            }
        }
        if buffer.count > maxLine { buffer.removeAll() }
        return records
    }
}

/// The audio format and event shapes of the SDK's dictation and realtime voice routes:
/// PCM16 little-endian, mono, 24 kHz, sent as 960-sample `input_audio_buffer.append` lines.
enum MuseVoiceEvents {
    static let sampleRate = 24_000
    static let frameSamples = 960
    static let frameBytes = frameSamples * 2
    private static let maxDeltaBytes = sampleRate * 2 * 4

    /// The PCM in a reply audio event, or nil for any other event or a malformed one.
    static func audio(from event: [String: Any]) -> Data? {
        let encoded: String?
        switch event["type"] as? String {
        case "continuous_audio_video.delta":
            guard let audio = event["audio_delta"] as? [String: Any] else { return nil }
            if let format = audio["format"] as? [String: Any] {
                let type = format["type"] as? String ?? ""
                guard type.isEmpty || type == "audio/pcm",
                      (format["rate"] as? Int) == sampleRate else { return nil }
            }
            guard (audio["num_channels"] as? Int ?? 1) == 1 else { return nil }
            encoded = audio["audio_frames"] as? String
        case "response.output_audio.delta", "response.audio.delta":
            encoded = event["delta"] as? String
        default:
            return nil
        }
        guard let encoded, let pcm = Data(base64Encoded: encoded),
              pcm.count % 2 == 0, pcm.count <= maxDeltaBytes else { return nil }
        return pcm
    }

    static func appendLine(_ pcm: Data) -> Data {
        let event: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": pcm.base64EncodedString(),
            "send_timestamp_ms": Int(Date().timeIntervalSince1970 * 1000)
        ]
        var line = (try? JSONSerialization.data(withJSONObject: event)) ?? Data()
        line.append(0x0A)
        return line
    }

    static func line(_ event: [String: Any]) -> Data {
        var line = (try? JSONSerialization.data(withJSONObject: event)) ?? Data()
        line.append(0x0A)
        return line
    }
}

enum MuseVoiceTime {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func rfc3339(_ date: Date) -> String { formatter.string(from: date) }
}

/// Converts any PCM buffer to the 24 kHz mono PCM16 the voice routes take.
final class MuseVoiceResampler {
    let output = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(MuseVoiceEvents.sampleRate),
        channels: 1,
        interleaved: true
    )!
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> Data {
        if inputFormat != buffer.format {
            inputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: output)
        }
        guard let converter, buffer.frameLength > 0 else { return Data() }
        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return Data() }
        var supplied = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, converted.frameLength > 0, let samples = converted.int16ChannelData else { return Data() }
        return Data(bytes: samples[0], count: Int(converted.frameLength) * 2)
    }
}

/// Speaks text with the iOS synthesizer into 24 kHz PCM16, for device checks of the voice routes.
enum MuseSpeechPCM {
    static func render(_ text: String, with synthesizer: AVSpeechSynthesizer, completion: @escaping (Data) -> Void) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        let resampler = MuseVoiceResampler()
        var pcm = Data()
        var finished = false
        synthesizer.write(utterance) { buffer in
            guard !finished else { return }
            guard let buffer = buffer as? AVAudioPCMBuffer, buffer.frameLength > 0 else {
                finished = true
                DispatchQueue.main.async { completion(pcm) }
                return
            }
            pcm.append(resampler.convert(buffer))
        }
    }
}
