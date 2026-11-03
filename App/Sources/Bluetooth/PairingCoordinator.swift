import Foundation
import os
import SystemConfiguration.CaptiveNetwork

final class PairingCoordinator: NSObject {
    private static let sdkTokenPattern = try! NSRegularExpression(
        pattern: #"^mgst_[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]$"#
    )

    enum State: Equatable {
        case idle
        case needsSDKToken
        case bluetooth(String)
        case advertising(String)
        case connected(mtu: Int)
        case encrypted
        case provisioning
        case paired
        case failed(String)

        var title: String {
            switch self {
            case .idle: return "Ready"
            case .needsSDKToken: return "SDK token required"
            case .bluetooth(let value): return "Bluetooth: \(value)"
            case .advertising(let name): return "Advertising as \(name)"
            case .connected(let mtu): return "Muse connected · MTU \(mtu)"
            case .encrypted: return "Encrypted pairing confirmed"
            case .provisioning: return "Saving device credentials"
            case .paired: return "Paired · Bluetooth no longer required"
            case .failed(let message): return "Error: \(message)"
            }
        }
    }

    var onStateChange: ((State) -> Void)?
    var onLog: ((String) -> Void)?

    private let identity: DeviceIdentity
    private let credentials: CredentialStore
    private let logger = Logger(subsystem: "com.exrector.MuseGadgetLegacy", category: "pairing")
    private let queue = DispatchQueue(label: "MuseGadgetLegacy.pairing")
    private let assembler = BLEChunkAssembler()
    private var peripheral: MusePeripheral?
    private var session: PairingSession?

    private(set) var state: State = .idle {
        didSet { DispatchQueue.main.async { self.onStateChange?(self.state) } }
    }

    init(identity: DeviceIdentity, credentials: CredentialStore) {
        self.identity = identity
        self.credentials = credentials
        super.init()
        if credentials.loadDeviceCredentials() != nil { state = .paired }
    }

    func saveSDKToken(_ rawToken: String) throws {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(token.startIndex..<token.endIndex, in: token)
        guard Self.sdkTokenPattern.firstMatch(in: token, range: range)?.range == range else {
            throw PairingCoordinatorError.invalidSDKToken
        }
        try credentials.saveSDKToken(token)
        if state == .needsSDKToken { state = .idle }
        log("SDK token saved in Keychain")
    }

    func start() {
        guard let sdkToken = credentials.loadSDKToken(), !sdkToken.isEmpty else {
            state = .needsSDKToken
            return
        }
        stop(clearSessionOnly: true)
        let session = PairingSession(identity: identity, firmwareVersion: "ios-0.1.0", sdkToken: sdkToken)
        let peripheral = MusePeripheral(localName: identity.bluetoothName)
        peripheral.delegate = self
        self.session = session
        self.peripheral = peripheral
        state = .bluetooth("starting")
        log("Opening ten-minute pairing window for \(identity.bluetoothName)")
        peripheral.start()
    }

    func stop() {
        stop(clearSessionOnly: false)
        state = credentials.loadDeviceCredentials() == nil ? .idle : .paired
    }

    func forgetPairing() {
        stop(clearSessionOnly: false)
        credentials.clearPairing()
        state = .idle
        log("Device credentials removed; stable device identity retained")
    }

    private func stop(clearSessionOnly: Bool) {
        peripheral?.stop()
        peripheral = nil
        session?.reset()
        session = nil
        assembler.reset()
        if !clearSessionOnly { log("Bluetooth pairing window closed") }
    }

    private func handle(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = object["action"] as? String,
              let session else {
            log("Ignored malformed setup message")
            return
        }

        do {
            switch action {
            case "get_device_info":
                try sendJSON(session.deviceInfo)
                log("Sent public device_info")

            case "pairing_client_hello":
                let ready = try session.handleHello(object)
                try sendJSON(ready)
                log("Pairing v5 keys established; waiting for encrypted client confirmation")

            case "pairing_encrypted":
                let command = try session.decrypt(object)
                try handleDecrypted(command, session: session)

            default:
                log("Ignored unsupported plaintext action \(action)")
            }
        } catch {
            state = .failed(String(describing: error))
            log("Setup protocol error: \(error)")
        }
    }

    private func handleDecrypted(_ command: [String: Any], session: PairingSession) throws {
        guard let action = command["action"] as? String else { throw PairingError.invalidMessage }
        switch action {
        case "pairing_client_finished":
            try session.confirmClientFinished(command)
            try sendJSON(session.encryptStatus("pairing_confirmed"))
            state = .encrypted
            log("Muse app confirmed encrypted pairing")

        case "wifi_scan":
            let networks: [[String: Any]]
            if let ssid = CurrentWiFi.ssid() {
                networks = [["ssid": ssid, "rssi": -40, "secure": false]]
                log("Offered the iOS device's current Wi-Fi network")
            } else {
                networks = []
                log("Current Wi-Fi name unavailable; grant Location permission and retry")
            }
            let response: [String: Any] = ["type": "wifi_scan_result", "networks": networks]
            try sendJSON(session.encrypt(response))

        case "provision_v2":
            try provision(command, session: session)

        default:
            log("Ignored unsupported encrypted action \(action)")
        }
    }

    private func provision(_ command: [String: Any], session: PairingSession) throws {
        guard let accessToken = command["access_token"] as? String, !accessToken.isEmpty,
              let refreshToken = command["refresh_token"] as? String, !refreshToken.isEmpty,
              command["token_type"] as? String == "device" else {
            try sendJSON(session.encryptStatus("error_missing_credentials"))
            return
        }
        try session.beginProvisioning()
        state = .provisioning
        try sendJSON(session.encryptStatus("wifi_connecting"))
        try sendJSON(session.encryptStatus("wifi_connected"))

        let saved = DeviceCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            username: command["username"] as? String ?? "",
            apiURL: command["api_url"] as? String ?? "",
            apiURLV2: command["api_url_v2"] as? String ?? "",
            noiseHost: command["noise_host"] as? String ?? "",
            savedAt: Date()
        )
        try credentials.saveDeviceCredentials(saved)
        try sendJSON(session.encryptStatus("auth_ok")) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.peripheral?.stop()
                self?.log("BLE stopped; the next stage is Wi-Fi-only Muse VM registration")
            }
        }
        state = .paired
        log("Device credentials stored in Keychain; pairing complete")
    }

    private func sendJSON(_ object: [String: Any], completion: (() -> Void)? = nil) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let packets = try BLEFraming.encode(data, mtu: peripheral?.transportMTU ?? 23)
        DispatchQueue.main.async { self.peripheral?.send(packets, completion: completion) }
    }

    private func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        DispatchQueue.main.async { self.onLog?(message) }
    }
}

private enum CurrentWiFi {
    static func ssid() -> String? {
        guard let interfaces = CNCopySupportedInterfaces() as? [String] else { return nil }
        for interface in interfaces {
            guard let info = CNCopyCurrentNetworkInfo(interface as CFString) as? [String: Any],
                  let ssid = info[kCNNetworkInfoKeySSID as String] as? String,
                  !ssid.isEmpty else { continue }
            return ssid
        }
        return nil
    }
}

extension PairingCoordinator: MusePeripheralDelegate {
    func musePeripheral(_ peripheral: MusePeripheral, didChange event: MusePeripheral.Event) {
        switch event {
        case .bluetoothState(let value):
            switch value {
            case "unauthorized":
                state = .failed("Bluetooth permission is denied. Enable it in Settings → Privacy & Security → Bluetooth.")
            case "unsupported":
                state = .failed("Bluetooth LE peripheral mode is unavailable. Pairing requires a physical iPhone or iPad, not Simulator.")
            case "powered off":
                state = .bluetooth("Turn Bluetooth on to continue")
            case "powered on":
                state = .bluetooth("publishing pairing service")
            default:
                state = .bluetooth(value)
            }
        case .advertising: state = .advertising(identity.bluetoothName)
        case .subscribed(let mtu): state = .connected(mtu: mtu)
        case .disconnected:
            session?.reset()
            assembler.reset()
            state = .advertising(identity.bluetoothName)
        case .error(let message): state = .failed(message)
        }
        log("BLE: \(event)")
    }

    func musePeripheral(_ peripheral: MusePeripheral, didReceive packet: Data) {
        queue.async { [weak self] in
            guard let self, let message = self.assembler.feed(packet) else { return }
            self.handle(message)
        }
    }
}

enum PairingCoordinatorError: LocalizedError {
    case invalidSDKToken

    var errorDescription: String? {
        "Enter your personal Muse Gadget SDK token beginning with mgst_."
    }
}
