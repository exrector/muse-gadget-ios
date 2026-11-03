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

    func testNoiseCipherMatchesOfficialSDKVector() throws {
        let cipher = MuseNoiseCipherState()
        try cipher.initializeKey(Data(0..<32))
        XCTAssertEqual(
            try cipher.encrypt(ad: Data("ad".utf8), plaintext: Data("hello".utf8)).hex,
            "66d9d9b2da11bae424ce671b6e7ef04a4d98656a32"
        )
        XCTAssertEqual(
            try cipher.encrypt(ad: Data(), plaintext: Data()).hex,
            "367ef8288831557408e102950a16e26a"
        )
    }

    func testControlStreamEnvelopeMatchesOfficialSDK() {
        let request = MuseNoiseWire.startControlStream(streamID: 1)
        XCTAssertEqual(
            request.hex,
            "1219080112150a04504f5354120d2f6c696e6b2d636f6e74726f6c"
        )
        XCTAssertEqual(
            MuseNoiseWire.noiseFrame(payload: request, chunkID: 7).hex,
            "08071801221b1219080112150a04504f5354120d2f6c696e6b2d636f6e74726f6c"
        )
    }

    func testChatRequestEnvelopeMatchesOfficialSDK() {
        let request = MuseNoiseWire.applicationRequest(
            streamID: 2,
            method: "POST",
            path: "/chat/stream",
            headers: [
                MuseHTTPHeader(name: "Content-Type", value: "application/json"),
                MuseHTTPHeader(name: "x-app-id", value: "musegadget")
            ],
            body: Data(#"{"message":"hi"}"#.utf8),
            endBody: true
        )
        XCTAssertEqual(
            request.hex,
            "1266080212620a04504f5354120c2f636861742f73747265616d" +
            "1a200a0c436f6e74656e742d5479706512106170706c69636174696f6e2f6a736f6e" +
            "1a160a08782d6170702d6964120a6d757365676164676574" +
            "22107b226d657373616765223a226869227d2801"
        )
    }

    func testNDJSONDecoderHandlesFragmentedUTF8AndFinalRecord() throws {
        let decoder = MuseNDJSONDecoder()
        let event = #"{"type":"event","event":"delta.text_append","payload":{"text":"café"}}"#
        let encoded = Data(event.utf8)
        let split = try XCTUnwrap(encoded.firstIndex(of: 0xc3)).advanced(by: 1)
        XCTAssertTrue(try decoder.feed(encoded.prefix(upTo: split)).isEmpty)
        let records = try decoder.feed(encoded.suffix(from: split) + Data("\n".utf8))
        XCTAssertEqual(records.first?["event"] as? String, "delta.text_append")
        XCTAssertEqual((records.first?["payload"] as? [String: Any])?["text"] as? String, "café")

        let done = Data(#"{"type":"event","event":"delta.message_done","payload":{"message_id":"reply-1"}}"#.utf8)
        let final = try decoder.feed(done, end: true)
        XCTAssertEqual((final.first?["payload"] as? [String: Any])?["message_id"] as? String, "reply-1")
    }

    func testBodyChunkAndResetMatchOfficialSDK() {
        XCTAssertEqual(
            MuseNoiseWire.bodyChunk(streamID: 2, data: Data("hi".utf8), endBody: true).hex,
            "120a080222060a0268691001"
        )
        XCTAssertEqual(
            MuseNoiseWire.reset(streamID: 3, reason: "request ended").hex,
            "121508032a110801120d7265717565737420656e646564"
        )
    }

    func testBodyChunksSplitAndMarkOnlyTheLastPart() {
        let body = Data((0..<40_000).map { UInt8($0 % 251) })
        let parts = MuseNoiseWire.bodyChunks(streamID: 7, data: body, endBody: true)
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0], MuseNoiseWire.bodyChunk(streamID: 7, data: body.prefix(16_384)))
        XCTAssertEqual(
            parts[2],
            MuseNoiseWire.bodyChunk(streamID: 7, data: body.suffix(40_000 - 32_768), endBody: true)
        )
    }

    func testTimelineReplacesDeltasWithFinalMessageWithoutDuplicates() {
        let timeline = acknowledgedTimeline()
        _ = timeline.feed(chatEvent("delta.text_append", ["message_id": "reply-1", "text": "Прив"]))
        XCTAssertEqual(
            timeline.feed(chatEvent("delta.text_append", ["message_id": "reply-1", "text": "ет"])),
            [.reply(messageID: "reply-1", text: "Привет", done: false)]
        )
        XCTAssertEqual(
            timeline.feed(chatEvent("delta.message_done", ["message_id": "reply-1"])),
            [.reply(messageID: "reply-1", text: "Привет", done: true)]
        )
        XCTAssertEqual(
            timeline.feed(chatEvent("message.assistant", ["message_id": "reply-1", "display_text": "Привет!"])),
            [.reply(messageID: "reply-1", text: "Привет!", done: true)]
        )
    }

    func testTimelineHoldsEventsUntilAcknowledged() {
        let timeline = MuseChatTimeline()
        timeline.expectRequest()
        XCTAssertTrue(timeline.feed(chatEvent("delta.text_append", [
            "message_id": "reply-1", "reply_to_message_id": "user-1", "text": "ok"
        ])).isEmpty)
        XCTAssertEqual(
            timeline.acknowledge(["result": ["message_id": "user-1", "session_id": "main"]]),
            [.reply(messageID: "reply-1", text: "ok", done: false)]
        )
    }

    func testTimelineDropsForeignRepliesOtherChatsAndUserEcho() {
        let timeline = acknowledgedTimeline()
        XCTAssertTrue(timeline.feed(chatEvent("delta.text_append", [
            "message_id": "foreign", "reply_to_message_id": "someone-else", "text": "x"
        ])).isEmpty)
        // An ignored message stays ignored even when a later event names no parent.
        XCTAssertTrue(timeline.feed(chatEvent("message.assistant", [
            "message_id": "foreign", "display_text": "x"
        ])).isEmpty)
        XCTAssertTrue(timeline.feed(chatEvent("delta.text_append", [
            "message_id": "side", "session_id": "other-chat", "text": "x"
        ])).isEmpty)
        XCTAssertTrue(timeline.feed(chatEvent("message.assistant", [
            "message_id": "user-1", "role": "user", "display_text": "echo"
        ])).isEmpty)
    }

    func testTimelineIgnoresEverythingBeforeTheFirstRequest() {
        XCTAssertTrue(MuseChatTimeline().feed(chatEvent("message.assistant", [
            "message_id": "old", "display_text": "history"
        ])).isEmpty)
    }

    func testTimelineReadsStructuredTranscriptAndRespectsReadyFlag() {
        let timeline = acknowledgedTimeline()
        let transcript: [String: Any] = ["messages": [
            ["role": "user", "id": "user-1", "content": [["type": "text", "text": "вопрос"]]],
            ["role": "assistant", "id": "reply-2", "content": [["type": "text", "text": "ответ"]]]
        ]]
        XCTAssertEqual(
            timeline.feed(chatEvent("message.assistant", [
                "message_id": "reply-2", "transcript": transcript, "display_text_ready": false
            ])),
            [.reply(messageID: "reply-2", text: "ответ", done: false)]
        )
    }

    func testTimelineStripsControlCharactersAndFinishesOnTerminalTask() {
        let timeline = acknowledgedTimeline()
        XCTAssertEqual(
            timeline.feed(chatEvent("delta.text_append", ["message_id": "r", "text": "a\u{1b}[31mb\nc"])),
            [.reply(messageID: "r", text: "a[31mb\nc", done: false)]
        )
        XCTAssertEqual(
            timeline.feed(chatEvent("task.status", ["status": "completed", "reply_to_message_id": "user-1"])),
            [.finished]
        )
        XCTAssertTrue(timeline.feed(chatEvent("task.status", [
            "status": "completed", "reply_to_message_id": "someone-else"
        ])).isEmpty)
    }

    func testHapticRouteMatchesDeviceGeneration() {
        XCTAssertEqual(MuseHapticRoute.route(machine: "iPhone8,1"), .systemVibration)
        XCTAssertEqual(MuseHapticRoute.route(machine: "iPhone7,2"), .systemVibration)
        XCTAssertEqual(MuseHapticRoute.route(machine: "iPhone9,1"), .impactGenerator)
        XCTAssertEqual(MuseHapticRoute.route(machine: "iPhone16,2"), .impactGenerator)
        XCTAssertEqual(MuseHapticRoute.route(machine: "iPad7,5"), .unavailable)
        XCTAssertEqual(MuseHapticRoute.route(machine: "arm64"), .unavailable)
    }

    func testRefreshAuthorizationNeverDoublesThePrefix() {
        XCTAssertEqual(MuseAPIClient.refreshAuthorization("abc"), "Bearer hatch_refresh:abc")
        XCTAssertEqual(MuseAPIClient.refreshAuthorization("hatch_refresh:abc"), "Bearer hatch_refresh:abc")
    }

    func testRotatedTokensParseWrappedAndRejectPartialResponses() {
        let expected = MuseRotatedTokens(accessToken: "a", refreshToken: "r")
        XCTAssertEqual(MuseAPIClient.parseRotatedTokens(Data(#"{"access_token":"a","refresh_token":"r"}"#.utf8)), expected)
        XCTAssertEqual(
            MuseAPIClient.parseRotatedTokens(Data(#"{"payload":{"access_token":"a","refresh_token":"r"}}"#.utf8)),
            expected
        )
        XCTAssertNil(MuseAPIClient.parseRotatedTokens(Data(#"{"access_token":"a"}"#.utf8)))
    }

    func testReconnectDelayMatchesSDKBackoff() {
        XCTAssertEqual(MuseRuntime.reconnectDelay(failures: 0), 2)
        XCTAssertEqual(MuseRuntime.reconnectDelay(failures: 1), 4)
        XCTAssertEqual(MuseRuntime.reconnectDelay(failures: 50), 60)
        XCTAssertEqual(MuseRuntime.reconnectDelay(failures: 0, floor: 15), 15)
    }

    func testBoundedJPEGRespectsSizeAndDimension() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2_000, height: 1_000)).image { context in
            for x in stride(from: 0, to: 2_000, by: 20) {
                UIColor(hue: CGFloat(x) / 2_000, saturation: 1, brightness: 1, alpha: 1).setFill()
                context.fill(CGRect(x: x, y: 0, width: 20, height: 1_000))
            }
        }
        let original = try XCTUnwrap(image.jpegData(compressionQuality: 1))
        let bounded = try XCTUnwrap(MuseJPEG.bounded(original, maxBytes: 96 * 1024, maxDimension: 800))
        XCTAssertLessThanOrEqual(bounded.count, 96 * 1024)
        let decoded = try XCTUnwrap(UIImage(data: bounded))
        XCTAssertLessThanOrEqual(max(decoded.size.width, decoded.size.height) * decoded.scale, 800)
    }

    private func acknowledgedTimeline() -> MuseChatTimeline {
        let timeline = MuseChatTimeline()
        timeline.expectRequest()
        _ = timeline.acknowledge(["message_id": "user-1", "session_id": "main"])
        return timeline
    }

    private func chatEvent(_ name: String, _ payload: [String: Any]) -> [String: Any] {
        ["type": "event", "event": name, "payload": payload]
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

