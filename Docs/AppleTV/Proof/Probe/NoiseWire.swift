import Foundation

enum MuseWireError: Error {
    case malformed
    case oversized
}

struct MuseApplicationResponse {
    let status: Int
    let body: Data
    let endBody: Bool
}

struct MuseBodyChunk {
    let data: Data
    let endBody: Bool
}

struct MuseHTTPHeader {
    let name: String
    let value: String
}

enum MuseInboundServiceFrame {
    case response(streamID: Int64, MuseApplicationResponse)
    case body(streamID: Int64, MuseBodyChunk)
    case reset(streamID: Int64, reason: String)
}

private enum MuseProto {
    static func varint(_ value: UInt64) -> Data {
        var value = value
        var result = Data()
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            result.append(byte)
        } while value != 0
        return result
    }

    static func field(_ number: Int, varint value: UInt64) -> Data {
        varint(UInt64(number << 3)) + varint(value)
    }

    static func field(_ number: Int, bytes: Data) -> Data {
        varint(UInt64((number << 3) | 2)) + varint(UInt64(bytes.count)) + bytes
    }

    static func field(_ number: Int, string: String) -> Data {
        field(number, bytes: Data(string.utf8))
    }
}

private struct MuseProtoReader {
    let data: Data
    var offset = 0

    mutating func key() throws -> (Int, Int) {
        let value = try varint()
        let number = Int(value >> 3)
        let wire = Int(value & 7)
        guard number > 0, wire == 0 || wire == 1 || wire == 2 || wire == 5 else {
            throw MuseWireError.malformed
        }
        return (number, wire)
    }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        for index in 0..<10 {
            guard offset < data.count else { throw MuseWireError.malformed }
            let byte = data[offset]
            offset += 1
            if index == 9, byte & 0xfe != 0 { throw MuseWireError.malformed }
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        throw MuseWireError.malformed
    }

    mutating func delimited() throws -> Data {
        let length = try varint()
        guard length <= UInt64(Int.max) else { throw MuseWireError.oversized }
        let end = offset + Int(length)
        guard end >= offset, end <= data.count else { throw MuseWireError.malformed }
        defer { offset = end }
        return data.subdata(in: offset..<end)
    }

    mutating func skip(wire: Int) throws {
        switch wire {
        case 0: _ = try varint()
        case 1:
            guard offset + 8 <= data.count else { throw MuseWireError.malformed }
            offset += 8
        case 2: _ = try delimited()
        case 5:
            guard offset + 4 <= data.count else { throw MuseWireError.malformed }
            offset += 4
        default: throw MuseWireError.malformed
        }
    }
}

enum MuseNoiseWire {
    static func startControlStream(streamID: Int64) -> Data {
        applicationRequest(streamID: streamID, method: "POST", path: "/link-control")
    }

    static func applicationRequest(
        streamID: Int64,
        method: String,
        path: String,
        headers: [MuseHTTPHeader] = [],
        body: Data = Data(),
        endBody: Bool = false
    ) -> Data {
        var request = Data()
        request += MuseProto.field(1, string: method)
        request += MuseProto.field(2, string: path)
        for header in headers {
            var encoded = MuseProto.field(1, string: header.name)
            encoded += MuseProto.field(2, string: header.value)
            request += MuseProto.field(3, bytes: encoded)
        }
        if !body.isEmpty { request += MuseProto.field(4, bytes: body) }
        if endBody { request += MuseProto.field(5, varint: 1) }

        var frame = MuseProto.field(1, varint: UInt64(bitPattern: streamID))
        frame += MuseProto.field(2, bytes: request)
        return MuseProto.field(2, bytes: frame)
    }

    static func reset(streamID: Int64, reason: String) -> Data {
        var reset = MuseProto.field(1, varint: 1)
        if !reason.isEmpty { reset += MuseProto.field(2, string: reason) }
        var frame = MuseProto.field(1, varint: UInt64(bitPattern: streamID))
        frame += MuseProto.field(5, bytes: reset)
        return MuseProto.field(2, bytes: frame)
    }

    static func bodyChunk(streamID: Int64, data: Data, endBody: Bool = false) -> Data {
        var chunk = Data()
        if !data.isEmpty { chunk += MuseProto.field(1, bytes: data) }
        if endBody { chunk += MuseProto.field(2, varint: 1) }

        var frame = MuseProto.field(1, varint: UInt64(bitPattern: streamID))
        frame += MuseProto.field(4, bytes: chunk)
        return MuseProto.field(2, bytes: frame)
    }

    /// Splits a body so no single Noise frame comes near the 65,489-byte transport limit.
    static func bodyChunks(streamID: Int64, data: Data, endBody: Bool = false, chunkSize: Int = 16 * 1024) -> [Data] {
        guard !data.isEmpty else { return [bodyChunk(streamID: streamID, data: data, endBody: endBody)] }
        return stride(from: 0, to: data.count, by: chunkSize).map { offset in
            let end = min(offset + chunkSize, data.count)
            return bodyChunk(
                streamID: streamID,
                data: data.subdata(in: data.startIndex + offset..<data.startIndex + end),
                endBody: endBody && end == data.count
            )
        }
    }

    static func noiseFrame(payload: Data, chunkID: Int64 = Int64.random(in: Int64.min...Int64.max)) -> Data {
        var frame = MuseProto.field(1, varint: UInt64(bitPattern: chunkID))
        frame += MuseProto.field(3, varint: 1)
        if !payload.isEmpty { frame += MuseProto.field(4, bytes: payload) }
        return frame
    }

    static func decodeNoiseFrame(_ data: Data) throws -> (chunkID: Int64, index: Int, total: Int, payload: Data) {
        var reader = MuseProtoReader(data: data)
        var chunkID: Int64 = 0
        var index = 0
        var total = 1
        var payload = Data()
        while reader.offset < data.count {
            let (field, wire) = try reader.key()
            switch field {
            case 1 where wire == 0: chunkID = Int64(bitPattern: try reader.varint())
            case 2 where wire == 0:
                let raw = try reader.varint()
                guard raw <= UInt64(Int.max) else { throw MuseWireError.malformed }
                index = Int(raw)
            case 3 where wire == 0:
                let raw = try reader.varint()
                guard raw <= UInt64(Int.max) else { throw MuseWireError.malformed }
                total = Int(raw)
            case 4 where wire == 2: payload = try reader.delimited()
            default: try reader.skip(wire: wire)
            }
        }
        guard total > 0, total <= 256, index >= 0, index < total else {
            throw MuseWireError.malformed
        }
        return (chunkID, index, total, payload)
    }

    static func decodeServiceFrame(_ data: Data) throws -> MuseInboundServiceFrame? {
        var responseReader = MuseProtoReader(data: data)
        var servicePayload = Data()
        while responseReader.offset < data.count {
            let (field, wire) = try responseReader.key()
            if field == 1, wire == 2 { servicePayload = try responseReader.delimited() }
            else { try responseReader.skip(wire: wire) }
        }
        guard !servicePayload.isEmpty else { throw MuseWireError.malformed }

        var frameReader = MuseProtoReader(data: servicePayload)
        var streamID: Int64 = 0
        var result: MuseInboundServiceFrame?
        while frameReader.offset < servicePayload.count {
            let (field, wire) = try frameReader.key()
            switch field {
            case 1 where wire == 0:
                streamID = Int64(bitPattern: try frameReader.varint())
            case 3 where wire == 2:
                let value = try decodeApplicationResponse(frameReader.delimited())
                result = .response(streamID: streamID, value)
            case 4 where wire == 2:
                let value = try decodeBodyChunk(frameReader.delimited())
                result = .body(streamID: streamID, value)
            case 5 where wire == 2:
                let reason = try decodeResetReason(frameReader.delimited())
                result = .reset(streamID: streamID, reason: reason)
            default:
                try frameReader.skip(wire: wire)
            }
        }
        return result
    }

    static func controlMessage(_ object: [String: Any]) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard json.count <= 4 * 1024 * 1024 else { throw MuseWireError.oversized }
        var length = UInt32(json.count).littleEndian
        var result = Data(bytes: &length, count: 4)
        result.append(json)
        return result
    }

    private static func decodeApplicationResponse(_ data: Data) throws -> MuseApplicationResponse {
        var reader = MuseProtoReader(data: data)
        var status = 0
        var body = Data()
        var end = false
        while reader.offset < data.count {
            let (field, wire) = try reader.key()
            switch field {
            case 1 where wire == 0: status = Int(try reader.varint())
            case 3 where wire == 2: body = try reader.delimited()
            case 4 where wire == 0: end = try reader.varint() != 0
            default: try reader.skip(wire: wire)
            }
        }
        return MuseApplicationResponse(status: status, body: body, endBody: end)
    }

    private static func decodeBodyChunk(_ data: Data) throws -> MuseBodyChunk {
        var reader = MuseProtoReader(data: data)
        var body = Data()
        var end = false
        while reader.offset < data.count {
            let (field, wire) = try reader.key()
            switch field {
            case 1 where wire == 2: body = try reader.delimited()
            case 2 where wire == 0: end = try reader.varint() != 0
            default: try reader.skip(wire: wire)
            }
        }
        return MuseBodyChunk(data: body, endBody: end)
    }

    private static func decodeResetReason(_ data: Data) throws -> String {
        var reader = MuseProtoReader(data: data)
        var reason = ""
        while reader.offset < data.count {
            let (field, wire) = try reader.key()
            if field == 2, wire == 2 {
                reason = String(data: try reader.delimited(), encoding: .utf8) ?? ""
            } else {
                try reader.skip(wire: wire)
            }
        }
        return reason
    }
}

final class MuseNoiseFrameDecoder {
    private struct Assembly {
        var chunks: [Int: Data]
        let total: Int
        var byteCount: Int
        let createdAt: Date
    }

    private var assemblies: [Int64: Assembly] = [:]
    private let maxAssemblies = 16
    private let assemblyTTL: TimeInterval = 60

    func decode(_ data: Data) throws -> Data? {
        let frame = try MuseNoiseWire.decodeNoiseFrame(data)
        let now = Date()
        assemblies = assemblies.filter { now.timeIntervalSince($0.value.createdAt) <= assemblyTTL }
        if assemblies[frame.chunkID] == nil, assemblies.count >= maxAssemblies {
            throw MuseWireError.oversized
        }
        var assembly = assemblies[frame.chunkID]
            ?? Assembly(chunks: [:], total: frame.total, byteCount: 0, createdAt: now)
        guard assembly.total == frame.total, assembly.chunks[frame.index] == nil else {
            assemblies.removeValue(forKey: frame.chunkID)
            throw MuseWireError.malformed
        }
        assembly.chunks[frame.index] = frame.payload
        assembly.byteCount += frame.payload.count
        guard assembly.byteCount <= 16 * 1024 * 1024 else {
            assemblies.removeValue(forKey: frame.chunkID)
            throw MuseWireError.oversized
        }
        if assembly.chunks.count < assembly.total {
            assemblies[frame.chunkID] = assembly
            return nil
        }
        assemblies.removeValue(forKey: frame.chunkID)
        return try (0..<assembly.total).reduce(into: Data()) { result, index in
            guard let chunk = assembly.chunks[index] else { throw MuseWireError.malformed }
            result.append(chunk)
        }
    }
}

final class MuseControlMessageDecoder {
    private var buffer = Data()

    func feed(_ data: Data) throws -> [[String: Any]] {
        buffer.append(data)
        var messages: [[String: Any]] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).enumerated().reduce(UInt32(0)) {
                $0 | (UInt32($1.element) << UInt32($1.offset * 8))
            }
            guard length <= 4 * 1024 * 1024 else { throw MuseWireError.oversized }
            let end = 4 + Int(length)
            guard buffer.count >= end else { break }
            let raw = buffer.subdata(in: 4..<end)
            buffer.removeSubrange(0..<end)
            guard !raw.isEmpty else { continue }
            if let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any] {
                messages.append(object)
            }
        }
        return messages
    }
}

final class MuseNDJSONDecoder {
    private var buffer = Data()
    private let maximumRecordBytes: Int

    init(maximumRecordBytes: Int = 256 * 1024) {
        self.maximumRecordBytes = maximumRecordBytes
    }

    func feed(_ data: Data, end: Bool = false) throws -> [[String: Any]] {
        buffer.append(data)
        guard buffer.count <= maximumRecordBytes else { throw MuseWireError.oversized }
        var records: [[String: Any]] = []
        while let newline = buffer.firstIndex(of: 0x0a) {
            let raw = buffer.subdata(in: 0..<newline)
            buffer.removeSubrange(0...newline)
            if let value = decode(raw) { records.append(value) }
        }
        if end, !buffer.isEmpty {
            let raw = buffer
            buffer.removeAll(keepingCapacity: false)
            if let value = decode(raw) { records.append(value) }
        }
        return records
    }

    private func decode(_ raw: Data) -> [String: Any]? {
        guard !raw.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            return nil
        }
        return object
    }
}
