import Foundation
import Security

struct DeviceCredentials: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let username: String
    let apiURL: String
    let apiURLV2: String
    let noiseHost: String
    let savedAt: Date
}

enum CredentialStoreError: Error {
    case encoding
    case keychain(OSStatus)
}

final class CredentialStore {
    private let service = "com.exrector.MuseGadgetLegacy"
    private let sdkTokenAccount = "sdk-token"
    private let deviceCredentialsAccount = "device-credentials"

    func saveSDKToken(_ token: String) throws {
        try save(Data(token.utf8), account: sdkTokenAccount)
    }

    func loadSDKToken() -> String? {
        load(account: sdkTokenAccount).flatMap { String(data: $0, encoding: .utf8) }
    }

    func saveDeviceCredentials(_ credentials: DeviceCredentials) throws {
        guard let data = try? JSONEncoder().encode(credentials) else {
            throw CredentialStoreError.encoding
        }
        try save(data, account: deviceCredentialsAccount)
    }

    func loadDeviceCredentials() -> DeviceCredentials? {
        guard let data = load(account: deviceCredentialsAccount) else { return nil }
        return try? JSONDecoder().decode(DeviceCredentials.self, from: data)
    }

    func clearPairing() {
        SecItemDelete(baseQuery(account: deviceCredentialsAccount) as CFDictionary)
    }

    private func save(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound { throw CredentialStoreError.keychain(updateStatus) }

        var insert = query
        attributes.forEach { insert[$0.key] = $0.value }
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CredentialStoreError.keychain(addStatus) }
    }

    private func load(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

