import CryptoKit
import Foundation

enum PairingConstants {
    static let version = 5
    static let model = "hatch_link"
    static let suite = "p256-hkdf-sha256-aes-gcm-v1"
    static let policy = "confirm_app"
    static let authentication = "none"
    static let recordLabel = "hatch-link ble setup v1"
    static let sessionIDLabel = Data("hatch-link session id v1".utf8)
}

enum PairingError: Error {
    case invalidHello
    case decrypt
    case invalidState
    case invalidMessage
    case crypto
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: Any?) throws -> Data {
        guard let text = text as? String,
              !text.isEmpty,
              text.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil,
              text.count % 4 != 1 else { throw PairingError.invalidMessage }
        let standard = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = standard + String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let data = Data(base64Encoded: padded) else { throw PairingError.invalidMessage }
        return data
    }
}

enum HKDFTools {
    static func derive(input: Data, salt: Data, info: Data, count: Int) -> Data {
        let prk = Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: salt)))
        return expand(prk: prk, info: info, count: count)
    }

    static func expand(prk: Data, info: Data, count: Int) -> Data {
        var output = Data()
        var previous = Data()
        var counter: UInt8 = 1
        while output.count < count {
            let input = previous + info + Data([counter])
            previous = Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: prk)))
            output.append(previous)
            counter &+= 1
        }
        return output.prefix(count)
    }
}

final class PairingSession {
    enum State { case idle, waitingForClientFinished, ready, provisioning }

    private(set) var state: State = .idle
    private let identity: DeviceIdentity
    private let firmwareVersion: String
    private let sdkToken: String

    private var receiveKey: SymmetricKey?
    private var transmitKey: SymmetricKey?
    private var sessionID = ""
    private var receiveCounter: UInt64 = 0
    private var transmitCounter: UInt64 = 0

    init(identity: DeviceIdentity, firmwareVersion: String, sdkToken: String) {
        self.identity = identity
        self.firmwareVersion = firmwareVersion
        self.sdkToken = sdkToken
    }

    var deviceInfo: [String: Any] {
        [
            "type": "device_info",
            "node_id": identity.nodeID,
            "device_id": identity.deviceID,
            "mac": identity.mac,
            "model": PairingConstants.model,
            "version": firmwareVersion,
            "build_sha": "",
            "network_ready": true,
            "pairing_protocol": PairingConstants.version,
            "pairing_auth": PairingConstants.authentication,
            "pairing_auth_epoch": 0,
            "pairing_policy": PairingConstants.policy
        ]
    }

    func reset() {
        state = .idle
        receiveKey = nil
        transmitKey = nil
        sessionID = ""
        receiveCounter = 0
        transmitCounter = 0
    }

    func handleHello(_ message: [String: Any]) throws -> [String: Any] {
        guard (message["version"] as? NSNumber)?.intValue == PairingConstants.version,
              message["pairing_auth"] as? String == PairingConstants.authentication,
              message["pairing_policy"] as? String == PairingConstants.policy else {
            throw PairingError.invalidHello
        }

        let mobilePublicData = try Base64URL.decode(message["mobile_pub"])
        let mobileNonce = try Base64URL.decode(message["mobile_nonce"])
        guard mobilePublicData.count == 65, mobilePublicData.first == 0x04, mobileNonce.count == 16 else {
            throw PairingError.invalidHello
        }

        let mobilePublic = try P256.KeyAgreement.PublicKey(x963Representation: mobilePublicData)
        let devicePrivate = P256.KeyAgreement.PrivateKey()
        let devicePublicData = devicePrivate.publicKey.x963Representation
        var deviceNonce = Data(count: 16)
        let randomStatus = deviceNonce.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        guard randomStatus == errSecSuccess else { throw PairingError.crypto }

        let mobilePublicText = Base64URL.encode(mobilePublicData)
        let devicePublicText = Base64URL.encode(devicePublicData)
        let mobileNonceText = Base64URL.encode(mobileNonce)
        let deviceNonceText = Base64URL.encode(deviceNonce)
        let transcript = [
            "hatch-link-pairing-v5",
            "version=5",
            "initiator_role=mobile",
            "responder_role=link",
            "device_id=\(identity.deviceID)",
            "node_id=\(identity.nodeID)",
            "mac=\(identity.mac)",
            "model=\(PairingConstants.model)",
            "firmware_version=\(firmwareVersion)",
            "selected_cipher_suite=\(PairingConstants.suite)",
            "pairing_auth=\(PairingConstants.authentication)",
            "pairing_auth_epoch=0",
            "pairing_policy=\(PairingConstants.policy)",
            "confirm_timeout_seconds=0",
            "mobile_pub=\(mobilePublicText)",
            "device_pub=\(devicePublicText)",
            "mobile_nonce=\(mobileNonceText)",
            "device_nonce=\(deviceNonceText)"
        ].joined(separator: "\n")
        let transcriptHash = Data(SHA256.hash(data: Data(transcript.utf8)))
        let sharedSecret = try devicePrivate.sharedSecretFromKeyAgreement(with: mobilePublic)
        let sharedData = sharedSecret.withUnsafeBytes { Data($0) }
        let salt = Data(SHA256.hash(data: mobileNonce + deviceNonce + transcriptHash))
        let sessionSecret = HKDFTools.derive(
            input: sharedData,
            salt: salt,
            info: Data(PairingConstants.recordLabel.utf8),
            count: 32
        )
        let mobileToDevice = HKDFTools.expand(prk: sessionSecret, info: Data("mobile->device".utf8), count: 32)
        let deviceToMobile = HKDFTools.expand(prk: sessionSecret, info: Data("device->mobile".utf8), count: 32)
        let sessionDigest = SHA256.hash(data: PairingConstants.sessionIDLabel + transcriptHash + sharedData)
        sessionID = Base64URL.encode(Data(sessionDigest).prefix(16))
        receiveKey = SymmetricKey(data: mobileToDevice)
        transmitKey = SymmetricKey(data: deviceToMobile)
        receiveCounter = 0
        transmitCounter = 0
        state = .waitingForClientFinished

        return [
            "type": "pairing_ready",
            "version": PairingConstants.version,
            "device_id": identity.deviceID,
            "node_id": identity.nodeID,
            "mac": identity.mac,
            "model": PairingConstants.model,
            "firmware_version": firmwareVersion,
            "pairing_auth": PairingConstants.authentication,
            "pairing_auth_epoch": 0,
            "pairing_policy": PairingConstants.policy,
            "device_pub": devicePublicText,
            "device_nonce": deviceNonceText,
            "transcript_hash": Base64URL.encode(transcriptHash),
            "session_id": sessionID
        ]
    }

    func decrypt(_ envelope: [String: Any]) throws -> [String: Any] {
        guard let key = receiveKey,
              envelope["session_id"] as? String == sessionID,
              let counterText = envelope["counter"] as? String,
              let counter = UInt64(counterText), counter == receiveCounter else {
            reset()
            throw PairingError.decrypt
        }
        let ciphertext = try Base64URL.decode(envelope["ciphertext"])
        let tag = try Base64URL.decode(envelope["tag"])
        guard tag.count == 16 else { reset(); throw PairingError.decrypt }

        do {
            let nonce = try AES.GCM.Nonce(data: recordNonce(direction: 0, counter: counter))
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            let plaintext = try AES.GCM.open(box, using: key, authenticating: recordAAD(direction: 0, counter: counter))
            receiveCounter += 1
            guard let object = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
                throw PairingError.invalidMessage
            }
            return object
        } catch {
            reset()
            throw PairingError.decrypt
        }
    }

    func confirmClientFinished(_ command: [String: Any]) throws {
        guard state == .waitingForClientFinished,
              receiveCounter == 1,
              command.count == 1,
              command["action"] as? String == "pairing_client_finished" else {
            reset()
            throw PairingError.invalidState
        }
        state = .ready
    }

    func beginProvisioning() throws {
        guard state == .ready else { throw PairingError.invalidState }
        state = .provisioning
    }

    func encryptStatus(_ status: String) throws -> [String: Any] {
        var object: [String: Any] = ["type": "status", "status": status]
        if status == "pairing_confirmed", !sdkToken.isEmpty { object["sdk_token"] = sdkToken }
        return try encrypt(object)
    }

    func encrypt(_ object: [String: Any]) throws -> [String: Any] {
        guard let key = transmitKey, state != .idle else { throw PairingError.invalidState }
        let plaintext = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let counter = transmitCounter
        let nonce = try AES.GCM.Nonce(data: recordNonce(direction: 1, counter: counter))
        let sealed = try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: nonce,
            authenticating: recordAAD(direction: 1, counter: counter)
        )
        transmitCounter += 1
        return [
            "type": "pairing_encrypted",
            "session_id": sessionID,
            "counter": String(counter),
            "ciphertext": Base64URL.encode(sealed.ciphertext),
            "tag": Base64URL.encode(sealed.tag)
        ]
    }

    private func recordNonce(direction: UInt8, counter: UInt64) -> Data {
        var value = counter.bigEndian
        let counterData = withUnsafeBytes(of: &value) { Data($0) }
        return Data([direction, 0, 0, 0]) + counterData
    }

    private func recordAAD(direction: UInt8, counter: UInt64) -> Data {
        let arrow = direction == 0 ? "m2d" : "d2m"
        return Data("\(PairingConstants.recordLabel)|\(sessionID)|\(arrow)|\(counter)".utf8)
    }
}
