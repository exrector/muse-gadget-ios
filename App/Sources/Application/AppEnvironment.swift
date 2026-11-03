import Foundation

final class AppEnvironment {
    let identity: DeviceIdentity
    let credentialStore: CredentialStore
    let permissions: PermissionCenter
    let commands: IOSCommandRegistry
    let pairing: PairingCoordinator

    init() {
        let identity = DeviceIdentityStore().loadOrCreate()
        let credentialStore = CredentialStore()
        let permissions = PermissionCenter()
        let commands = IOSCommandRegistry.defaultRegistry(permissions: permissions)

        self.identity = identity
        self.credentialStore = credentialStore
        self.permissions = permissions
        self.commands = commands
        self.pairing = PairingCoordinator(identity: identity, credentials: credentialStore)

        importStagedSDKTokenIfPresent()
    }

    private func importStagedSDKTokenIfPresent() {
        let fileManager = FileManager.default
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let file = documents.appendingPathComponent("muse-sdk-import.musetoken", isDirectory: false)
        guard let rawToken = try? String(contentsOf: file, encoding: .utf8) else { return }
        do {
            try pairing.saveSDKToken(rawToken)
            try fileManager.removeItem(at: file)
        } catch {
            // Keep the staging file so a transient Keychain failure can be retried.
        }
    }
}

