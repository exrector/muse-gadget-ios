import AVFoundation
import CoreBluetooth
import CoreLocation
import CoreMotion
import dnssd
import Foundation
import Network

enum AppPermission: CaseIterable, Hashable {
    case bluetooth
    case localNetwork
    case camera
    case microphone
    case location
    case motion

    var title: String {
        switch self {
        case .bluetooth: return "Bluetooth pairing"
        case .localNetwork: return "Local network"
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        case .location: return "Location while in use"
        case .motion: return "Motion sensors"
        }
    }
}

enum PermissionState: String {
    case notDetermined = "Not requested"
    case granted = "Granted"
    case denied = "Denied"
    case restricted = "Restricted"
    case unavailable = "Unavailable"
}

final class PermissionCenter: NSObject {
    private var bluetoothManager: CBPeripheralManager?
    private var bluetoothCompletion: ((PermissionState) -> Void)?
    private lazy var locationManager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        return manager
    }()
    private var locationCompletion: ((PermissionState) -> Void)?
    private var localNetworkBrowser: NWBrowser?
    private var localNetworkCompletion: ((PermissionState) -> Void)?
    private var localNetworkTimeout: DispatchWorkItem?
    private var localNetworkState: PermissionState
    private var motionManager: CMMotionActivityManager?

    override init() {
        let saved = UserDefaults.standard.string(forKey: "MuseGadgetLegacy.localNetworkPermission")
        let restored = saved.flatMap(PermissionState.init(rawValue:))
        localNetworkState = restored == .unavailable ? .notDetermined : (restored ?? .notDetermined)
        super.init()
    }

    func status(for permission: AppPermission) -> PermissionState {
        switch permission {
        case .bluetooth:
            if #available(iOS 13.1, *) {
                switch CBManager.authorization {
                case .allowedAlways: return .granted
                case .denied: return .denied
                case .restricted: return .restricted
                case .notDetermined: return .notDetermined
                @unknown default: return .unavailable
                }
            }
            return .notDetermined
        case .localNetwork:
            return localNetworkState
        case .camera:
            return map(AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone:
            return map(AVAudioSession.sharedInstance().recordPermission)
        case .location:
            let value: CLAuthorizationStatus
            if #available(iOS 14.0, *) { value = locationManager.authorizationStatus }
            else { value = CLLocationManager.authorizationStatus() }
            switch value {
            case .authorizedAlways, .authorizedWhenInUse: return .granted
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .unavailable
            }
        case .motion:
            switch CMMotionActivityManager.authorizationStatus() {
            case .authorized: return .granted
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .unavailable
            }
        }
    }

    func request(_ permission: AppPermission, completion: @escaping (PermissionState) -> Void) {
        switch permission {
        case .bluetooth:
            let current = status(for: permission)
            guard current == .notDetermined else { completion(current); return }
            bluetoothCompletion = completion
            bluetoothManager = CBPeripheralManager(delegate: self, queue: .main)
        case .localNetwork:
            requestLocalNetwork(completion: completion)
        case .camera:
            AVCaptureDevice.requestAccess(for: .video) { _ in
                DispatchQueue.main.async { completion(self.status(for: permission)) }
            }
        case .microphone:
            AVAudioSession.sharedInstance().requestRecordPermission { _ in
                DispatchQueue.main.async { completion(self.status(for: permission)) }
            }
        case .location:
            let current = status(for: permission)
            guard current == .notDetermined else { completion(current); return }
            locationCompletion = completion
            locationManager.requestWhenInUseAuthorization()
        case .motion:
            guard CMMotionActivityManager.isActivityAvailable() else { completion(.unavailable); return }
            let manager = CMMotionActivityManager()
            motionManager = manager
            manager.queryActivityStarting(from: Date(), to: Date(), to: .main) { _, _ in
                completion(self.status(for: permission))
                self.motionManager = nil
            }
        }
    }

    func resetLocalNetworkStatusForRecheck() {
        guard localNetworkState != .granted else { return }
        localNetworkState = .notDetermined
        UserDefaults.standard.removeObject(forKey: "MuseGadgetLegacy.localNetworkPermission")
    }

    private func requestLocalNetwork(completion: @escaping (PermissionState) -> Void) {
        localNetworkBrowser?.cancel()
        localNetworkTimeout?.cancel()
        localNetworkCompletion = completion
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: "_muse-gadget._tcp", domain: nil),
            using: parameters
        )
        localNetworkBrowser = browser
        browser.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self, self.localNetworkCompletion != nil else { return }
                switch state {
                case .ready:
                    self.finishLocalNetworkRequest(.granted)
                case .waiting(let error):
                    self.finishLocalNetworkRequest(self.isLocalNetworkPolicyDenied(error) ? .denied : .unavailable)
                case .failed(let error):
                    self.finishLocalNetworkRequest(self.isLocalNetworkPolicyDenied(error) ? .denied : .unavailable)
                default:
                    break
                }
            }
        }
        browser.start(queue: DispatchQueue(label: "MuseGadgetLegacy.local-network-permission"))

        let timeout = DispatchWorkItem { [weak self] in
            self?.finishLocalNetworkRequest(.unavailable)
        }
        localNetworkTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    private func finishLocalNetworkRequest(_ state: PermissionState) {
        localNetworkState = state
        if state == .unavailable {
            UserDefaults.standard.removeObject(forKey: "MuseGadgetLegacy.localNetworkPermission")
        } else {
            UserDefaults.standard.set(state.rawValue, forKey: "MuseGadgetLegacy.localNetworkPermission")
        }
        let completion = localNetworkCompletion
        localNetworkCompletion = nil
        localNetworkTimeout?.cancel()
        localNetworkTimeout = nil
        localNetworkBrowser?.cancel()
        localNetworkBrowser = nil
        completion?(state)
    }

    private func isLocalNetworkPolicyDenied(_ error: NWError) -> Bool {
        guard case .dns(let code) = error else { return false }
        return code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied)
    }

    private func map(_ status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unavailable
        }
    }

    private func map(_ permission: AVAudioSession.RecordPermission) -> PermissionState {
        switch permission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .notDetermined
        @unknown default: return .unavailable
        }
    }
}

extension PermissionCenter: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard let completion = bluetoothCompletion else { return }
        bluetoothCompletion = nil
        completion(status(for: .bluetooth))
        bluetoothManager = nil
    }
}

extension PermissionCenter: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard let completion = locationCompletion else { return }
        locationCompletion = nil
        completion(status(for: .location))
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        guard #unavailable(iOS 14.0), let completion = locationCompletion else { return }
        locationCompletion = nil
        completion(self.status(for: .location))
    }
}

