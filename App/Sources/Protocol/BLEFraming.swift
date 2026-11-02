import Foundation

enum BLEFraming {
    static let magic: UInt8 = 0xFE
    static let headerBytes = 3
    static let maxPacketBytes = 160
    static let maxChunks = 255
    static let maxMessageBytes = 8192

    static func encode(_ data: Data, mtu: Int) throws -> [Data] {
        let notifyMax = min(mtu > 3 ? mtu - 3 : 20, maxPacketBytes)
        let usable = notifyMax - headerBytes
        guard usable > 0 else { throw BLEFramingError.invalidMTU }

        let fragments: [Data]
        if data.isEmpty {
            fragments = [Data()]
        } else {
            fragments = stride(from: 0, to: data.count, by: usable).map {
                data.subdata(in: $0..<min($0 + usable, data.count))
            }
        }
        guard fragments.count <= maxChunks else { throw BLEFramingError.tooLarge }

        return fragments.enumerated().map { index, fragment in
            Data([magic, UInt8(index), UInt8(fragments.count)]) + fragment
        }
    }
}

enum BLEFramingError: Error {
    case invalidMTU
    case tooLarge
}

final class BLEChunkAssembler {
    private var buffer = Data()
    private var total = 0
    private var next = 0

    func reset() {
        buffer.removeAll(keepingCapacity: true)
        total = 0
        next = 0
    }

    func feed(_ packet: Data) -> Data? {
        guard packet.count >= BLEFraming.headerBytes, packet.first == BLEFraming.magic else {
            return packet
        }

        let index = Int(packet[packet.startIndex + 1])
        let incomingTotal = Int(packet[packet.startIndex + 2])
        guard incomingTotal > 0 else { reset(); return nil }
        if index == 0 || incomingTotal != total {
            reset()
            total = incomingTotal
        }
        guard index == next, index < total else { reset(); return nil }

        let fragment = packet.dropFirst(BLEFraming.headerBytes)
        guard buffer.count + fragment.count <= BLEFraming.maxMessageBytes else {
            reset()
            return nil
        }
        buffer.append(fragment)
        next += 1
        guard next == total else { return nil }
        let message = buffer
        reset()
        return message
    }
}

