// Ported from the Muse Gadget SDK, branch anantn/linux-video-calls (commit 77c7e27),
// linux/src/musegadget/rtc/stun.py. Copyright (c) Meta Platforms, Inc. and affiliates.
// Licensed under the Apache License, Version 2.0.

import CryptoKit
import Foundation
import Security

/// Minimal STUN for ICE-lite connectivity checks and consent (RFC 5389/8445).
enum MuseSTUN {
    static let magic: UInt32 = 0x2112_A442
    static let bindingRequest: UInt16 = 0x0001
    static let bindingSuccess: UInt16 = 0x0101

    private static let username: UInt16 = 0x0006
    private static let messageIntegrity: UInt16 = 0x0008
    private static let priority: UInt16 = 0x0024
    private static let useCandidate: UInt16 = 0x0025
    private static let fingerprint: UInt16 = 0x8028
    private static let iceControlling: UInt16 = 0x802A

    static func isSTUN(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(8))
        return data.count >= 20 && bytes[0] < 2 && read32(bytes, 4) == magic
    }

    /// A controlling check, nominating the path if asked. Returns the packet and its transaction id.
    static func bindingRequest(username user: String, password: String, priority value: UInt32,
                               tieBreaker: UInt64, nominate: Bool = true) -> (packet: Data, transactionID: Data) {
        var id = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, id.count, &id)
        let transactionID = Data(id)
        var attributes = attribute(username, Data(user.utf8))
            + attribute(priority, be32(value))
            + attribute(iceControlling, be64(tieBreaker))
        if nominate { attributes += attribute(useCandidate, Data()) }
        var header = be16(bindingRequest) + be16(UInt16(attributes.count + 24)) + be32(magic) + transactionID
        let mac = Data(HMAC<Insecure.SHA1>.authenticationCode(for: header + attributes, using: SymmetricKey(data: Data(password.utf8))))
        attributes += attribute(messageIntegrity, mac)
        header = be16(bindingRequest) + be16(UInt16(attributes.count + 8)) + be32(magic) + transactionID
        let crc = crc32(header + attributes) ^ 0x5354_554E
        attributes += attribute(fingerprint, be32(crc))
        return (header + attributes, transactionID)
    }

    /// True for an authenticated success response to `transactionID`.
    static func isSuccess(_ data: Data, transactionID: Data, password: String) -> Bool {
        guard isSTUN(data) else { return false }
        let bytes = [UInt8](data)
        guard Data(bytes[8..<20]) == transactionID else { return false }
        let kind = read16(bytes, 0)
        let length = Int(read16(bytes, 2))
        guard kind == bindingSuccess, bytes.count >= 20 + length else { return false }
        var offset = 20
        while offset + 4 <= 20 + length {
            let type = read16(bytes, offset)
            let size = Int(read16(bytes, offset + 2))
            if type == messageIntegrity {
                guard offset + 24 <= bytes.count else { return false }
                var prefix = Array(bytes[0..<offset])
                let adjusted = UInt16(offset - 20 + 24)
                prefix[2] = UInt8(adjusted >> 8)
                prefix[3] = UInt8(adjusted & 0xFF)
                let expected = Data(HMAC<Insecure.SHA1>.authenticationCode(for: Data(prefix), using: SymmetricKey(data: Data(password.utf8))))
                return expected == Data(bytes[(offset + 4)..<(offset + 24)])
            }
            offset += 4 + size + (4 - size % 4) % 4
        }
        return false
    }

    private static func attribute(_ type: UInt16, _ value: Data) -> Data {
        let pad = (4 - value.count % 4) % 4
        return be16(type) + be16(UInt16(value.count)) + value + Data(count: pad)
    }

    static func be16(_ value: UInt16) -> Data { Data([UInt8(value >> 8), UInt8(value & 0xFF)]) }
    static func be32(_ value: UInt32) -> Data { Data((0..<4).map { UInt8((value >> (24 - 8 * $0)) & 0xFF) }) }
    static func be64(_ value: UInt64) -> Data { Data((0..<8).map { UInt8((value >> (56 - 8 * $0)) & 0xFF) }) }
    static func read16(_ bytes: [UInt8], _ at: Int) -> UInt16 { UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1]) }
    static func read32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
    }

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    /// The CRC-32 STUN's FINGERPRINT uses, the same as zlib's.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
