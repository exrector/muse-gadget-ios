import Foundation
import os
import UIKit

extension DeviceIdentity {
    var displayName: String {
        displayName(deviceName: UIDevice.current.name, model: UIDevice.current.model)
    }
}

/// iOS suspends an app moments after it leaves the screen. This asks for the extra time iOS allows,
/// about 30 seconds, so a quick look at another app does not drop the connection.
final class MuseBackgroundGrace {
    private var task = UIBackgroundTaskIdentifier.invalid
    private var observers: [NSObjectProtocol] = []
    private let logger = Logger(subsystem: "com.exrector.MuseGadgetLegacy", category: "background")

    init() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.begin() },
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.end() }
        ]
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func begin() {
        guard task == .invalid else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: "MuseConnection") { [weak self] in
            self?.logger.info("Background time ran out")
            self?.end()
        }
        logger.info("Left the screen")
    }

    private func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}

final class AppEnvironment {
    let diagnostics: MuseDiagnostics
    let identity: DeviceIdentity
    let credentialStore: CredentialStore
    let permissions: PermissionCenter
    let nativeServices: NativeCommandServices
    let grants: MuseGrantStore
    let approvals: MuseApprovalCenter
    let shortcuts: MuseShortcutsBridge
    let vmImages: MuseVMImageService
    let commands: IOSCommandRegistry
    let pairing: PairingCoordinator
    let runtime: MuseRuntime
    let chatStore = MuseChatStore()
    let documents = MuseDocumentStore()
    let chatCloud = MuseChatCloudSync()
    let chatPeers: MuseChatPeerSync
    private let backgroundGrace = MuseBackgroundGrace()
    private var activeObserver: NSObjectProtocol?

    init() {
        let diagnostics = MuseDiagnostics()
        let credentialStore = CredentialStore()
        FreshInstallReset.runIfNeeded { credentialStore.clearAll() }
        let identity = DeviceIdentityStore().loadOrCreate()
        let permissions = PermissionCenter()
        let nativeServices = NativeCommandServices(permissions: permissions)
        let grants = MuseGrantStore()
        let approvals = MuseApprovalCenter()
        let shortcuts = MuseShortcutsBridge(grants: grants, approvals: approvals)
        let lan = MuseLANServices(permissions: permissions, grants: grants, approvals: approvals)
        let vmImages = MuseVMImageService()
        let commands = IOSCommandRegistry.defaultRegistry(
            nativeServices: nativeServices,
            shortcuts: shortcuts,
            grants: grants,
            lan: lan,
            images: vmImages
        )
        let pairing = PairingCoordinator(identity: identity, credentials: credentialStore)
        let runtime = MuseRuntime(identity: identity, commands: commands, credentialStore: credentialStore)
        vmImages.readVMFile = { [weak runtime] path, maxBytes, completion in
            guard let runtime else {
                completion(.failure(MuseRuntimeError.notConnected))
                return
            }
            runtime.readVMFile(path: path, maxBytes: maxBytes, completion: completion)
        }

        self.diagnostics = diagnostics
        self.identity = identity
        chatPeers = MuseChatPeerSync(serviceName: identity.nodeID)
        self.credentialStore = credentialStore
        self.permissions = permissions
        self.nativeServices = nativeServices
        self.grants = grants
        self.approvals = approvals
        self.shortcuts = shortcuts
        self.vmImages = vmImages
        self.commands = commands
        self.pairing = pairing
        self.runtime = runtime

        importStagedSDKTokenIfPresent()
        vmImages.buildAvatarVideos()
        runtime.onRegistered = { vmImages.syncFromVM() }
        nativeServices.connectivityEvents = { [weak runtime] in runtime?.connectivity.recent() ?? [] }
        runtime.connectivity.onEvent = { [weak diagnostics] code in
            DispatchQueue.main.async { diagnostics?.record("link", detail: code) }
        }
        vmImages.askMuseForAvatar = {
            runtime.sendChat(PalL10n.format("avatar.request_format", identity.displayName)) { _ in }
        }
        // A build stopped by the app leaving the screen goes on from where it was.
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            vmImages.buildAvatarVideos()
            vmImages.syncFromVM()
        }

        pairing.onCredentialsStored = { credentials in runtime.start(credentials: credentials) }
        runtime.onUnpaired = { pairing.forgetPairing() }
        if let credentials = credentialStore.loadDeviceCredentials() {
            runtime.start(credentials: credentials)
        }
    }

    /// Stops everything this environment runs before a full reset, so a new one can take its place.
    func shutdown() {
        runtime.onUnpaired = nil
        runtime.onRegistered = nil
        runtime.connectivity.onEvent = nil
        runtime.stopPathMonitor()
        pairing.onCredentialsStored = nil
        vmImages.readVMFile = nil
        vmImages.askMuseForAvatar = nil
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
        runtime.stop()
        pairing.stop()
        chatPeers.stop()
        diagnostics.stop()
        // Drops a delayed save that would otherwise write the chat back after the reset.
        chatStore.clear()
    }

    /// Removes everything the app has stored on this device: the SDK token and the pairing in the
    /// Keychain, every setting, the device identity, the chat, the avatar and the files.
    /// iOS permissions are not the app's to remove, and other gadgets keep their chat history.
    static func eraseStoredData() {
        CredentialStore().clearAll()
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        MuseWidgetContent().save()
        let fileManager = FileManager.default
        if let avatar = MuseWidgetContent.avatarURL { try? fileManager.removeItem(at: avatar) }
        var folders = [fileManager.temporaryDirectory]
        for directory in [FileManager.SearchPathDirectory.documentDirectory, .applicationSupportDirectory, .cachesDirectory] {
            folders += fileManager.urls(for: directory, in: .userDomainMask)
        }
        for folder in folders {
            let items = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            items.forEach { try? fileManager.removeItem(at: $0) }
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

