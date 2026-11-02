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
    }
}

