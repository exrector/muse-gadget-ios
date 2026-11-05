import AVFoundation
import SwiftUI

final class TVModel: ObservableObject {
    @Published var token = ""
    @Published var pairing = "-"
    @Published var connection = "-"
    @Published var caption = ""
    @Published var log: [String] = []

    let identity = DeviceIdentityStore().loadOrCreate()
    let store = CredentialStore()
    lazy var coordinator = PairingCoordinator(identity: identity, credentials: store)
    lazy var commands = makeCommands()
    lazy var runtime = MuseRuntime(identity: identity, commands: commands, credentialStore: store)
    private let speech = AVSpeechSynthesizer()

    var bluetoothName: String { identity.bluetoothName }
    var hasToken: Bool { store.loadSDKToken() != nil }

    private func add(_ text: String) {
        print("\(ISO8601DateFormatter().string(from: Date())) \(text)")
        fflush(stdout)
        DispatchQueue.main.async {
            self.log.insert(text, at: 0)
            if self.log.count > 12 { self.log.removeLast() }
        }
    }

    private func makeCommands() -> IOSCommandRegistry {
        let registry = IOSCommandRegistry()
        registry.register(CommandDefinition(
            name: "display.set_caption",
            summary: "Show a line of text on the television, on the Apple TV this gadget runs on.",
            parameters: ["text": ["type": "string", "description": "The text to show."]]
        )) { [weak self] arguments, completion in
            let text = arguments["text"] as? String ?? ""
            DispatchQueue.main.async {
                self?.caption = text
                completion(CommandResult(success: true, value: ["shown": true]))
            }
        }
        registry.register(CommandDefinition(
            name: "audio.speak",
            summary: "Speak text aloud through the television.",
            parameters: ["text": ["type": "string", "description": "The text to speak."]]
        )) { [weak self] arguments, completion in
            let text = arguments["text"] as? String ?? ""
            DispatchQueue.main.async {
                self?.speech.speak(AVSpeechUtterance(string: text))
                completion(CommandResult(success: true, value: ["accepted": true]))
            }
        }
        registry.register(CommandDefinition(
            name: "device.health",
            summary: "Report the system version and model of this Apple TV.",
            parameters: [:]
        )) { _, completion in
            completion(CommandResult(success: true, value: [
                "system": UIDevice.current.systemName,
                "system_version": UIDevice.current.systemVersion,
                "model": UIDevice.current.model
            ]))
        }
        return registry
    }

    func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        coordinator.onLog = { [weak self] in self?.add("pairing: \($0)") }
        coordinator.onStateChange = { [weak self] state in
            self?.pairing = state.title
            self?.add("pairing state: \(state.title)")
        }
        coordinator.onCredentialsStored = { [weak self] credentials in
            self?.add("credentials received over Bluetooth")
            self?.runtime.start(credentials: credentials)
        }
        runtime.onLog = { [weak self] in self?.add("runtime: \($0)") }
        runtime.onStateChange = { [weak self] state in
            DispatchQueue.main.async { self?.connection = "\(state)" }
            self?.add("connection: \(state)")
        }
        runtime.onCommandFinished = { [weak self] command, ok in self?.add("command \(command): \(ok ? "ok" : "failed")") }
        add("name \(identity.bluetoothName), SDK token saved: \(hasToken)")
        if let credentials = store.loadDeviceCredentials() {
            add("already paired, connecting")
            runtime.start(credentials: credentials)
        } else if hasToken {
            coordinator.start()
        }
    }

    func saveTokenAndPair() {
        do {
            try coordinator.saveSDKToken(token)
            token = ""
            add("SDK token accepted")
            coordinator.start()
        } catch {
            add("SDK token refused: \(error.localizedDescription)")
        }
    }
}

struct TVContentView: View {
    @StateObject private var model = TVModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pal Again on Apple TV: \(model.bluetoothName)").font(.title3)
            Text(model.caption.isEmpty ? " " : model.caption).font(.largeTitle)
            Text("Pairing: \(model.pairing)")
            Text("Muse: \(model.connection)")
            if !model.hasToken {
                SecureField("Paste your SDK Token", text: $model.token)
                Button("Save and pair") { model.saveTokenAndPair() }
            }
            ForEach(model.log, id: \.self) { Text($0).font(.caption2).lineLimit(1) }
            Spacer()
        }
        .padding(60)
        .onAppear { model.start() }
    }
}

@main
struct PalAgainTVApp: App {
    var body: some Scene { WindowGroup { TVContentView() } }
}

extension DeviceIdentity {
    var displayName: String {
        displayName(deviceName: UIDevice.current.name, model: UIDevice.current.model)
    }
}
