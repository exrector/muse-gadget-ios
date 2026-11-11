// Ported from the Muse Gadget SDK, branch anantn/linux-video-calls (commit 77c7e27),
// linux/src/musegadget/rtc/join.py. Copyright (c) Meta Platforms, Inc. and affiliates.
// Licensed under the Apache License, Version 2.0.

import CryptoKit
import Foundation
import Security

/// Thrift Compact encoding, enough for a video call's JOIN request.
struct MuseThriftWriter {
    private(set) var data = Data()
    private var last: [Int] = [0]

    private mutating func varint(_ value: UInt64) {
        var n = value
        repeat {
            var byte = UInt8(n & 0x7F)
            n >>= 7
            if n != 0 { byte |= 0x80 }
            data.append(byte)
        } while n != 0
    }

    private mutating func field(_ id: Int, kind: UInt8) {
        let delta = id - last[last.count - 1]
        if delta > 0 && delta <= 15 {
            data.append(UInt8(delta << 4) | kind)
        } else {
            data.append(kind)
            varint(UInt64(bitPattern: Int64((id << 1) ^ (id >> 63))))
        }
        last[last.count - 1] = id
    }

    mutating func i32(_ id: Int, _ value: Int32) {
        field(id, kind: 5)
        varint(UInt64(UInt32(bitPattern: (value << 1) ^ (value >> 31))))
    }

    mutating func boolean(_ id: Int, _ value: Bool) {
        field(id, kind: value ? 1 : 2)
    }

    mutating func binary(_ id: Int, _ value: Data) {
        field(id, kind: 8)
        varint(UInt64(value.count))
        data.append(value)
    }

    mutating func binary(_ id: Int, _ value: String) {
        binary(id, Data(value.utf8))
    }

    mutating func begin(_ id: Int) {
        field(id, kind: 12)
        last.append(0)
    }

    mutating func end() {
        data.append(0)
        last.removeLast()
    }

    /// Ends the top-level struct and starts another, as the SDK writes a header then a body.
    mutating func stop() {
        data.append(0)
        last = [0]
    }
}

enum MuseThriftError: Error {
    case malformed(String)
}

/// Thrift Compact decoding for one small message. Values are Int, Bool, Data, [Any] or [Int: Any].
struct MuseThriftReader {
    private let data: [UInt8]
    private var position = 0
    private var depth = 0

    init(_ data: Data) {
        self.data = [UInt8](data)
    }

    private mutating func byte() throws -> UInt8 {
        guard position < data.count else { throw MuseThriftError.malformed("truncated") }
        position += 1
        return data[position - 1]
    }

    private mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, position + count <= data.count else { throw MuseThriftError.malformed("truncated") }
        position += count
        return Data(data[(position - count)..<position])
    }

    private mutating func varint() throws -> UInt64 {
        var shift: UInt64 = 0
        var result: UInt64 = 0
        while shift < 64 {
            let next = try byte()
            result |= UInt64(next & 0x7F) << shift
            if next & 0x80 == 0 { return result }
            shift += 7
        }
        throw MuseThriftError.malformed("varint too long")
    }

    private func zigzag(_ raw: UInt64) -> Int {
        Int(Int64(bitPattern: raw >> 1) ^ -Int64(bitPattern: raw & 1))
    }

    private mutating func enter() throws {
        depth += 1
        guard depth <= 8 else { throw MuseThriftError.malformed("nested too deeply") }
    }

    private func count(_ value: Int) throws -> Int {
        guard value >= 0, value <= data.count - position else { throw MuseThriftError.malformed("container too large") }
        return value
    }

    mutating func structure() throws -> [Int: Any] {
        try enter()
        var fields: [Int: Any] = [:]
        var last = 0
        while true {
            let header = try byte()
            if header == 0 {
                depth -= 1
                return fields
            }
            let delta = Int(header >> 4)
            let kind = header & 0x0F
            let id = delta != 0 ? last + delta : zigzag(try varint())
            last = id
            fields[id] = try value(kind)
        }
    }

    private mutating func value(_ kind: UInt8, inContainer: Bool = false) throws -> Any {
        switch kind {
        case 1, 2: return inContainer ? try byte() == 1 : kind == 1
        case 3: return Int(try byte())
        case 4, 5, 6: return zigzag(try varint())
        case 7: _ = try take(8); return 0
        case 8: return try take(Int(try varint()))
        case 9, 10:
            let header = try byte()
            var size = Int(header >> 4)
            let element = header & 0x0F
            if size == 15 { size = Int(try varint()) }
            try enter()
            var items: [Any] = []
            for _ in 0..<(try count(size)) { items.append(try value(element, inContainer: true)) }
            depth -= 1
            return items
        case 11:
            let size = try count(Int(try varint()))
            if size == 0 { return [Int: Any]() }
            let kinds = try byte()
            try enter()
            var items: [Int: Any] = [:]
            for _ in 0..<size {
                let key = try value(kinds >> 4, inContainer: true)
                items[(key as? Int) ?? items.count] = try value(kinds & 0x0F, inContainer: true)
            }
            depth -= 1
            return items
        case 12: return try structure()
        default: throw MuseThriftError.malformed("unsupported type \(kind)")
        }
    }
}

/// A self-signed P-256 X.509 certificate, as the JOIN's DTLS identities need. They are required
/// fields that Muse does not use, since the SRTP key travels in the JOIN itself.
enum MuseDTLSIdentity {
    struct Identity {
        let privateKeyPEM: String
        let certificatePEM: String
        let fingerprint: String
    }

    static func make(now: Date = Date()) -> Identity {
        let key = P256.Signing.PrivateKey()
        let name = DER.sequence([DER.set([DER.sequence([DER.oid([0x55, 0x04, 0x03]), DER.utf8("musegadget")])])])
        var serial = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial)
        serial[0] &= 0x7F
        serial[0] |= 0x01
        let ecdsaWithSHA256 = DER.sequence([DER.oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])])
        let spki = DER.sequence([
            DER.sequence([DER.oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]),
                          DER.oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])]),
            DER.bitString(key.publicKey.x963Representation)
        ])
        let tbs = DER.sequence([
            DER.explicit(0, DER.integer([0x02])),
            DER.integer(serial),
            ecdsaWithSHA256,
            name,
            DER.sequence([DER.utcTime(now.addingTimeInterval(-86_400)), DER.utcTime(now.addingTimeInterval(30 * 86_400))]),
            name,
            spki
        ])
        let signature = (try? key.signature(for: tbs).derRepresentation) ?? Data()
        let certificate = DER.sequence([tbs, ecdsaWithSHA256, DER.bitString(signature)])
        let digest = SHA256.hash(data: certificate).map { String(format: "%02X", $0) }.joined(separator: ":")
        return Identity(
            privateKeyPEM: key.pemRepresentation + "\n",
            certificatePEM: pem("CERTIFICATE", certificate),
            fingerprint: "sha-256 " + digest
        )
    }

    private static func pem(_ label: String, _ der: Data) -> String {
        let base64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(label)-----\n\(base64)\n-----END \(label)-----\n"
    }

    /// The handful of DER encodings a certificate needs.
    private enum DER {
        static func element(_ tag: UInt8, _ content: Data) -> Data {
            var out = Data([tag])
            if content.count < 0x80 {
                out.append(UInt8(content.count))
            } else {
                var length = content.count
                var bytes: [UInt8] = []
                while length > 0 { bytes.insert(UInt8(length & 0xFF), at: 0); length >>= 8 }
                out.append(0x80 | UInt8(bytes.count))
                out.append(contentsOf: bytes)
            }
            out.append(content)
            return out
        }

        static func sequence(_ items: [Data]) -> Data { element(0x30, items.reduce(Data(), +)) }
        static func set(_ items: [Data]) -> Data { element(0x31, items.reduce(Data(), +)) }
        static func oid(_ bytes: [UInt8]) -> Data { element(0x06, Data(bytes)) }
        static func utf8(_ text: String) -> Data { element(0x0C, Data(text.utf8)) }
        static func bitString(_ content: Data) -> Data { element(0x03, Data([0]) + content) }
        static func explicit(_ number: UInt8, _ content: Data) -> Data { element(0xA0 | number, content) }

        static func integer(_ bytes: [UInt8]) -> Data {
            var value = bytes
            while value.count > 1, value[0] == 0, value[1] & 0x80 == 0 { value.removeFirst() }
            if let first = value.first, first & 0x80 != 0 { value.insert(0, at: 0) }
            return element(0x02, Data(value))
        }

        static func utcTime(_ date: Date) -> Data {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyMMddHHmmss'Z'"
            return element(0x17, Data(formatter.string(from: date).utf8))
        }
    }
}

/// The media-only call JOIN: the client mints every credential, as the SDK's build_join does.
struct MuseCallJoinOffer {
    static let audioTrackAssistant: Int32 = 1
    static let videoTrackAssistant: Int32 = 2
    static let videoTrackNone: Int32 = 8
    static let dtlsActive: Int32 = 1
    /// The media endpoint's vip_type as the JOIN's numeric code.
    static let endpointTypes: [String: Int32] = ["META_AI": 2, "HATCH": 8]

    let payload: Data
    let clientUfrag: String
    let serverUfrag: String
    let clientPassword: String
    let serverPassword: String
    let srtpKey: Data
    let clientSessionID: String
    let transactionID: Int32

    private static let iceCharacters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

    static func iceToken(_ length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(bytes.map { iceCharacters[Int($0) % iceCharacters.count] })
    }

    static func sessionParameters(threadID: String?) -> Data {
        var writer = MuseThriftWriter()
        writer.i32(1, 0)
        writer.binary(2, Data())
        writer.binary(3, Data())
        if let threadID, !threadID.isEmpty { writer.binary(4, threadID) }
        writer.stop()
        return writer.data
    }

    static func make(threadID: String?, edgeHost: String, edgePort: Int, vipType: Int32, video: Bool) -> MuseCallJoinOffer {
        let clientUfrag = iceToken(4)
        let serverUfrag = iceToken(16)
        let clientPassword = iceToken(24)
        let serverPassword = iceToken(24)
        var key = [UInt8](repeating: 0, count: 30)
        _ = SecRandomCopyBytes(kSecRandomDefault, key.count, &key)
        let srtpKey = Data(key)
        let client = MuseDTLSIdentity.make()
        let server = MuseDTLSIdentity.make()
        let sessionID = String(UInt64.random(in: 1_000_000_000..<10_000_000_000))
        let transactionID = Int32.random(in: 1..<Int32.max)

        var writer = MuseThriftWriter()
        writer.binary(1, sessionID)
        writer.i32(3, transactionID)
        writer.stop()
        writer.begin(1)  // body.joinRequest
        writer.binary(1, clientUfrag)
        writer.binary(2, serverUfrag)
        writer.begin(3)
        writer.binary(1, srtpKey.base64EncodedString())
        writer.binary(2, clientPassword)
        writer.binary(3, serverPassword)
        writer.binary(4, server.privateKeyPEM)
        writer.end()
        writer.binary(4, client.fingerprint)
        writer.binary(5, server.certificatePEM)
        writer.binary(6, "\(edgeHost):\(edgePort)")
        writer.i32(8, dtlsActive)
        writer.i32(11, audioTrackAssistant)
        writer.i32(12, video ? videoTrackAssistant : videoTrackNone)
        writer.i32(13, vipType)
        writer.boolean(14, false)
        writer.binary(16, sessionParameters(threadID: threadID))
        writer.end()
        writer.stop()
        return MuseCallJoinOffer(
            payload: writer.data, clientUfrag: clientUfrag, serverUfrag: serverUfrag,
            clientPassword: clientPassword, serverPassword: serverPassword, srtpKey: srtpKey,
            clientSessionID: sessionID, transactionID: transactionID
        )
    }
}

struct MuseCallJoinAnswer {
    let serverUfrag: String
    let status: Int?
    let ipv4: String
    let ipv6: String

    static func parse(_ payload: Data) throws -> MuseCallJoinAnswer {
        guard payload.count <= 16 * 1024 else { throw MuseThriftError.malformed("response too large") }
        var reader = MuseThriftReader(payload)
        let header = try reader.structure()
        let body = try reader.structure()
        guard let answer = body[2] as? [Int: Any] else { throw MuseThriftError.malformed("no joinResponse") }
        func text(_ id: Int) throws -> String {
            guard let value = answer[id] else { return "" }
            guard let data = value as? Data else { throw MuseThriftError.malformed("joinResponse field \(id)") }
            return String(decoding: data, as: UTF8.self)
        }
        let ufrag = try text(1)
        guard !ufrag.isEmpty else { throw MuseThriftError.malformed("no server ufrag") }
        let status = header[4] as? Int
        if let status, status != 200 { throw MuseThriftError.malformed("JOIN refused (\(status))") }
        return MuseCallJoinAnswer(serverUfrag: ufrag, status: status, ipv4: try text(2), ipv6: try text(3))
    }
}
