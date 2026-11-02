import CryptoKit
import Foundation

func nonce(direction: UInt8, counter: UInt64) -> Data {
    var value = counter.bigEndian
    return Data([direction, 0, 0, 0]) + withUnsafeBytes(of: &value) { Data($0) }
}

func aad(sessionID: String, direction: UInt8, counter: UInt64) -> Data {
    let arrow = direction == 0 ? "m2d" : "d2m"
    return Data("\(PairingConstants.recordLabel)|\(sessionID)|\(arrow)|\(counter)".utf8)
}

let identity = DeviceIdentity(mac: "02:11:22:aa:bb:cc")
let device = PairingSession(identity: identity, firmwareVersion: "smoke", sdkToken: "mgst_smoke_only")
let mobilePrivate = P256.KeyAgreement.PrivateKey()
let mobileNonce = Data((0..<16).map(UInt8.init))
let hello: [String: Any] = [
    "action": "pairing_client_hello",
    "version": 5,
    "pairing_auth": "none",
    "pairing_policy": "confirm_app",
    "mobile_pub": Base64URL.encode(mobilePrivate.publicKey.x963Representation),
    "mobile_nonce": Base64URL.encode(mobileNonce)
]

let ready = try device.handleHello(hello)
let devicePublic = try P256.KeyAgreement.PublicKey(x963Representation: Base64URL.decode(ready["device_pub"]))
let deviceNonce = try Base64URL.decode(ready["device_nonce"])
let transcriptHash = try Base64URL.decode(ready["transcript_hash"])
let sessionID = ready["session_id"] as! String
let shared = try mobilePrivate.sharedSecretFromKeyAgreement(with: devicePublic).withUnsafeBytes { Data($0) }
let salt = Data(SHA256.hash(data: mobileNonce + deviceNonce + transcriptHash))
let secret = HKDFTools.derive(input: shared, salt: salt, info: Data(PairingConstants.recordLabel.utf8), count: 32)
let mobileToDevice = HKDFTools.expand(prk: secret, info: Data("mobile->device".utf8), count: 32)
let deviceToMobile = HKDFTools.expand(prk: secret, info: Data("device->mobile".utf8), count: 32)

let finishedData = try JSONSerialization.data(withJSONObject: ["action": "pairing_client_finished"])
let finishedBox = try AES.GCM.seal(
    finishedData,
    using: SymmetricKey(data: mobileToDevice),
    nonce: AES.GCM.Nonce(data: nonce(direction: 0, counter: 0)),
    authenticating: aad(sessionID: sessionID, direction: 0, counter: 0)
)
let finishedEnvelope: [String: Any] = [
    "session_id": sessionID,
    "counter": "0",
    "ciphertext": Base64URL.encode(finishedBox.ciphertext),
    "tag": Base64URL.encode(finishedBox.tag)
]

let openedFinished = try device.decrypt(finishedEnvelope)
try device.confirmClientFinished(openedFinished)
let confirmation = try device.encryptStatus("pairing_confirmed")
let confirmationBox = try AES.GCM.SealedBox(
    nonce: AES.GCM.Nonce(data: nonce(direction: 1, counter: 0)),
    ciphertext: Base64URL.decode(confirmation["ciphertext"]),
    tag: Base64URL.decode(confirmation["tag"])
)
let openedConfirmation = try AES.GCM.open(
    confirmationBox,
    using: SymmetricKey(data: deviceToMobile),
    authenticating: aad(sessionID: sessionID, direction: 1, counter: 0)
)
let status = try JSONSerialization.jsonObject(with: openedConfirmation) as! [String: Any]
precondition(status["status"] as? String == "pairing_confirmed")

let payload = Data((0..<700).map { UInt8($0 % 251) })
let frames = try BLEFraming.encode(payload, mtu: 80)
let assembler = BLEChunkAssembler()
let rebuilt = frames.compactMap(assembler.feed).last
precondition(rebuilt == payload)

print("PAIRING_V5_SMOKE_OK")
print("BLE_FRAMING_SMOKE_OK frames=\(frames.count)")
