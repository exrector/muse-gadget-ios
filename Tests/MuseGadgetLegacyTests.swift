import AVFoundation
import ImageIO
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

    func testVoiceRoutesReadAudioAndSplitStreamedLines() throws {
        let pcm = Data([1, 0, 2, 0, 3, 0, 4, 0])
        let delta: [String: Any] = ["type": "response.output_audio.delta", "delta": pcm.base64EncodedString()]
        XCTAssertEqual(MuseVoiceEvents.audio(from: delta), pcm)
        let continuous: [String: Any] = ["type": "continuous_audio_video.delta", "audio_delta": [
            "format": ["type": "audio/pcm", "rate": 24_000], "audio_frames": pcm.base64EncodedString()
        ]]
        XCTAssertEqual(MuseVoiceEvents.audio(from: continuous), pcm)
        let wrongRate: [String: Any] = ["type": "continuous_audio_video.delta", "audio_delta": [
            "format": ["rate": 16_000], "audio_frames": pcm.base64EncodedString()
        ]]
        XCTAssertNil(MuseVoiceEvents.audio(from: wrongRate))
        XCTAssertNil(MuseVoiceEvents.audio(from: ["type": "hatch.voice.session"]))

        var lines = MuseNDJSONLines()
        XCTAssertTrue(lines.feed(Data("{\"type\":\"par".utf8)).isEmpty)
        let records = lines.feed(Data("tial\"}\nnot json\n{\"type\":\"final\"}\n".utf8))
        XCTAssertEqual(records.compactMap { $0["type"] as? String }, ["partial", "final"])

        let append = try XCTUnwrap(JSONSerialization.jsonObject(with: MuseVoiceEvents.appendLine(pcm).dropLast()) as? [String: Any])
        XCTAssertEqual(append["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(append["audio"] as? String, pcm.base64EncodedString())
        XCTAssertEqual(MuseRuntime.spokenTurnHint["device"] as? String, "mcu-wearable")
    }

    func testDiagnosticsLogStatesWithoutGadgetNamesOrErrorText() {
        XCTAssertEqual(MuseDiagnostics.label(PairingCoordinator.State.advertising("MuseGadgetA1B2C3")), "advertising")
        XCTAssertEqual(MuseDiagnostics.label(PairingCoordinator.State.failed("token mgst_secret")), "failed")
        XCTAssertEqual(MuseDiagnostics.label(PairingCoordinator.State.connected(mtu: 185)), "connected")
        XCTAssertEqual(MuseDiagnostics.label(PairingCoordinator.State.paired), "paired")
        XCTAssertEqual(MuseDiagnostics.label(MuseRuntimeState.failed("HTTP 401 for homelink-a1b2c3")), "failed")
        XCTAssertEqual(MuseDiagnostics.label(MuseRuntimeState.registered), "registered")
    }

    func testOnlyTestFlightBuildsCallThemselvesBeta() {
        // Unit tests run without a sandbox receipt, like an App Store or Xcode install.
        XCTAssertFalse(MuseAppVersion.isTestFlight)
        XCTAssertEqual(MuseAppVersion.display, MuseAppVersion.current)
    }

    func testFreshInstallClearsKeychainButAnUpdateKeepsIt() throws {
        let suite = "FreshInstallReset.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var clears = 0

        // A new install: nothing in UserDefaults, so the Keychain left by a deleted copy goes.
        XCTAssertTrue(FreshInstallReset.runIfNeeded(defaults: defaults) { clears += 1 })
        XCTAssertEqual(clears, 1)
        // Later launches of the same install leave it alone.
        XCTAssertFalse(FreshInstallReset.runIfNeeded(defaults: defaults) { clears += 1 })
        XCTAssertEqual(clears, 1)

        // An update from a version without the marker already has a device identity.
        defaults.removeObject(forKey: FreshInstallReset.markerKey)
        _ = DeviceIdentityStore(defaults: defaults).loadOrCreate()
        XCTAssertFalse(FreshInstallReset.runIfNeeded(defaults: defaults) { clears += 1 })
        XCTAssertEqual(clears, 1)
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

    func testTimelineStopIgnoresLateReplyAndAcceptsNextRequest() {
        let timeline = acknowledgedTimeline()
        timeline.stopCurrentReply()
        XCTAssertTrue(timeline.feed(chatEvent("delta.message_done", [
            "message_id": "late", "reply_to_message_id": "user-1", "content": "late"
        ])).isEmpty)
        timeline.expectRequest()
        _ = timeline.acknowledge(["message_id": "user-2", "session_id": "main"])
        XCTAssertEqual(
            timeline.feed(chatEvent("delta.message_done", [
                "message_id": "next", "reply_to_message_id": "user-2", "content": "next"
            ])),
            [.reply(messageID: "next", text: "next", done: true)]
        )
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

    func testChatHistorySurvivesReopeningAndDropsFailureNotices() throws {
        let directory = temporaryChatDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let question = MuseChatItem(author: .user, text: "вопрос", image: image)
        let answer = MuseChatItem(author: .muse, text: "ответ", museMessageID: "reply-1")
        let notice = MuseChatItem(author: .system, text: "сбой")

        let store = MuseChatStore(directory: directory)
        store.scheduleSave([question, answer, notice])
        store.flush()

        let reopened = MuseChatStore(directory: directory).load()
        XCTAssertEqual(reopened.map(\.id), [question.id, answer.id])
        XCTAssertEqual(reopened.map(\.text), ["вопрос", "ответ"])
        XCTAssertEqual(reopened[0].author, .user)
        XCTAssertNotNil(reopened[0].image)
        XCTAssertEqual(reopened[1].author, .muse)
        XCTAssertEqual(reopened[1].museMessageID, "reply-1")
    }

    func testChatHistoryKeepsNewestItemsAndRemovesDroppedImages() throws {
        let directory = temporaryChatDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
        let oldest = MuseChatItem(author: .user, text: "старое", image: image)
        let store = MuseChatStore(directory: directory)
        store.scheduleSave([oldest])
        store.flush()
        XCTAssertEqual(try jpegCount(in: directory), 1)

        let newest = (0..<MuseChatStore.maxStoredItems).map { MuseChatItem(author: .muse, text: "\($0)") }
        store.scheduleSave([oldest] + newest)
        store.flush()

        let reopened = MuseChatStore(directory: directory).load()
        XCTAssertEqual(reopened.map(\.id), newest.map(\.id))
        XCTAssertEqual(try jpegCount(in: directory), 0)
    }

    func testChatHistorySetsAsideUnreadableFile() throws {
        let directory = temporaryChatDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("не json".utf8).write(to: directory.appendingPathComponent("history.json"))

        XCTAssertTrue(MuseChatStore(directory: directory).load().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("history.unreadable.json").path
        ))
    }

    func testClearingChatHistoryRemovesItFromDisk() {
        let directory = temporaryChatDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MuseChatStore(directory: directory)
        store.scheduleSave([MuseChatItem(author: .user, text: "вопрос")])
        store.flush()
        store.clear()
        XCTAssertTrue(MuseChatStore(directory: directory).load().isEmpty)
    }

    func testLANPolicyAllowsOnlyPrivateAddressesAndLocalNames() {
        for host in ["192.168.1.20", "10.0.0.5", "172.16.0.1", "172.31.255.1", "169.254.3.4", "hue-bridge.local"] {
            XCTAssertTrue(MuseLANPolicy.isAllowedHost(host), host)
        }
        for host in ["8.8.8.8", "172.32.0.1", "127.0.0.1", "0.0.0.0", "example.com", "192.168.1", "192.168.1.256",
                     "192.168.001.1", ".local", "evil.com#.local", "a b.local", "::1", ""] {
            XCTAssertFalse(MuseLANPolicy.isAllowedHost(host), host)
        }
    }

    func testLANRequestDefaultsAndValidation() throws {
        let request = try MuseLANPolicy.request(from: ["host": "192.168.1.20"]).get()
        XCTAssertEqual(request.url.absoluteString, "http://192.168.1.20:80/")
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.port, 80)
        XCTAssertEqual(request.timeout, 8)

        let secure = try MuseLANPolicy.request(from: [
            "host": "Bridge.local", "scheme": "https", "method": "put",
            "path": "/clip/v2/resource/light/1?x=1", "headers": ["hue-application-key": "k"],
            "body": "{}", "timeout_ms": 90_000
        ]).get()
        XCTAssertEqual(secure.url.absoluteString, "https://bridge.local:443/clip/v2/resource/light/1?x=1")
        XCTAssertEqual(secure.method, "PUT")
        XCTAssertEqual(secure.body, Data("{}".utf8))
        XCTAssertEqual(secure.timeout, 15)

        let rejected: [([String: Any], String)] = [
            (["host": "8.8.8.8"], "host_not_local"),
            ([:], "host_not_local"),
            (["host": "10.0.0.1", "scheme": "ftp"], "invalid_scheme"),
            (["host": "10.0.0.1", "port": 70_000], "invalid_port"),
            (["host": "10.0.0.1", "method": "TRACE"], "invalid_method"),
            (["host": "10.0.0.1", "path": "no-slash"], "invalid_path"),
            (["host": "10.0.0.1", "path": "/a b"], "invalid_path"),
            (["host": "10.0.0.1", "path": "/a\r\nX: y"], "invalid_path"),
            (["host": "10.0.0.1", "headers": ["Host": "evil"]], "invalid_headers"),
            (["host": "10.0.0.1", "headers": ["X": "a\r\nB: c"]], "invalid_headers"),
            (["host": "10.0.0.1", "body_base64": "%%%"], "invalid_body"),
            (["host": "10.0.0.1", "body": String(repeating: "x", count: 256 * 1024 + 1)], "body_too_large")
        ]
        for (arguments, code) in rejected {
            XCTAssertEqual(MuseLANPolicy.request(from: arguments), .failure(MuseLANRequestError(code)), code)
        }
    }

    func testLANResponseKeepsTextAndEncodesBinary() {
        let text = MuseLANPolicy.responseValue(status: 200, headers: ["A": "b"], body: Data("ок".utf8), truncated: false)
        XCTAssertEqual(text["status"] as? Int, 200)
        XCTAssertEqual(text["body"] as? String, "ок")
        XCTAssertEqual(text["headers"] as? [String: String], ["A": "b"])

        let binary = MuseLANPolicy.responseValue(status: 200, headers: [:], body: Data([0xff, 0xfe]), truncated: false)
        XCTAssertNil(binary["body"])
        XCTAssertEqual(binary["body_base64"] as? String, "//4=")

        // A body cut in the middle of a character is still text.
        let cut = Data("ок".utf8).dropLast()
        let truncated = MuseLANPolicy.responseValue(status: 200, headers: [:], body: Data(cut), truncated: true)
        XCTAssertEqual(truncated["body"] as? String, "о")
    }

    func testGrantsPersistAndPinTheFirstCertificate() throws {
        let suite = "MuseGrantTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = MuseGrantStore(defaults: defaults)
        XCTAssertFalse(store.trustCertificate(host: "10.0.0.1", port: 443, sha256: "aa"), "not approved yet")
        store.allowLANDevice(host: "10.0.0.1", port: 443)
        store.allowShortcut("Кино")
        XCTAssertTrue(store.trustCertificate(host: "10.0.0.1", port: 443, sha256: "aa"))
        XCTAssertTrue(store.trustCertificate(host: "10.0.0.1", port: 443, sha256: "aa"))
        XCTAssertFalse(store.trustCertificate(host: "10.0.0.1", port: 443, sha256: "bb"))

        let reopened = MuseGrantStore(defaults: defaults)
        XCTAssertTrue(reopened.allowsShortcut("Кино"))
        XCTAssertEqual(reopened.lanGrant(host: "10.0.0.1", port: 443)?.certificateSHA256, "aa")
        XCTAssertNil(reopened.lanGrant(host: "10.0.0.1", port: 80))
        reopened.revokeShortcut("Кино")
        reopened.revokeLANDevice(try XCTUnwrap(reopened.lanGrant(host: "10.0.0.1", port: 443)))
        XCTAssertTrue(reopened.shortcuts.isEmpty)
        XCTAssertTrue(reopened.lanDevices.isEmpty)
    }

    func testShortcutLinkEncodesEverythingAndParsesCallbacks() throws {
        let url = try XCTUnwrap(MuseShortcutLink.runURL(name: "Кино & свет", input: "a=1&b", token: "T"))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let value = { (name: String) in items.first(where: { $0.name == name })?.value }
        XCTAssertEqual(url.scheme, "shortcuts")
        XCTAssertEqual(url.host, "x-callback-url")
        XCTAssertEqual(url.path, "/run-shortcut")
        XCTAssertEqual(value("name"), "Кино & свет")
        XCTAssertEqual(value("input"), "text")
        XCTAssertEqual(value("text"), "a=1&b")
        XCTAssertEqual(value("x-success"), "musegadget://shortcut/success?token=T")

        let noInput = try XCTUnwrap(MuseShortcutLink.runURL(name: "A", input: nil, token: "T"))
        XCTAssertFalse(noInput.absoluteString.contains("input="))

        func parsed(_ text: String) -> (String, MuseShortcutCallback)? {
            URL(string: text).flatMap(MuseShortcutLink.parse).map { ($0.token, $0.callback) }
        }
        XCTAssertEqual(parsed("musegadget://shortcut/success?token=T&result=ok")?.1, .success(result: "ok"))
        XCTAssertEqual(parsed("musegadget://shortcut/success?token=T")?.1, .success(result: nil))
        XCTAssertEqual(parsed("musegadget://shortcut/cancel?token=T")?.1, .cancelled)
        XCTAssertEqual(parsed("musegadget://shortcut/error?token=T&errorMessage=x")?.1, .failed(message: "x"))
        XCTAssertNil(parsed("musegadget://shortcut/success"))
        XCTAssertNil(parsed("musegadget://other/success?token=T"))
        XCTAssertNil(parsed("https://shortcut/success?token=T"))
    }

    func testDisplayTextRemovesControlsAndDirectionTricks() {
        XCTAssertEqual(MuseDisplayText.sanitized("a\nb\u{202e}c"), "abc")
        XCTAssertEqual(MuseDisplayText.sanitized(String(repeating: "x", count: 5), maxLength: 3), "xxx…")
    }

    func testCommandSpecsDeclareOptionalParametersAndCustomTimeouts() throws {
        let registry = IOSCommandRegistry()
        registry.register(CommandDefinition(
            name: "x.y",
            summary: "s",
            parameters: ["a": ["type": "string", "description": "d"]],
            optional: ["b": ["type": "integer", "description": "e"]],
            timeoutMS: 45_000
        )) { _, _ in }
        let spec = try XCTUnwrap(registry.commandSpecs["x.y"] as? [String: Any])
        XCTAssertEqual(spec["required"] as? [String: [String: String]], ["a": ["type": "string", "description": "d"]])
        XCTAssertEqual(spec["optional"] as? [String: [String: String]], ["b": ["type": "integer", "description": "e"]])
        XCTAssertEqual(spec["timeout_ms"] as? Int, 45_000)
    }

    func testChatStoreKeepsDatesAndRemotePhotoMark() throws {
        let directory = temporaryChatDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let created = Date(timeIntervalSince1970: 1_000)
        let item = MuseChatItem(author: .user, text: "фото", createdAt: created, hasRemoteImage: true)
        let store = MuseChatStore(directory: directory)
        store.scheduleSave([item])
        store.flush()
        let loaded = try XCTUnwrap(MuseChatStore(directory: directory).load().first)
        XCTAssertEqual(loaded.createdAt, created)
        XCTAssertTrue(loaded.hasRemoteImage)
    }

    func testChatStoreReadsHistoryWrittenBeforeDatesExisted() throws {
        let directory = temporaryChatDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = UUID(), second = UUID()
        let old = #"{"version":1,"items":[{"id":"\#(first)","author":"user","text":"а"},{"id":"\#(second)","author":"muse","text":"б"}]}"#
        try Data(old.utf8).write(to: directory.appendingPathComponent("history.json"))
        let loaded = MuseChatStore(directory: directory).load()
        XCTAssertEqual(loaded.map(\.id), [first, second])
        XCTAssertLessThan(loaded[0].createdAt, loaded[1].createdAt)
    }

    func testMergeCombinesDevicesInTimeOrderAndMarksRemotePhotos() {
        let mine = syncItem("мой", at: 10)
        let theirs = syncedMessage("чужой", at: 5, hasImage: true)
        let merged = MuseChatMerge.merge(
            local: [mine],
            remote: MuseSyncedHistory(messages: [theirs]),
            clearedBefore: nil
        ).items
        XCTAssertEqual(merged.map(\.text), ["чужой", "мой"])
        XCTAssertTrue(merged[0].hasRemoteImage)
        XCTAssertNil(merged[0].image)
        XCTAssertFalse(merged[1].hasRemoteImage)
    }

    func testMergeKeepsTheNewestTextOfOneMessage() {
        let local = syncItem("старый", at: 1, updated: 2)
        let newer = MuseSyncedMessage(
            id: local.id, author: "muse", text: "новый", museMessageID: nil,
            createdAt: local.createdAt, updatedAt: Date(timeIntervalSince1970: 3), hasImage: false
        )
        let older = MuseSyncedMessage(
            id: local.id, author: "muse", text: "древний", museMessageID: nil,
            createdAt: local.createdAt, updatedAt: Date(timeIntervalSince1970: 1), hasImage: false
        )
        let history = { (message: MuseSyncedMessage) in MuseSyncedHistory(messages: [message]) }
        XCTAssertEqual(
            MuseChatMerge.merge(local: [local], remote: history(newer), clearedBefore: nil).items.map(\.text),
            ["новый"]
        )
        XCTAssertEqual(
            MuseChatMerge.merge(local: [local], remote: history(older), clearedBefore: nil).items.map(\.text),
            ["старый"]
        )
    }

    func testMergeShowsOneMuseReplySeenByTwoDevices() {
        let local = syncItem("ответ", at: 5, museMessageID: "reply-1")
        let same = syncedMessage("ответ", at: 6, museMessageID: "reply-1")
        let merged = MuseChatMerge.merge(
            local: [local],
            remote: MuseSyncedHistory(messages: [same]),
            clearedBefore: nil
        ).items
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, local.id)
    }

    func testServerHistoryParsesTextAndMergesWithoutDuplicates() throws {
        let json = #"{"result":{"messages":[{"id":"u1","role":"user","created_at":10,"content":[{"type":"text","text":"Hello"}]},{"id":"a1","role":"assistant","created_at":"1970-01-01T00:00:20Z","content":[{"type":"text","text":"Hi"}]},{"id":"tool","role":"tool","content":"hidden"}]}}"#
        let parsed = MuseServerHistory.parse(Data(json.utf8))
        XCTAssertEqual(parsed.map(\.messageID), ["u1", "a1"])
        XCTAssertEqual(parsed.map(\.text), ["Hello", "Hi"])

        let local = MuseChatItem(
            author: .user,
            text: "Hello",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let merged = MuseChatMerge.mergeServer(local: [local], server: parsed, clearedBefore: nil)
        XCTAssertEqual(merged.map(\.text), ["Hello", "Hi"])
        XCTAssertEqual(merged.first?.museMessageID, "u1")
        XCTAssertEqual(MuseChatMerge.mergeServer(local: merged, server: parsed, clearedBefore: nil).count, 2)
    }

    func testServerHistoryKeepsSideChatSession() {
        let json = #"{"result":{"messages":[{"id":"a1","role":"assistant","session_id":"side-1","text":"Hi"}]}}"#
        let parsed = MuseServerHistory.parse(Data(json.utf8))
        XCTAssertEqual(parsed.first?.sessionID, "side-1")
        XCTAssertEqual(
            MuseChatMerge.mergeServer(local: [], server: parsed, clearedBefore: nil).first?.sessionID,
            "side-1"
        )
    }

    func testServerHistoryReadsLiveChatEventsAndDoesNotExposeMainSession() {
        let json = #"{"result":{"chat_events":[{"message_id":"u1","role":"user","display_text":"Account side chat","occurred_at_ms":20000,"payload":{"session_id":"side-live","is_thread":true}},{"message_id":"a1","role":"assistant","display_text":"Main reply","occurred_at_ms":21000,"payload":{"session_id":"main-internal","is_thread":false}}]}}"#
        let parsed = MuseServerHistory.parse(Data(json.utf8))

        XCTAssertEqual(parsed.map(\.messageID), ["u1", "a1"])
        XCTAssertEqual(parsed.map(\.sessionID), ["side-live", nil])
        XCTAssertEqual(parsed.first?.createdAt, Date(timeIntervalSince1970: 20))
    }

    func testChatReferenceAcceptsAnIDOrMuseLink() {
        let id = "ABE174C7-1234-4ABC-8DEF-1234567890AB"
        let account = "11111111-2222-4333-8444-555555555555"
        XCTAssertEqual(MuseChatSessionReference.id(from: id), id.lowercased())
        XCTAssertEqual(
            MuseChatSessionReference.id(from: "https://muse.ai/account/\(account)/chat/\(id)?source=share"),
            id.lowercased()
        )
        XCTAssertEqual(
            MuseChatSessionReference.id(from: "https://muse.ai/chat?session_id=\(id)&account_id=\(account)"),
            id.lowercased()
        )
        XCTAssertNil(MuseChatSessionReference.id(from: "https://muse.ai/chat/"))
    }

    func testDocumentPathStaysInsidePalAgainFolder() {
        XCTAssertEqual(MuseDocumentPath.remotePath("notes.txt"), "pal-again-documents/notes.txt")
        XCTAssertEqual(MuseDocumentPath.remotePath("folder/photo 1.jpg"), "pal-again-documents/folder/photo 1.jpg")
        XCTAssertNil(MuseDocumentPath.remotePath("../secret"))
        XCTAssertNil(MuseDocumentPath.remotePath("/absolute"))
        XCTAssertNil(MuseDocumentPath.remotePath(".hidden"))
    }

    func testServerHistoryRespectsLocalClearDate() {
        let old = MuseServerChatMessage(
            author: .muse, text: "old", messageID: "a1", createdAt: Date(timeIntervalSince1970: 1)
        )
        let new = MuseServerChatMessage(
            author: .muse, text: "new", messageID: "a2", createdAt: Date(timeIntervalSince1970: 3)
        )
        let merged = MuseChatMerge.mergeServer(
            local: [], server: [old, new], clearedBefore: Date(timeIntervalSince1970: 2)
        )
        XCTAssertEqual(merged.map(\.text), ["new"])
    }

    func testClearingOnOneDeviceReachesTheOthersButKeepsNewerMessages() {
        let older = syncItem("старое", at: 1)
        let newer = syncItem("новое", at: 100)
        let cleared = Date(timeIntervalSince1970: 50)
        let merged = MuseChatMerge.merge(
            local: [older, newer],
            remote: MuseSyncedHistory(clearedBefore: cleared, messages: []),
            clearedBefore: nil
        )
        XCTAssertEqual(merged.items.map(\.text), ["новое"])
        XCTAssertEqual(merged.clearedBefore, cleared)
        // A device that has not cleared must not bring the old message back.
        let revived = MuseChatMerge.merge(
            local: [newer],
            remote: MuseSyncedHistory(messages: [syncedMessage("старое", at: 1)]),
            clearedBefore: cleared
        )
        XCTAssertEqual(revived.items.map(\.text), ["новое"])
    }

    func testMergeIsStableSoDevicesConverge() throws {
        let a = syncItem("а", at: 1)
        let b = syncItem("б", at: 2)
        let data = try XCTUnwrap(MuseChatMerge.encoded(items: [a, b], clearedBefore: nil, maxBytes: 100_000))
        let history = try XCTUnwrap(MuseChatMerge.decoded(data))
        let merged = MuseChatMerge.merge(local: [b, a], remote: history, clearedBefore: nil).items
        XCTAssertEqual(
            MuseChatMerge.encoded(items: merged, clearedBefore: nil, maxBytes: 100_000),
            data
        )
    }

    func testEncodingDropsOldestMessagesToFitAndSkipsNotices() throws {
        var random = SystemRandomNumberGenerator()
        let noise = { String((0..<2_000).map { _ in Character(UnicodeScalar(UInt8.random(in: 33...126, using: &random))) }) }
        let items = (0..<50).map { syncItem("\($0) \(noise())", at: TimeInterval($0)) }
            + [MuseChatItem(author: .system, text: "сбой")]
        let data = try XCTUnwrap(MuseChatMerge.encoded(items: items, clearedBefore: nil, maxBytes: 30_000))
        XCTAssertLessThanOrEqual(data.count, 30_000)
        let history = try XCTUnwrap(MuseChatMerge.decoded(data))
        XCTAssertLessThan(history.messages.count, 50)
        XCTAssertTrue(history.messages.last?.text.hasPrefix("49 ") ?? false)
        XCTAssertFalse(history.messages.contains { $0.text == "сбой" })
    }

    func testCloudSyncPublishesOnlyChangesAndRespectsTheSwitch() throws {
        let suite = "MuseCloudTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cloud = FakeCloudKeyValues()
        let sync = MuseChatCloudSync(cloud: cloud, defaults: defaults, publishDelay: 60)
        let item = syncItem("а", at: 1)

        sync.publish([item])
        XCTAssertEqual(cloud.writes, 0, "writes wait for the delay")
        sync.flush()
        XCTAssertEqual(cloud.writes, 1)
        XCTAssertEqual(sync.remoteHistory()?.messages.map(\.text), ["а"])

        sync.publish([item])
        sync.flush()
        XCTAssertEqual(cloud.writes, 1, "unchanged history is not written again")

        sync.isEnabled = false
        sync.publish([syncItem("б", at: 2)])
        sync.flush()
        XCTAssertEqual(cloud.writes, 1)
        XCTAssertNil(sync.remoteHistory())
    }

    func testFailureNoticesStayOutOfMerge() {
        let notice = MuseChatItem(author: .system, text: "сбой", createdAt: Date(timeIntervalSince1970: 3))
        let merged = MuseChatMerge.merge(local: [notice], remote: MuseSyncedHistory(messages: []), clearedBefore: nil)
        XCTAssertEqual(merged.items.map(\.text), ["сбой"])
    }

    func testPeerKeysMatchOnlyForTheSameToken() {
        let first = MusePeerKeys(token: "token-a")
        let second = MusePeerKeys(token: "token-a")
        let other = MusePeerKeys(token: "token-b")
        XCTAssertEqual(first.groupID, second.groupID)
        XCTAssertEqual(first.groupID.count, 16)
        XCTAssertNotEqual(first.groupID, other.groupID)
        XCTAssertFalse(first.groupID.contains("token"))
    }

    func testPeerFramesSurviveFragmentationAndRejectOtherKeysAndOversize() throws {
        let key = MusePeerKeys(token: "token-a").symmetric
        var writer = MusePeerFrameCodec(key: key)
        let one = try writer.seal(Data("один".utf8))
        let two = try writer.seal(Data("два".utf8))
        let stream = one + two

        var reader = MusePeerFrameCodec(key: key)
        var received: [Data] = []
        for byte in stream { received += try reader.open(Data([byte])) }
        XCTAssertEqual(received, [Data("один".utf8), Data("два".utf8)])

        var stranger = MusePeerFrameCodec(key: MusePeerKeys(token: "token-b").symmetric)
        XCTAssertThrowsError(try stranger.open(one))

        var flooded = MusePeerFrameCodec(key: key)
        XCTAssertThrowsError(try flooded.open(Data([0xff, 0xff, 0xff, 0xff])))
        var empty = MusePeerFrameCodec(key: key)
        XCTAssertThrowsError(try empty.open(Data([0, 0, 0, 0])))
        writer = MusePeerFrameCodec(key: key)
    }

    func testExactlyOneGadgetDials() {
        XCTAssertTrue(MuseChatPeerSync.shouldDial(local: "homelink-aaaaaa", remote: "homelink-bbbbbb"))
        XCTAssertFalse(MuseChatPeerSync.shouldDial(local: "homelink-bbbbbb", remote: "homelink-aaaaaa"))
    }

    func testMergeKeepsOnlyTheNewestItems() {
        let local = (0..<MuseChatStore.maxStoredItems).map { syncItem("\($0)", at: TimeInterval($0 + 10)) }
        let merged = MuseChatMerge.merge(
            local: local,
            remote: MuseSyncedHistory(messages: [syncedMessage("старое", at: 1)]),
            clearedBefore: nil
        ).items
        XCTAssertEqual(merged.count, MuseChatStore.maxStoredItems)
        XCTAssertFalse(merged.contains { $0.text == "старое" })
    }

    /// Real sockets and Bonjour on this machine: two gadgets find each other and swap history.
    func testTwoGadgetsExchangeHistoryOverTheNetwork() throws {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let token = "peer-test-\(UUID().uuidString)"
        let left = MuseChatPeerSync(serviceName: "gadget-a-\(suffix)", publishDelay: 0.05)
        let right = MuseChatPeerSync(serviceName: "gadget-b-\(suffix)", publishDelay: 0.05)
        let stranger = MuseChatPeerSync(serviceName: "gadget-c-\(suffix)", publishDelay: 0.05)
        defer {
            for gadget in [left, right, stranger] {
                gadget.onHistory = nil
                gadget.stop()
            }
        }

        let leftReceived = expectation(description: "left received right's history")
        let rightReceived = expectation(description: "right received left's history")
        // A reconnect sends the history again, and that is allowed.
        leftReceived.assertForOverFulfill = false
        rightReceived.assertForOverFulfill = false
        left.onHistory = { history in
            if history.messages.contains(where: { $0.text == "от правого" }) { leftReceived.fulfill() }
        }
        right.onHistory = { history in
            if history.messages.contains(where: { $0.text == "от левого" }) { rightReceived.fulfill() }
        }
        stranger.onHistory = { _ in XCTFail("a gadget with another token must not read the history") }

        left.publish([syncItem("от левого", at: 1)], clearedBefore: nil)
        right.publish([syncItem("от правого", at: 2)], clearedBefore: nil)
        stranger.publish([syncItem("чужое", at: 3)], clearedBefore: nil)
        left.start(token: token)
        right.start(token: token)
        stranger.start(token: "another-token")

        wait(for: [leftReceived, rightReceived], timeout: 60)
    }

    func testEnglishAndRussianLocalizationsAreBundled() throws {
        let englishPath = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let russianPath = try XCTUnwrap(Bundle.main.path(forResource: "ru", ofType: "lproj"))
        let english = try XCTUnwrap(Bundle(path: englishPath))
        let russian = try XCTUnwrap(Bundle(path: russianPath))

        XCTAssertEqual(
            english.localizedString(forKey: "Настройки", value: nil, table: "Localizable"),
            "Settings"
        )
        XCTAssertEqual(
            russian.localizedString(forKey: "Настройки", value: "Настройки", table: "Localizable"),
            "Настройки"
        )
        XCTAssertEqual(
            english.localizedString(forKey: "pairing.choose_device_format", value: nil, table: "Localizable"),
            "Tap + and choose %@."
        )
        XCTAssertEqual(
            russian.localizedString(forKey: "pairing.choose_device_format", value: nil, table: "Localizable"),
            "Нажмите + и выберите %@."
        )
    }

    func testMuseWidgetMarkupExtractsIDsAndHidesWireMarkers() {
        let parsed = MuseWidgetMarkup.parse(
            "Готово.\n\n[[hatch_widget:widget-one]]\n[[hatch_widget:widget-two]]"
        )
        XCTAssertEqual(parsed.text, "Готово.")
        XCTAssertEqual(parsed.widgetIDs, ["widget-one", "widget-two"])
    }

    func testMuseWidgetMarkupKeepsOrdinaryTextAndDeduplicatesWidgets() {
        XCTAssertEqual(
            MuseWidgetMarkup.parse("Обычный ответ"),
            MuseWidgetMarkup(text: "Обычный ответ", widgetIDs: [])
        )
        let parsed = MuseWidgetMarkup.parse("[[hatch_widget:same]] [[hatch_widget:same]]")
        XCTAssertEqual(parsed.widgetIDs, ["same"])
        XCTAssertTrue(parsed.text.isEmpty)
    }

    func testAgentIdentityReadsTheWrappedNameAndRejectsAnEmptyOne() {
        XCTAssertEqual(MuseAgentIdentity.parse(Data(#"{"ok":true,"result":{"name":"Muse"}}"#.utf8))?.name, "Muse")
        XCTAssertNil(MuseAgentIdentity.parse(Data(#"{"result":{"name":"  "}}"#.utf8)))
        XCTAssertNil(MuseAgentIdentity.parse(Data("route not allowed".utf8)))
    }

    func testAvatarPathMustBeRelativeAndInsideTheVM() {
        XCTAssertTrue(MuseVMImageService.isValidVMPath("workspace/pal-again-avatar.png"))
        XCTAssertTrue(MuseVMImageService.isValidVMPath("аватар.png"))
        for path in ["", "/etc/passwd", "../secret.png", "workspace/../../x.png", "workspace//x.png",
                     "workspace/./x.png", "workspace\\x.png", "x\n.png", String(repeating: "a", count: 513)] {
            XCTAssertFalse(MuseVMImageService.isValidVMPath(path), path)
        }
    }

    private func samplePNG(side: CGFloat = 32) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
        return try XCTUnwrap(image.pngData())
    }

    private func sampleGIF(frames: Int) throws -> Data {
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "com.compuserve.gif" as CFString, frames, nil))
        let image = try XCTUnwrap(UIImage(data: try samplePNG())?.cgImage)
        for _ in 0..<frames {
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.5]
            ] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    func testAnimationInfoReportsTheFilesRealSizeAndTiming() throws {
        let info = try XCTUnwrap(MuseAvatarAnimationInfo(data: try sampleGIF(frames: 100)))
        XCTAssertEqual(info.delays.count, 100)
        XCTAssertEqual(info.duration, 50, accuracy: 0.1)
        XCTAssertEqual(info.pixelWidth, 32)
        XCTAssertNil(MuseAvatarAnimationInfo(data: Data("not an image".utf8)))
    }

    func testAvatarNamesAcceptMuseVariantsAndNewMovements() {
        XCTAssertEqual(MuseAvatarState.animationName("working"), "thinking")
        XCTAssertEqual(MuseAvatarState.animationName("TALKING"), "speaking")
        XCTAssertEqual(MuseAvatarState.animationName("wag-tail_2"), "wag-tail_2")
        XCTAssertNil(MuseAvatarState.animationName("../secret"))
        XCTAssertNil(MuseAvatarState.animationName(""))
        XCTAssertNil(MuseAvatarState.animationName(String(repeating: "a", count: 33)))
    }

    func testAnimationBecomesAVideoAssetThatKeepsItsTiming() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MuseAvatarStore(directory: directory)
        let gif = try sampleGIF(frames: 4)

        _ = try store.saveAnimation(gif, name: "wag")
        XCTAssertNil(store.load(), "only idle sets the still picture")
        XCTAssertTrue(store.videoFiles().isEmpty)
        XCTAssertEqual(store.availableAnimations, ["wag"])
        XCTAssertEqual(store.animationsToBuild, ["wag"])

        store.buildMissingVideos()
        let video = try XCTUnwrap(store.videoFiles()["wag"])
        XCTAssertEqual(CMTimeGetSeconds(AVURLAsset(url: video).duration), 2, accuracy: 0.05)
        XCTAssertEqual(store.duration(of: "wag") ?? 0, 2, accuracy: 0.05)
        XCTAssertTrue(store.animationsToBuild.isEmpty)

        // The same file again costs nothing, and a new one keeps the old video until it is built.
        _ = try store.saveAnimation(gif, name: "wag")
        XCTAssertTrue(store.animationsToBuild.isEmpty)
        Thread.sleep(forTimeInterval: 1.1)
        _ = try store.saveAnimation(try sampleGIF(frames: 2), name: "wag")
        XCTAssertEqual(store.animationsToBuild, ["wag"])
        XCTAssertNotNil(store.videoFiles()["wag"])

        store.clear()
        XCTAssertTrue(store.availableAnimations.isEmpty)
    }

    func testAnMP4IsReadyAtOnceAndNeedsNoBuild() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mp4 = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: mp4) }
        let source = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".gif")
        defer { try? FileManager.default.removeItem(at: source) }
        try sampleGIF(frames: 4).write(to: source)
        try MuseAvatarVideoBuilder.build(source: source, destination: mp4)

        let store = MuseAvatarStore(directory: directory)
        let info = try store.saveAnimation(try Data(contentsOf: mp4), name: "idle")
        XCTAssertEqual(info.duration, 2, accuracy: 0.05)
        XCTAssertEqual(info.pixelWidth, 32)
        XCTAssertNotNil(store.videoFiles()["idle"])
        XCTAssertTrue(store.animationsToBuild.isEmpty)
        XCTAssertNotNil(store.load(), "the first frame becomes the still picture")
        XCTAssertThrowsError(try store.saveAnimation(Data("....ftypnot a video".utf8), name: "idle"))
    }

    func testGadgetAsksMuseOnceWhenTheVMHasNoList() {
        let defaults = UserDefaults.standard
        defer {
            defaults.removeObject(forKey: "avatarSyncOff")
            defaults.removeObject(forKey: "avatarLastAsked")
        }
        defaults.removeObject(forKey: "avatarSyncOff")
        defaults.removeObject(forKey: "avatarLastAsked")
        let service = MuseVMImageService(store: MuseAvatarStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        ))
        var asked = 0
        service.askMuseForAvatar = { asked += 1 }
        var answer: Result<Data, Error> = .failure(MuseVMFileError.status(500))
        service.readVMFile = { _, _, completion in completion(answer) }

        service.syncFromVM()
        XCTAssertEqual(asked, 0, "a failed read says nothing about the list")

        answer = .failure(MuseVMFileError.status(404))
        service.syncFromVM()
        service.syncFromVM()
        XCTAssertEqual(asked, 1, "no repeat within a day")

        defaults.set(Date(timeIntervalSinceNow: -25 * 3600), forKey: "avatarLastAsked")
        service.syncFromVM()
        XCTAssertEqual(asked, 2, "asks again if nothing came of it")

        defaults.removeObject(forKey: "avatarLastAsked")
        service.clearAvatar()
        service.syncFromVM()
        XCTAssertEqual(asked, 2, "a removed avatar stays removed")
    }

    func testPlayingAMovementStillBeingBuiltSaysItIsNotReady() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MuseAvatarStore(directory: directory)
        _ = try store.saveAnimation(try sampleGIF(frames: 2), name: "listening")
        var result: CommandResult?
        MuseVMImageService(store: store).playAvatar(name: "listening") { result = $0 }
        XCTAssertEqual(result?.value["error"] as? String, "not_ready")
    }

    func testPinnedCardSurvivesARestartWithItsTimerStillRunning() throws {
        let previous = MuseCard.loadPinned()
        defer { MuseCard.savePinned(previous) }
        let started = Date(timeIntervalSince1970: 1_000)
        MuseCard.savePinned(MuseCard(title: "Таймер", body: "1 час", kind: .timer, durationSeconds: 3_600, shownAt: started))
        let restored = try XCTUnwrap(MuseCard.loadPinned())
        XCTAssertEqual(restored.title, "Таймер")
        XCTAssertEqual(restored.kind, .timer)
        XCTAssertEqual(restored.durationSeconds, 3_600)
        XCTAssertEqual(restored.shownAt, started)
        MuseCard.savePinned(nil)
        XCTAssertNil(MuseCard.loadPinned())
    }

    func testAgentNameIsKeptAndBadNamesAreRefused() {
        let previous = UserDefaults.standard.string(forKey: "agentName")
        defer { UserDefaults.standard.set(previous, forKey: "agentName") }
        XCTAssertTrue(MuseAgentName.save("  Kotoboba \n"))
        XCTAssertEqual(MuseAgentName.saved, "Kotoboba")
        XCTAssertFalse(MuseAgentName.save("   "))
        XCTAssertFalse(MuseAgentName.save("two\nlines"))
        XCTAssertFalse(MuseAgentName.save(String(repeating: "a", count: 41)))
        XCTAssertEqual(MuseAgentName.saved, "Kotoboba")
    }

    func testManifestKeepsGoodEntriesAndDropsUnsafeOnes() throws {
        let entries = try XCTUnwrap(MuseVMImageService.parseManifest(Data(#"""
        {"animations": {
          "idle": {"path": "workspace/idle.webp", "bytes": 5},
          "working": {"path": "workspace/work.webp"},
          "wag": {"path": "../secret.webp"},
          "bad/name": {"path": "workspace/x.webp"}
        }}
        """#.utf8)))
        XCTAssertEqual(entries.map(\.name), ["idle", "thinking"])
        XCTAssertEqual(entries[0].path, "workspace/idle.webp")
        XCTAssertNil(MuseVMImageService.parseManifest(Data("not json".utf8)))
    }

    func testGadgetFetchesNewAnimationsFromTheListOnlyOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults.standard.removeObject(forKey: "avatarSyncOff")
        }
        UserDefaults.standard.removeObject(forKey: "avatarSyncOff")
        let store = MuseAvatarStore(directory: directory)
        let service = MuseVMImageService(store: store)
        let gif = try sampleGIF(frames: 2)
        var bytes = 1
        var reads: [String] = []
        service.readVMFile = { path, _, completion in
            reads.append(path)
            if path == MuseVMImageService.manifestPath {
                let list = #"{"animations":{"wag":{"path":"workspace/wag.gif","bytes":\#(bytes)}}}"#
                completion(.success(Data(list.utf8)))
            } else {
                completion(.success(gif))
            }
        }

        service.syncFromVM()
        XCTAssertEqual(reads, [MuseVMImageService.manifestPath, "workspace/wag.gif"])
        XCTAssertEqual(store.availableAnimations, ["wag"])

        service.syncFromVM()
        XCTAssertEqual(reads.count, 3, "nothing new, so only the list is read")

        bytes = 2
        service.syncFromVM()
        XCTAssertEqual(reads.last, "workspace/wag.gif", "a changed entry is fetched again")

        reads = []
        service.clearAvatar()
        service.syncFromVM()
        XCTAssertTrue(reads.isEmpty, "a removed avatar stays removed")
    }

    func testPlayingAnUnknownMovementListsTheAvailableOnes() {
        let service = MuseVMImageService(store: MuseAvatarStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        ))
        var result: CommandResult?
        service.playAvatar(name: "dance") { result = $0 }
        XCTAssertEqual(result?.value["error"] as? String, "unknown_animation")
        XCTAssertEqual(result?.value["available"] as? [String], [])
    }

    func testAvatarCommandRejectsAnUnknownStateBeforeReadingAnything() {
        let service = MuseVMImageService(store: MuseAvatarStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        ))
        service.readVMFile = { _, _, _ in XCTFail("nothing should be read") }
        var result: CommandResult?
        service.installAvatar(path: "workspace/a.gif", state: "not/a/name") { result = $0 }
        XCTAssertEqual(result?.value["error"] as? String, "invalid_state")
    }

    func testDrawFileShowsAnImageAndReportsFailuresWithoutShowingOne() throws {
        let png = try samplePNG()
        let service = MuseVMImageService(store: MuseAvatarStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        ))
        var responses: [Result<Data, Error>] = [
            .success(png),
            .success(Data("not an image".utf8)),
            .failure(MuseVMFileError.status(403)),
            .failure(MuseVMFileError.tooLarge)
        ]
        service.readVMFile = { path, maxBytes, completion in
            XCTAssertEqual(path, "workspace/picture.png")
            XCTAssertEqual(maxBytes, MuseVMImageService.maxFileBytes)
            completion(responses.removeFirst())
        }
        var results: [CommandResult] = []
        for _ in 0..<4 {
            service.draw(path: "workspace/picture.png") { results.append($0) }
        }
        service.draw(path: "../secret.png") { results.append($0) }

        XCTAssertEqual(results[0].value["drawn"] as? Bool, true)
        XCTAssertEqual(results[0].value["width"] as? Int, 32)
        XCTAssertEqual(results[1].value["error"] as? String, "not_an_image")
        XCTAssertEqual(results[2].value["error"] as? String, "file_unavailable")
        XCTAssertEqual(results[2].value["http_status"] as? Int, 403)
        XCTAssertEqual(results[3].value["error"] as? String, "file_too_large")
        XCTAssertEqual(results[4].value["error"] as? String, "invalid_path")
    }

    func testVoiceConfigureKeepsVolumeInRangeAndReportsIt() {
        let registry = IOSCommandRegistry.defaultRegistry(
            nativeServices: NativeCommandServices(permissions: PermissionCenter()),
            shortcuts: MuseShortcutsBridge(grants: MuseGrantStore(), approvals: MuseApprovalCenter()),
            grants: MuseGrantStore(),
            lan: MuseLANServices(permissions: PermissionCenter(), grants: MuseGrantStore(), approvals: MuseApprovalCenter()),
            images: MuseVMImageService()
        )
        let previous = MuseSpeechVolume.current
        defer { MuseSpeechVolume.set(previous) }

        var result: CommandResult?
        registry.invoke(name: "voice.configure", arguments: ["volume": 40]) { result = $0 }
        XCTAssertEqual(result?.value["volume"] as? Int, 40)
        registry.invoke(name: "voice.configure", arguments: [:]) { result = $0 }
        XCTAssertEqual(result?.value["volume"] as? Int, 40)
        registry.invoke(name: "voice.configure", arguments: ["volume": 101]) { result = $0 }
        XCTAssertEqual(result?.value["error"] as? String, "invalid_volume")
        XCTAssertEqual(MuseSpeechVolume.current, 40)
    }

    func testDeviceHealthReportsUsefulAppVisibleState() {
        let registry = IOSCommandRegistry.defaultRegistry(
            nativeServices: NativeCommandServices(permissions: PermissionCenter()),
            shortcuts: MuseShortcutsBridge(grants: MuseGrantStore(), approvals: MuseApprovalCenter()),
            grants: MuseGrantStore(),
            lan: MuseLANServices(permissions: PermissionCenter(), grants: MuseGrantStore(), approvals: MuseApprovalCenter()),
            images: MuseVMImageService()
        )
        let finished = expectation(description: "device health")
        registry.invoke(name: "device.health", arguments: [:]) { result in
            XCTAssertTrue(result.success)
            XCTAssertNotNil(result.value["system"] as? String)
            XCTAssertNotNil(result.value["system_version"] as? String)
            XCTAssertNotNil(result.value["model_identifier"] as? String)
            XCTAssertNotNil(result.value["battery_state"] as? String)
            XCTAssertNotNil(result.value["thermal_state"] as? String)
            XCTAssertNotNil(result.value["storage_free_bytes"])
            XCTAssertNotNil(result.value["app_version"] as? String)
            XCTAssertNotNil(result.value["foreground"] as? Bool)
            let permissions = result.value["permissions"] as? [String: String]
            XCTAssertEqual(Set(permissions?.keys.map { $0 } ?? []), [
                "bluetooth", "local_network", "camera", "microphone", "location", "motion"
            ])
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
    }

    func testLocationFailureKeepsCoreLocationDiagnostics() {
        let error = NSError(domain: "kCLErrorDomain", code: 0)
        let result = NativeCommandServices.locationFailure(error)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.value["error"] as? String, "location_failed")
        XCTAssertEqual(result.value["error_domain"] as? String, "kCLErrorDomain")
        XCTAssertEqual(result.value["error_code"] as? Int, 0)
    }

    func testChatMarkdownDropsItsMarkersAndKeepsLineBreaks() {
        let text = String(MuseChatMarkdown.attributed("- **Яркость** и `code`\n\nдальше").characters)
        XCTAssertEqual(text, "• Яркость и code\n\nдальше")
        XCTAssertEqual(String(MuseChatMarkdown.attributed("2 * 3 = 6").characters), "2 * 3 = 6")
    }

    func testToastsCoverActionsAndStayQuietForEverythingElse() {
        XCTAssertNotNil(MuseCommandToast(command: "torch.set", succeeded: true))
        XCTAssertNotNil(MuseCommandToast(command: "camera.capture", succeeded: false))
        XCTAssertNil(MuseCommandToast(command: "device.health", succeeded: true))
        XCTAssertNil(MuseCommandToast(command: "display.set_caption", succeeded: true))
    }

    func testDeviceSummaryLeavesOutWhatIsUnknown() {
        XCTAssertEqual(MuseDeviceSummary.text(batteryLevel: -1, batteryState: .unknown, freeBytes: nil), "")
        XCTAssertFalse(MuseDeviceSummary.text(batteryLevel: 0.5, batteryState: .charging, freeBytes: nil).isEmpty)
    }

    func testAvatarStoreShrinksAnImageKeepsItAndSurvivesBadFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MuseAvatarStore(directory: directory)
        XCTAssertNil(store.load())

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let large = UIGraphicsImageRenderer(size: CGSize(width: 1024, height: 1024), format: format).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        }
        let saved = try store.save(imageData: try XCTUnwrap(large.pngData()))
        XCTAssertEqual(UIImage(data: saved)?.cgImage?.width, MuseAvatarStore.maxPixelSize)
        XCTAssertEqual(MuseAvatarStore(directory: directory).load(), saved)

        XCTAssertThrowsError(try store.save(imageData: Data("not an image".utf8)))
        XCTAssertEqual(store.load(), saved)

        store.clear()
        XCTAssertNil(store.load())
    }

    func testDisplayNameTellsApartDevicesThatAreOnlyGivenTheirModel() {
        let identity = DeviceIdentity(mac: "02:11:22:aa:bb:cc")
        XCTAssertEqual(identity.displayName(deviceName: "iPhone", model: "iPhone"), "iPhone BBCC")
        XCTAssertEqual(identity.displayName(deviceName: "iPad", model: "iPad"), "iPad BBCC")
        XCTAssertEqual(
            identity.displayName(deviceName: "iPad (6th generation)", model: "iPad"),
            "iPad (6th generation) BBCC"
        )
        XCTAssertEqual(identity.displayName(deviceName: "Kitchen iPhone", model: "iPhone"), "Kitchen iPhone")
    }

    func testAvatarPlayerKeepsStatesReadyAndOnlyTheLastNamedMovement() {
        let names = MuseAvatarState.allCases.map(\.rawValue) + (1...28).map { "move\($0)" }
        let files = Dictionary(uniqueKeysWithValues: names.map {
            ($0, FileManager.default.temporaryDirectory.appendingPathComponent("\($0).mp4"))
        })
        let states = Set(MuseAvatarState.allCases.map(\.rawValue))
        let view = MuseAvatarPlayerView()
        let version = UUID()

        view.update(files: files, name: "idle", version: version)
        XCTAssertEqual(view.preparedMovements, states)

        view.update(files: files, name: "move1", version: version)
        XCTAssertEqual(view.preparedMovements, states.union(["move1"]))

        view.update(files: files, name: "move2", version: version)
        XCTAssertEqual(view.preparedMovements, states.union(["move2"]))

        view.update(files: files, name: "speaking", version: version)
        XCTAssertEqual(view.preparedMovements, states.union(["move2"]))

        view.update(files: files, name: "unknown", version: version)
        XCTAssertEqual(view.preparedMovements, states.union(["move2"]))
    }

    func testProblemReportHoldsTheLogAndDeviceButNothingElse() {
        let report = MuseProblemReport.text(
            appVersion: "1.0",
            system: "iOS 15.8.8",
            model: "iPhone8,1",
            connection: "Registered",
            log: ["Connecting to Muse VM", "Registered with Muse"]
        )
        XCTAssertTrue(report.contains("Pal Again 1.0"))
        XCTAssertTrue(report.contains("iOS 15.8.8"))
        XCTAssertTrue(report.contains("iPhone8,1"))
        XCTAssertTrue(report.contains("Connecting to Muse VM\nRegistered with Muse"))
        XCTAssertTrue(MuseProblemReport.text(
            appVersion: "1.0", system: "", model: "", connection: "", log: []
        ).contains("(empty)"))
    }

    func testWidgetContentCarriesTheCardAndWhenItsTimerEnds() throws {
        let shownAt = Date(timeIntervalSince1970: 1000)
        let card = MuseCard(title: "Tea", body: "Steeping", kind: .timer, durationSeconds: 300, shownAt: shownAt)
        let content = MuseWidgetPublisher.content(name: "Companion", card: card)
        XCTAssertEqual(content.name, "Companion")
        XCTAssertEqual(content.card?.title, "Tea")
        XCTAssertEqual(content.card?.endsAt, shownAt.addingTimeInterval(300))

        let decoded = try JSONDecoder().decode(MuseWidgetContent.self, from: JSONEncoder().encode(content))
        XCTAssertEqual(decoded, content)

        XCTAssertNil(MuseWidgetPublisher.content(name: nil, card: nil).card)
        XCTAssertNil(MuseWidgetPublisher.content(name: nil, card: MuseCard(title: "Note", body: "")).card?.endsAt)
    }

    func testAvatarStoreRemovesAnInterruptedBuildAndKeepsFinishedVideos() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let leftover = directory.appendingPathComponent("listening.mp4.building.mp4")
        let finished = directory.appendingPathComponent("idle.mp4")
        try Data("partial".utf8).write(to: leftover)
        try Data("video".utf8).write(to: finished)

        MuseAvatarStore(directory: directory).buildMissingVideos()

        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finished.path))
    }

    func testCardInfersRussianAndEnglishTimersFromBasicTitleBody() {
        let russian = MuseCard.interpreted(
            title: "Таймер", body: "30 минут — время пошло",
            kind: nil, durationSeconds: nil, progress: nil,
            shownAt: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(russian.kind, .timer)
        XCTAssertEqual(russian.durationSeconds, 1_800)

        let english = MuseCard.interpreted(
            title: "Timer", body: "1.5 hours remaining",
            kind: nil, durationSeconds: nil, progress: nil
        )
        XCTAssertEqual(english.kind, .timer)
        XCTAssertEqual(english.durationSeconds, 5_400)
    }

    private func syncItem(
        _ text: String,
        at seconds: TimeInterval,
        updated: TimeInterval? = nil,
        museMessageID: String? = nil
    ) -> MuseChatItem {
        MuseChatItem(
            author: .muse,
            text: text,
            museMessageID: museMessageID,
            createdAt: Date(timeIntervalSince1970: seconds),
            updatedAt: updated.map(Date.init(timeIntervalSince1970:))
        )
    }

    private func syncedMessage(
        _ text: String,
        at seconds: TimeInterval,
        hasImage: Bool = false,
        museMessageID: String? = nil
    ) -> MuseSyncedMessage {
        let date = Date(timeIntervalSince1970: seconds)
        return MuseSyncedMessage(
            id: UUID(), author: "muse", text: text, museMessageID: museMessageID,
            createdAt: date, updatedAt: date, hasImage: hasImage
        )
    }

    private func temporaryChatDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func jpegCount(in directory: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".jpg") }.count
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

private final class FakeCloudKeyValues: MuseCloudKeyValues {
    private var values: [String: Data] = [:]
    private(set) var writes = 0

    func data(forKey key: String) -> Data? { values[key] }

    func set(_ value: Data?, forKey key: String) {
        values[key] = value
        writes += 1
    }

    @discardableResult func synchronize() -> Bool { true }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

