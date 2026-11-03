import CryptoKit
import Foundation

enum MuseNoiseError: Error, Equatable {
    case invalidState
    case invalidKey
    case invalidMessage
    case decryptFailed
    case nonceExhausted
}

final class MuseNoiseCipherState {
    private var key: SymmetricKey?
    private var nonce: UInt64 = 0

    func initializeKey(_ data: Data) throws {
        guard data.count == 32 else { throw MuseNoiseError.invalidKey }
        key = SymmetricKey(data: data)
        nonce = 0
    }

    func encrypt(ad: Data, plaintext: Data) throws -> Data {
        guard let key else { return plaintext }
        let iv = try nextNonce()
        let box = try AES.GCM.seal(plaintext, using: key, nonce: iv, authenticating: ad)
        return box.ciphertext + box.tag
    }

    func decrypt(ad: Data, ciphertext: Data) throws -> Data {
        guard let key else { return ciphertext }
        guard ciphertext.count >= 16 else { throw MuseNoiseError.invalidMessage }
        let iv = try nextNonce()
        let split = ciphertext.count - 16
        do {
            let box = try AES.GCM.SealedBox(
                nonce: iv,
                ciphertext: ciphertext.prefix(split),
                tag: ciphertext.suffix(16)
            )
            return try AES.GCM.open(box, using: key, authenticating: ad)
        } catch {
            throw MuseNoiseError.decryptFailed
        }
    }

    private func nextNonce() throws -> AES.GCM.Nonce {
        guard nonce < (1 << 53) - 1 else { throw MuseNoiseError.nonceExhausted }
        var bytes = Data(repeating: 0, count: 4)
        var bigEndian = nonce.bigEndian
        withUnsafeBytes(of: &bigEndian) { bytes.append(contentsOf: $0) }
        nonce += 1
        return try AES.GCM.Nonce(data: bytes)
    }
}

private enum MuseNoiseCrypto {
    static let protocolName = Data("Noise_XX_25519_AESGCM_SHA256".utf8)

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static func hmac(key: Data, data: Data) -> Data {
        let code = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(code)
    }

    static func hkdf(chainingKey: Data, input: Data) -> (Data, Data) {
        let tempKey = hmac(key: chainingKey, data: input)
        let first = hmac(key: tempKey, data: Data([1]))
        let second = hmac(key: tempKey, data: first + Data([2]))
        return (first, second)
    }
}

private final class MuseNoiseSymmetricState {
    private var chainingKey = Data(repeating: 0, count: 32)
    private var hash = Data(repeating: 0, count: 32)
    private var cipher = MuseNoiseCipherState()

    func initialize() {
        var padded = Data(repeating: 0, count: 32)
        padded.replaceSubrange(0..<MuseNoiseCrypto.protocolName.count, with: MuseNoiseCrypto.protocolName)
        hash = padded
        chainingKey = hash
        mixHash(Data())
    }

    func mixHash(_ data: Data) {
        hash = MuseNoiseCrypto.sha256(hash + data)
    }

    func mixKey(_ input: Data) throws {
        let (nextChainingKey, temporaryKey) = MuseNoiseCrypto.hkdf(
            chainingKey: chainingKey,
            input: input
        )
        chainingKey = nextChainingKey
        cipher = MuseNoiseCipherState()
        try cipher.initializeKey(temporaryKey)
    }

    func encryptAndHash(_ plaintext: Data) throws -> Data {
        let ciphertext = try cipher.encrypt(ad: hash, plaintext: plaintext)
        mixHash(ciphertext)
        return ciphertext
    }

    func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let plaintext = try cipher.decrypt(ad: hash, ciphertext: ciphertext)
        mixHash(ciphertext)
        return plaintext
    }

    func split() throws -> (MuseNoiseCipherState, MuseNoiseCipherState) {
        let (firstKey, secondKey) = MuseNoiseCrypto.hkdf(chainingKey: chainingKey, input: Data())
        let first = MuseNoiseCipherState()
        let second = MuseNoiseCipherState()
        try first.initializeKey(firstKey)
        try second.initializeKey(secondKey)
        return (first, second)
    }
}

private struct MuseX25519KeyPair {
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    var publicKey: Data { privateKey.publicKey.rawRepresentation }
}

private func museX25519(
    privateKey: Curve25519.KeyAgreement.PrivateKey,
    publicKey: Data
) throws -> Data {
    guard publicKey.count == 32,
          publicKey.contains(where: { $0 != 0 }) else { throw MuseNoiseError.invalidKey }
    do {
        let remote = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: remote)
        return secret.withUnsafeBytes { Data($0) }
    } catch {
        throw MuseNoiseError.invalidKey
    }
}

final class MuseNoiseXXInitiator {
    private enum Phase { case created, initialized, message1, message2, message3, split }

    private let symmetric = MuseNoiseSymmetricState()
    private var ephemeral: MuseX25519KeyPair?
    private var staticKey: MuseX25519KeyPair?
    private var remoteEphemeral: Data?
    private var phase: Phase = .created

    func initialize() throws {
        guard phase == .created else { throw MuseNoiseError.invalidState }
        symmetric.initialize()
        phase = .initialized
    }

    func writeMessage1() throws -> Data {
        guard phase == .initialized else { throw MuseNoiseError.invalidState }
        let key = MuseX25519KeyPair(privateKey: Curve25519.KeyAgreement.PrivateKey())
        ephemeral = key
        symmetric.mixHash(key.publicKey)
        _ = try symmetric.encryptAndHash(Data())
        phase = .message1
        return key.publicKey
    }

    func readMessage2(_ message: Data) throws -> Data {
        guard phase == .message1, message.count >= 96, let ephemeral else {
            throw MuseNoiseError.invalidMessage
        }
        var offset = 0
        let remoteEphemeral = message.subdata(in: offset..<(offset + 32))
        self.remoteEphemeral = remoteEphemeral
        symmetric.mixHash(remoteEphemeral)
        offset += 32

        try symmetric.mixKey(try museX25519(privateKey: ephemeral.privateKey, publicKey: remoteEphemeral))
        let encryptedStatic = message.subdata(in: offset..<(offset + 48))
        let remoteStatic = try symmetric.decryptAndHash(encryptedStatic)
        guard remoteStatic.count == 32 else { throw MuseNoiseError.invalidMessage }
        offset += 48
        try symmetric.mixKey(try museX25519(privateKey: ephemeral.privateKey, publicKey: remoteStatic))
        let payload = try symmetric.decryptAndHash(message.suffix(from: offset))
        phase = .message2
        return payload
    }

    func writeMessage3() throws -> Data {
        guard phase == .message2, let remoteEphemeral else { throw MuseNoiseError.invalidState }
        let key = MuseX25519KeyPair(privateKey: Curve25519.KeyAgreement.PrivateKey())
        staticKey = key
        let encryptedStatic = try symmetric.encryptAndHash(key.publicKey)
        try symmetric.mixKey(try museX25519(privateKey: key.privateKey, publicKey: remoteEphemeral))
        let encryptedPayload = try symmetric.encryptAndHash(Data())
        phase = .message3
        return encryptedStatic + encryptedPayload
    }

    func split() throws -> (send: MuseNoiseCipherState, receive: MuseNoiseCipherState) {
        guard phase == .message3 else { throw MuseNoiseError.invalidState }
        phase = .split
        ephemeral = nil
        staticKey = nil
        remoteEphemeral = nil
        let result = try symmetric.split()
        return (result.0, result.1)
    }
}
