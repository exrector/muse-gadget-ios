import XCTest
@testable import MuseGadgetLegacy

final class MuseGadgetLegacyTests: XCTestCase {
    func testIdentityConventionsMatchMuseApps() {
        let identity = DeviceIdentity(mac: "02:11:22:aa:bb:cc")
        XCTAssertEqual(identity.suffix, "aabbcc")
        XCTAssertEqual(identity.nodeID, "homelink-aabbcc")
        XCTAssertEqual(identity.deviceID, "hatch-link:02:11:22:aa:bb:cc")
        XCTAssertEqual(identity.bluetoothName, "MuseGadgetAABBCC")
    }

    func testBLEFramingRoundTrip() throws {
        let payload = Data((0..<600).map { UInt8($0 % 251) })
        let frames = try BLEFraming.encode(payload, mtu: 80)
        let assembler = BLEChunkAssembler()
        let rebuilt = frames.compactMap(assembler.feed).last
        XCTAssertEqual(rebuilt, payload)
    }

    func testOutOfOrderBLEFrameIsRejected() throws {
        let frames = try BLEFraming.encode(Data(repeating: 7, count: 300), mtu: 64)
        XCTAssertGreaterThan(frames.count, 2)
        let assembler = BLEChunkAssembler()
        XCTAssertNil(assembler.feed(frames[1]))
        XCTAssertNil(assembler.feed(frames[0]))
        XCTAssertNil(assembler.feed(frames[2]))
    }

    func testHKDFExpandMatchesRFC5869Vector() {
        let prk = Data([
            0x07, 0x77, 0x09, 0x36, 0x2c, 0x2e, 0x32, 0xdf, 0x0d, 0xdc, 0x3f,
            0x0d, 0xc4, 0x7b, 0xba, 0x63, 0x90, 0xb6, 0xc7, 0x3b, 0xb5, 0x0f,
            0x9c, 0x31, 0x22, 0xec, 0x84, 0x4a, 0xd7, 0xc2, 0xb3, 0xe5
        ])
        let info = Data([0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9])
        let output = HKDFTools.expand(prk: prk, info: info, count: 42)
        XCTAssertEqual(output.map { String(format: "%02x", $0) }.joined(),
                       "3cb25f25faacd57a90434f64d0362f2a" +
                       "2d2d0a90cf1a5a4c5db02d56ecc4c5bf" +
                       "34007208d5b887185865")
    }
}

