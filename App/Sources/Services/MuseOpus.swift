import AVFoundation
import Foundation

/// Opus for video calls through AudioToolbox, in place of the SDK's libopus via ctypes
/// (rtc/opus.py): mono 48 kHz, 20 ms (960 samples) per packet, about 32 kbit/s.
enum MuseOpusError: Error {
    case unavailable
    case failed
}

enum MuseOpus {
    static let sampleRate = 48_000.0
    static let frameSamples: AVAudioFrameCount = 960
    static let bitRate = 32_000

    static let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!

    static var opusFormat: AVAudioFormat? {
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: frameSamples, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0
        )
        return AVAudioFormat(streamDescription: &description)
    }
}

final class MuseOpusEncoder {
    private let converter: AVAudioConverter
    private let output: AVAudioFormat

    init() throws {
        guard let opus = MuseOpus.opusFormat,
              let converter = AVAudioConverter(from: MuseOpus.pcmFormat, to: opus) else { throw MuseOpusError.unavailable }
        converter.bitRate = MuseOpus.bitRate
        self.converter = converter
        output = opus
    }

    /// One packet from exactly 20 ms of mono 48 kHz PCM16.
    func encode(_ pcm: Data) throws -> Data {
        let frames = AVAudioFrameCount(pcm.count / 2)
        guard frames == MuseOpus.frameSamples,
              let input = AVAudioPCMBuffer(pcmFormat: MuseOpus.pcmFormat, frameCapacity: frames) else { throw MuseOpusError.failed }
        input.frameLength = frames
        pcm.withUnsafeBytes { raw in
            input.int16ChannelData?[0].update(from: raw.bindMemory(to: Int16.self).baseAddress!, count: Int(frames))
        }
        let packet = AVAudioCompressedBuffer(format: output, packetCapacity: 1, maximumPacketSize: 1_500)
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: packet, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, packet.packetCount > 0, packet.byteLength > 0 else { throw MuseOpusError.failed }
        return Data(bytes: packet.data, count: Int(packet.byteLength))
    }
}

final class MuseOpusDecoder {
    private let converter: AVAudioConverter
    private let input: AVAudioFormat

    init() throws {
        guard let opus = MuseOpus.opusFormat,
              let converter = AVAudioConverter(from: opus, to: MuseOpus.pcmFormat) else { throw MuseOpusError.unavailable }
        self.converter = converter
        input = opus
    }

    /// Mono 48 kHz PCM16 from one Opus packet.
    func decode(_ packet: Data) throws -> Data {
        guard !packet.isEmpty, packet.count <= 1_500 else { throw MuseOpusError.failed }
        let compressed = AVAudioCompressedBuffer(format: input, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { raw in compressed.data.copyMemory(from: raw.baseAddress!, byteCount: packet.count) }
        compressed.byteLength = UInt32(packet.count)
        compressed.packetCount = 1
        compressed.packetDescriptions?[0] = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count)
        )
        // An Opus packet holds at most 120 ms.
        guard let output = AVAudioPCMBuffer(pcmFormat: MuseOpus.pcmFormat, frameCapacity: 5_760) else { throw MuseOpusError.failed }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return compressed
        }
        guard status != .error, error == nil, let samples = output.int16ChannelData else { throw MuseOpusError.failed }
        return Data(bytes: samples[0], count: Int(output.frameLength) * 2)
    }
}
