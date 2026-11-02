import AVFoundation
import CoreLocation
import CoreMotion
import Foundation
import Speech

enum AppPermission: CaseIterable {
    case bluetooth
    case camera
    case microphone
    case speechRecognition
    case location
    case motion

    var title: String {
        switch self {
        case .bluetooth: return "Bluetooth pairing"
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        case .speechRecognition: return "Speech recognition"
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
    private lazy var locationManager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        return manager
    }()
    private var locationCompletion: ((PermissionState) -> Void)?

    func status(for permission: AppPermission) -> PermissionState {
        switch permission {
        case .bluetooth:
            return .notDetermined // CoreBluetooth reports the definitive state to the pairing dashboard.
        case .camera:
            return map(AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone:
            return map(AVAudioSession.sharedInstance().recordPermission)
        case .speechRecognition:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .granted
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .unavailable
            }
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
            completion(.notDetermined)
        case .camera:
            AVCaptureDevice.requestAccess(for: .video) { _ in
                DispatchQueue.main.async { completion(self.status(for: permission)) }
            }
        case .microphone:
            AVAudioSession.sharedInstance().requestRecordPermission { _ in
                DispatchQueue.main.async { completion(self.status(for: permission)) }
            }
        case .speechRecognition:
            SFSpeechRecognizer.requestAuthorization { _ in
                DispatchQueue.main.async { completion(self.status(for: permission)) }
            }
        case .location:
            locationCompletion = completion
            locationManager.requestWhenInUseAuthorization()
        case .motion:
            guard CMMotionActivityManager.isActivityAvailable() else { completion(.unavailable); return }
            let manager = CMMotionActivityManager()
            manager.queryActivityStarting(from: Date(), to: Date(), to: .main) { _, _ in
                completion(self.status(for: permission))
            }
        }
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

