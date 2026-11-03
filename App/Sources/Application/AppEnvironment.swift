import Foundation

final class AppEnvironment {
    let identity: DeviceIdentity
    let credentialStore: CredentialStore
    let permissions: PermissionCenter
    let nativeServices: NativeCommandServices
    let commands: IOSCommandRegistry
    let pairing: PairingCoordinator
    let runtime: MuseRuntime
    let chatStore = MuseChatStore()

    init() {
        let identity = DeviceIdentityStore().loadOrCreate()
        let credentialStore = CredentialStore()
        let permissions = PermissionCenter()
        let nativeServices = NativeCommandServices(permissions: permissions)
        let commands = IOSCommandRegistry.defaultRegistry(nativeServices: nativeServices)
        let pairing = PairingCoordinator(identity: identity, credentials: credentialStore)
        let runtime = MuseRuntime(identity: identity, commands: commands, credentialStore: credentialStore)

        self.identity = identity
        self.credentialStore = credentialStore
        self.permissions = permissions
        self.nativeServices = nativeServices
        self.commands = commands
        self.pairing = pairing
        self.runtime = runtime

        importStagedSDKTokenIfPresent()

        pairing.onCredentialsStored = { credentials in runtime.start(credentials: credentials) }
        runtime.onUnpaired = { pairing.forgetPairing() }
        if let credentials = credentialStore.loadDeviceCredentials() {
            runtime.start(credentials: credentials)
        }
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

