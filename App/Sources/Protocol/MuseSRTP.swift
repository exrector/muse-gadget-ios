// Ported from the Muse Gadget SDK, branch anantn/linux-video-calls (commit 77c7e27),
// linux/src/musegadget/rtc/srtp.py and rtc/rtp.py. Copyright (c) Meta Platforms, Inc. and
// affiliates. Licensed under the Apache License, Version 2.0.

import CommonCrypto
import CryptoKit
import Foundation

enum MuseSRTPError: Error {
    case malformed(String)
    case authentication
    case replay
}

/// SRTP and SRTCP with AES_CM_128_HMAC_SHA1_80 (RFC 3711), keyed directly from the JOIN's
/// 30-byte master key and salt. One direction-agnostic context, as the SDK's SrtpSession.
final class MuseSRTPSession {
    static let tagLength = 10
    static let masterKeyLength = 16
    static let masterSaltLength = 14

    struct Keys {
        let encryption: Data
        let authentication: Data
        let salt: [UInt8]

        init(masterKey: Data, masterSalt: Data, baseLabel: UInt8) {
            encryption = MuseSRTPSession.derive(masterKey, masterSalt, label: baseLabel, length: 16)
            authentication = MuseSRTPSession.derive(masterKey, masterSalt, label: baseLabel + 1, length: 20)
            salt = [UInt8](MuseSRTPSession.derive(masterKey, masterSalt, label: baseLabel + 2, length: 14))
        }

        /// (salt << 16) ^ (ssrc << 64) ^ (index << 16), as 16 bytes.
        func iv(ssrc: UInt32, index: UInt64) -> [UInt8] {
            var iv = [UInt8](repeating: 0, count: 16)
            for i in 0..<14 { iv[i] = salt[i] }
            for i in 0..<4 { iv[4 + i] ^= UInt8((ssrc >> (24 - 8 * UInt32(i))) & 0xFF) }
            for i in 0..<6 { iv[8 + i] ^= UInt8((index >> (40 - 8 * UInt64(i))) & 0xFF) }
            return iv
        }

        func tag(_ data: Data) -> Data {
            Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: SymmetricKey(data: authentication)))
                .prefix(MuseSRTPSession.tagLength)
        }
    }

    private struct ReplayWindow {
        var top: UInt64?
        var seen: UInt64 = 0

        mutating func check(_ index: UInt64) throws {
            guard let top else {
                self.top = index
                seen = 1
                return
            }
            if index > top {
                let shift = index - top
                seen = shift < 64 ? (seen << shift) | 1 : 1
                self.top = index
            } else {
                let behind = top - index
                guard behind < 64, (seen >> behind) & 1 == 0 else { throw MuseSRTPError.replay }
                seen |= 1 << behind
            }
        }
    }

    private let rtp: Keys
    private let rtcp: Keys
    private var transmitROC: [UInt32: (roc: UInt32, last: UInt16)] = [:]
    private var receiveROC: [UInt32: (roc: UInt32, last: UInt16)] = [:]
    private var transmitRTCPIndex: [UInt32: UInt32] = [:]
    private var receiveRTPWindows: [UInt32: ReplayWindow] = [:]
    private var receiveRTCPWindows: [UInt32: ReplayWindow] = [:]

    init(keyAndSalt: Data) throws {
        guard keyAndSalt.count == Self.masterKeyLength + Self.masterSaltLength else {
            throw MuseSRTPError.malformed("master key and salt must be 30 bytes")
        }
        let key = keyAndSalt.prefix(Self.masterKeyLength)
        let salt = keyAndSalt.suffix(Self.masterSaltLength)
        rtp = Keys(masterKey: key, masterSalt: salt, baseLabel: 0)
        rtcp = Keys(masterKey: key, masterSalt: salt, baseLabel: 3)
    }

    /// The RTP session keys, for tests against RFC 3711's key derivation vectors.
    var rtpKeys: Keys { rtp }

    // MARK: RTP

    func protectRTP(_ packet: Data) throws -> Data {
        let bytes = [UInt8](packet)
        let headerLength = try Self.rtpHeaderLength(bytes)
        let ssrc = MuseSTUN.read32(bytes, 8)
        let seq = MuseSTUN.read16(bytes, 2)
        var (roc, last) = transmitROC[ssrc] ?? (0, seq)
        if seq < last && last - seq > 0x8000 { roc &+= 1 }
        transmitROC[ssrc] = (roc, seq)
        let index = UInt64(roc) << 16 | UInt64(seq)
        let payload = Data(bytes[headerLength...])
        var body = Data(bytes[..<headerLength])
        body.append(Self.xor(payload, key: rtp.encryption, iv: rtp.iv(ssrc: ssrc, index: index)))
        return body + rtp.tag(body + MuseSTUN.be32(roc))
    }

    func unprotectRTP(_ packet: Data) throws -> Data {
        guard packet.count >= 12 + Self.tagLength else { throw MuseSRTPError.malformed("short SRTP packet") }
        let body = Data(packet.prefix(packet.count - Self.tagLength))
        let tag = Data(packet.suffix(Self.tagLength))
        let bytes = [UInt8](body)
        let headerLength = try Self.rtpHeaderLength(bytes)
        let ssrc = MuseSTUN.read32(bytes, 8)
        let seq = MuseSTUN.read16(bytes, 2)
        let (roc, last) = receiveROC[ssrc] ?? (0, seq)
        var guess = roc
        if last < 0x8000 {
            if Int(seq) - Int(last) > 0x8000 { guess = roc &- 1 }
        } else if Int(last) - 0x8000 > Int(seq) {
            guess = roc &+ 1
        }
        guard rtp.tag(body + MuseSTUN.be32(guess)) == tag else { throw MuseSRTPError.authentication }
        let index = UInt64(guess) << 16 | UInt64(seq)
        var window = try window(for: ssrc, in: &receiveRTPWindows)
        try window.check(index)
        receiveRTPWindows[ssrc] = window
        if (guess == roc && seq > last) || guess == roc &+ 1 || receiveROC[ssrc] == nil {
            receiveROC[ssrc] = (guess, seq)
        }
        var out = Data(bytes[..<headerLength])
        out.append(Self.xor(Data(bytes[headerLength...]), key: rtp.encryption, iv: rtp.iv(ssrc: ssrc, index: index)))
        return out
    }

    // MARK: RTCP

    func protectRTCP(_ packet: Data) throws -> Data {
        guard packet.count >= 8 else { throw MuseSRTPError.malformed("short RTCP packet") }
        let bytes = [UInt8](packet)
        let ssrc = MuseSTUN.read32(bytes, 4)
        // Like libsrtp, the first SRTCP index sent is 1.
        let index = ((transmitRTCPIndex[ssrc] ?? 0) + 1) & 0x7FFF_FFFF
        transmitRTCPIndex[ssrc] = index
        var body = Data(bytes[..<8])
        body.append(Self.xor(Data(bytes[8...]), key: rtcp.encryption, iv: rtcp.iv(ssrc: ssrc, index: UInt64(index))))
        body.append(MuseSTUN.be32(0x8000_0000 | index))
        return body + rtcp.tag(body)
    }

    func unprotectRTCP(_ packet: Data) throws -> Data {
        guard packet.count >= 8 + 4 + Self.tagLength else { throw MuseSRTPError.malformed("short SRTCP packet") }
        let signed = Data(packet.prefix(packet.count - Self.tagLength))
        guard rtcp.tag(signed) == Data(packet.suffix(Self.tagLength)) else { throw MuseSRTPError.authentication }
        let bytes = [UInt8](signed)
        let eIndex = MuseSTUN.read32(bytes, bytes.count - 4)
        let body = Array(bytes[..<(bytes.count - 4)])
        let index = eIndex & 0x7FFF_FFFF
        let ssrc = MuseSTUN.read32(body, 4)
        var window = try window(for: ssrc, in: &receiveRTCPWindows)
        try window.check(UInt64(index))
        receiveRTCPWindows[ssrc] = window
        guard eIndex & 0x8000_0000 != 0 else { return Data(body) }
        var out = Data(body[..<8])
        out.append(Self.xor(Data(body[8...]), key: rtcp.encryption, iv: rtcp.iv(ssrc: ssrc, index: UInt64(index))))
        return out
    }

    // MARK: Helpers

    private func window(for ssrc: UInt32, in windows: inout [UInt32: ReplayWindow]) throws -> ReplayWindow {
        if let window = windows[ssrc] { return window }
        guard windows.count < 16 else { throw MuseSRTPError.malformed("too many SRTP streams") }
        return ReplayWindow()
    }

    static func rtpHeaderLength(_ packet: [UInt8]) throws -> Int {
        guard packet.count >= 12 else { throw MuseSRTPError.malformed("short RTP packet") }
        var length = 12 + 4 * Int(packet[0] & 0x0F)
        if packet[0] & 0x10 != 0 {
            guard packet.count >= length + 4 else { throw MuseSRTPError.malformed("short RTP extension") }
            length += 4 + 4 * Int(MuseSTUN.read16(packet, length + 2))
        }
        guard packet.count >= length else { throw MuseSRTPError.malformed("short RTP header") }
        return length
    }

    /// AES-128 in counter mode over zeros: the keystream that RFC 3711's AES-CM XORs in.
    static func keystream(key: Data, iv: [UInt8], length: Int) -> Data {
        guard length > 0 else { return Data() }
        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { keyBytes in
            CCCryptorCreateWithMode(
                CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                iv, keyBytes.baseAddress, key.count, nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor
            )
        }
        guard status == kCCSuccess, let cryptor else { return Data(count: length) }
        defer { CCCryptorRelease(cryptor) }
        let zeros = [UInt8](repeating: 0, count: length)
        var out = [UInt8](repeating: 0, count: length)
        var moved = 0
        CCCryptorUpdate(cryptor, zeros, length, &out, length, &moved)
        return Data(out)
    }

    static func xor(_ data: Data, key: Data, iv: [UInt8]) -> Data {
        let stream = [UInt8](keystream(key: key, iv: iv, length: data.count))
        return Data(zip([UInt8](data), stream).map { $0 ^ $1 })
    }

    /// RFC 3711 4.3.1 key derivation with a key derivation rate of 0.
    static func derive(_ masterKey: Data, _ masterSalt: Data, label: UInt8, length: Int) -> Data {
        var x = [UInt8](repeating: 0, count: 16)
        let salt = [UInt8](masterSalt)
        for i in 0..<14 { x[i] = salt[i] }
        x[7] ^= label  // label << 48 within the 112-bit salt, before the << 16
        return keystream(key: masterKey, iv: x, length: length)
    }
}

/// RTP packets, as the SDK's rtc/rtp.py.
struct MuseRTPPacket {
    let payloadType: UInt8
    let marker: Bool
    let sequence: UInt16
    let timestamp: UInt32
    let ssrc: UInt32
    let payload: Data

    static func isRTCP(_ data: Data) -> Bool {
        data.count >= 8 && (192...223).contains(data[data.startIndex + 1])
    }

    static func parse(_ data: Data) throws -> MuseRTPPacket {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0] >> 6 == 2 else { throw MuseSRTPError.malformed("not RTP") }
        var offset = 12 + 4 * Int(bytes[0] & 0x0F)
        if bytes[0] & 0x10 != 0 {
            guard bytes.count >= offset + 4 else { throw MuseSRTPError.malformed("bad RTP extension") }
            offset += 4 + 4 * Int(MuseSTUN.read16(bytes, offset + 2))
        }
        var end = bytes.count
        if bytes[0] & 0x20 != 0, let padding = bytes.last { end -= Int(padding) }
        guard offset <= end else { throw MuseSRTPError.malformed("bad RTP lengths") }
        return MuseRTPPacket(
            payloadType: bytes[1] & 0x7F, marker: bytes[1] & 0x80 != 0,
            sequence: MuseSTUN.read16(bytes, 2), timestamp: MuseSTUN.read32(bytes, 4), ssrc: MuseSTUN.read32(bytes, 8),
            payload: Data(bytes[offset..<end])
        )
    }

    static func build(payloadType: UInt8, sequence: UInt16, timestamp: UInt32, ssrc: UInt32,
                      payload: Data, marker: Bool = false) -> Data {
        Data([0x80, payloadType | (marker ? 0x80 : 0)]) + MuseSTUN.be16(sequence) + MuseSTUN.be32(timestamp)
            + MuseSTUN.be32(ssrc) + payload
    }

    /// RTCP picture loss indication: asks Muse for a keyframe.
    static func pictureLossIndication(sender: UInt32, media: UInt32) -> Data {
        Data([0x81, 206]) + MuseSTUN.be16(2) + MuseSTUN.be32(sender) + MuseSTUN.be32(media)
    }
}
