import AudioToolbox
@preconcurrency import AVFoundation
import CoreLocation
import CoreMotion
import Darwin
import Foundation
import ImageIO
import UIKit

/// Retained, bounded implementations for commands that touch native iOS services.
/// Permission prompts remain an explicit UI responsibility; remote invocations fail closed.
final class NativeCommandServices {
    /// The newest connection events, for `device.health`.
    var connectivityEvents: (() -> [[String: Any]])?
    private let permissions: PermissionCenter
    private let speech: NativeSpeechService
    private let location = NativeLocationService()
    private let motion = NativeMotionService()
    private let camera = NativeCameraService()
    private let recorder: NativeVoiceRecorderService

    init(permissions: PermissionCenter) {
        self.permissions = permissions
        let audioActivity = NativeAudioActivity()
        speech = NativeSpeechService(activity: audioActivity)
        recorder = NativeVoiceRecorderService(activity: audioActivity)
    }

    /// A bounded, privacy-safe health report. iOS does not expose processes, arbitrary files,
    /// SMART data or the other host-wide diagnostics available to the Linux gadget.
    func deviceHealth() -> [String: Any] {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let batteryLevel = UIDevice.current.batteryLevel
        let fileSystem = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        let process = ProcessInfo.processInfo
        let permissions = Dictionary(uniqueKeysWithValues: AppPermission.allCases.map {
            ($0.healthKey, self.permissions.status(for: $0).healthValue)
        })
        let brightness = min(max(Double(UIScreen.main.brightness), 0), 1)
        return [
            "system": UIDevice.current.systemName,
            "system_version": UIDevice.current.systemVersion,
            "model": UIDevice.current.model,
            "model_identifier": Self.modelIdentifier(),
            "battery_percent": batteryLevel < 0 ? NSNull() : Int((batteryLevel * 100).rounded()),
            "battery_state": Self.batteryState(UIDevice.current.batteryState),
            "charging": Self.charging(UIDevice.current.batteryState),
            "low_power_mode": process.isLowPowerModeEnabled,
            "thermal_state": Self.thermalState(process.thermalState),
            "device_uptime_seconds": Int(process.systemUptime),
            "storage_free_bytes": fileSystem?[.systemFreeSize] as? Int64 ?? NSNull(),
            "storage_total_bytes": fileSystem?[.systemSize] as? Int64 ?? NSNull(),
            "screen_brightness_percent": Int((brightness * 100).rounded()),
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            "foreground": UIApplication.shared.applicationState == .active,
            "permissions": permissions,
            "connectivity_events": connectivityEvents?() ?? []
        ]
    }

    private static func modelIdentifier() -> String {
        var info = utsname()
        uname(&info)
        var machine = info.machine
        let byteCount = MemoryLayout.size(ofValue: machine)
        return withUnsafePointer(to: &machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: byteCount) {
                String(cString: $0)
            }
        }
    }

    private static func batteryState(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .unknown: return "unknown"
        case .unplugged: return "unplugged"
        case .charging: return "charging"
        case .full: return "full"
        @unknown default: return "unknown"
        }
    }

    private static func charging(_ state: UIDevice.BatteryState) -> Any {
        switch state {
        case .charging, .full: return true
        case .unplugged: return false
        case .unknown: return NSNull()
        @unknown default: return NSNull()
        }
    }

    private static func thermalState(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func locationFailure(_ error: Error) -> CommandResult {
        let failure = error as NSError
        return CommandResult(success: false, value: [
            "error": "location_failed",
            "error_domain": failure.domain,
            "error_code": failure.code
        ])
    }

    func speak(text: String, completion: @escaping (CommandResult) -> Void) {
        onMain {
            guard Self.requireForeground(completion) else { return }
            self.speech.speak(text: text, completion: completion)
        }
    }

    func setBrightness(_ level: Double, completion: @escaping (CommandResult) -> Void) {
        onMain {
            guard Self.requireForeground(completion) else { return }
            let previous = Double(UIScreen.main.brightness)
            UIScreen.main.brightness = CGFloat(level)
            NotificationCenter.default.post(name: .museBrightnessChanged, object: nil)
            completion(CommandResult(success: true, value: ["level": level, "previous_level": previous]))
        }
    }

    func showCard(_ card: MuseCard?, completion: @escaping (CommandResult) -> Void) {
        onMain {
            guard Self.requireForeground(completion) else { return }
            NotificationCenter.default.post(name: .museCardChanged, object: card)
            completion(CommandResult(success: true, value: ["displayed": card != nil]))
        }
    }

    func setTorch(on: Bool, level: Double, completion: @escaping (CommandResult) -> Void) {
        onMain {
            guard Self.requireForeground(completion) else { return }
            guard let device = AVCaptureDevice.default(for: .video), device.hasTorch, device.isTorchAvailable else {
                completion(.failure("torch_unavailable"))
                return
            }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if on {
                    try device.setTorchModeOn(level: Float(level))
                } else {
                    device.torchMode = .off
                }
                completion(CommandResult(success: true, value: ["on": on]))
            } catch {
                completion(.failure("torch_failed"))
            }
        }
    }

    func playHaptic(completion: @escaping (CommandResult) -> Void) {
        onMain {
            guard Self.requireForeground(completion) else { return }
            switch MuseHapticRoute.current {
            case .impactGenerator:
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                completion(CommandResult(success: true, value: ["played": true, "method": "impact_generator"]))
            case .systemVibration:
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                completion(CommandResult(success: true, value: ["played": true, "method": "system_vibration"]))
            case .unavailable:
                completion(.failure("haptics_unavailable"))
            }
        }
    }

    func currentLocation(completion: @escaping (CommandResult) -> Void) {
        onMain {
            guard Self.requireForeground(completion),
                  self.requirePermission(.location, completion: completion) else { return }
            self.location.request(completion: completion)
        }
    }

    func motionSnapshot(completion: @escaping (CommandResult) -> Void) {
        onMain {
            guard Self.requireForeground(completion),
                  self.requirePermission(.motion, completion: completion) else { return }
            self.motion.snapshot(completion: completion)
        }
    }

    func capturePhoto(
        maxBytes: Int = 1_048_576,
        maxDimension: Int = 1_600,
        completion: @escaping (CommandResult) -> Void
    ) {
        onMain {
            guard Self.requireForeground(completion),
                  self.requirePermission(.camera, completion: completion) else { return }
            let bytes = min(max(maxBytes, 64 * 1024), 2 * 1024 * 1024)
            let dimension = min(max(maxDimension, 320), 1_600)
            self.camera.capture(maxBytes: bytes, maxDimension: dimension, completion: completion)
        }
    }

    func recordVoice(
        durationSeconds: TimeInterval = 10,
        completion: @escaping (CommandResult) -> Void
    ) {
        onMain {
            guard Self.requireForeground(completion),
                  self.requirePermission(.microphone, completion: completion) else { return }
            guard durationSeconds.isFinite, durationSeconds > 0 else {
                Self.deliver(.failure("invalid_arguments"), to: completion)
                return
            }
            NotificationCenter.default.post(name: .museDeviceAudioChanged, object: MuseDeviceAudio.listening)
            self.recorder.record(
                durationSeconds: min(durationSeconds, 15),
                maxBytes: 2 * 1024 * 1024
            ) { result in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .museDeviceAudioChanged, object: nil)
                }
                completion(result)
            }
        }
    }

    /// User-started voice note; ends at `maxDuration` or on `stopVoiceRecording()`.
    func recordVoiceNote(
        maxDuration: TimeInterval = 40,
        completion: @escaping (CommandResult) -> Void
    ) {
        onMain {
            guard Self.requireForeground(completion),
                  self.requirePermission(.microphone, completion: completion) else { return }
            self.recorder.record(
                durationSeconds: maxDuration,
                maxBytes: 2 * 1024 * 1024,
                completion: completion
            )
        }
    }

    func stopVoiceRecording() {
        onMain { self.recorder.stop() }
    }

    private func requirePermission(
        _ permission: AppPermission,
        completion: @escaping (CommandResult) -> Void
    ) -> Bool {
        let state = permissions.status(for: permission)
        switch state {
        case .granted:
            return true
        case .unavailable:
            Self.deliver(.failure("unavailable"), to: completion)
        case .notDetermined, .denied, .restricted:
            Self.deliver(CommandResult(success: false, value: [
                "error": "permission_required",
                "permission": permission.title,
                "permission_state": state.rawValue
            ]), to: completion)
        }
        return false
    }

    private static func requireForeground(_ completion: @escaping (CommandResult) -> Void) -> Bool {
        guard UIApplication.shared.applicationState == .active else {
            deliver(.failure("foreground_required"), to: completion)
            return false
        }
        return true
    }

    fileprivate static func deliver(
        _ result: CommandResult,
        to completion: @escaping (CommandResult) -> Void
    ) {
        if Thread.isMainThread { completion(result) }
        else { DispatchQueue.main.async { completion(result) } }
    }
}

private extension AppPermission {
    var healthKey: String {
        switch self {
        case .bluetooth: return "bluetooth"
        case .localNetwork: return "local_network"
        case .camera: return "camera"
        case .microphone: return "microphone"
        case .location: return "location"
        case .motion: return "motion"
        }
    }
}

private extension PermissionState {
    var healthValue: String {
        switch self {
        case .notDetermined: return "not_determined"
        case .granted: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .unavailable: return "unavailable"
        }
    }
}

struct MuseCard: Equatable, Identifiable, Codable {
    private enum CodingKeys: String, CodingKey {
        case title, body, kind, durationSeconds, progress, shownAt
    }

    private static let storageKey = "pinnedCard"

    /// The card outlives the app: what it stands for, such as a timer, goes on running on the VM.
    static func loadPinned() -> MuseCard? {
        UserDefaults.standard.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(MuseCard.self, from: $0) }
    }

    static func savePinned(_ card: MuseCard?) {
        if let card, let data = try? JSONEncoder().encode(card) {
            UserDefaults.standard.set(data, forKey: storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
    }

    let id = UUID()
    let title: String
    let body: String
    let kind: Kind
    let durationSeconds: TimeInterval?
    let progress: Double?
    let shownAt: Date

    enum Kind: String, Equatable, Codable {
        case info
        case timer
        case progress
    }

    init(
        title: String,
        body: String,
        kind: Kind = .info,
        durationSeconds: TimeInterval? = nil,
        progress: Double? = nil,
        shownAt: Date = Date()
    ) {
        self.title = title
        self.body = body
        self.kind = kind
        self.durationSeconds = durationSeconds
        self.progress = progress
        self.shownAt = shownAt
    }

    static func interpreted(
        title: String,
        body: String,
        kind explicitKind: Kind?,
        durationSeconds explicitDuration: TimeInterval?,
        progress: Double?,
        shownAt: Date = Date()
    ) -> MuseCard {
        var kind = explicitKind ?? .info
        var duration = explicitDuration
        if explicitKind == nil,
           duration == nil,
           (title + " " + body).lowercased().range(of: #"(timer|таймер)"#, options: .regularExpression) != nil,
           let inferred = inferredDuration(from: title + " " + body) {
            kind = .timer
            duration = inferred
        }
        return MuseCard(
            title: title,
            body: body,
            kind: kind,
            durationSeconds: duration,
            progress: progress,
            shownAt: shownAt
        )
    }

    private static func inferredDuration(from text: String) -> TimeInterval? {
        let pattern = #"([0-9]+(?:[.,][0-9]+)?)\s*(seconds?|secs?|секунд[а-я]*|сек|minutes?|mins?|минут[а-я]*|мин|hours?|hrs?|час[а-я]*)"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let numberRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let number = Double(text[numberRange].replacingOccurrences(of: ",", with: ".")) else { return nil }
        let unit = text[unitRange].lowercased()
        let multiplier: Double
        if unit.hasPrefix("h") || unit.hasPrefix("час") { multiplier = 3_600 }
        else if unit.hasPrefix("m") || unit.hasPrefix("мин") { multiplier = 60 }
        else { multiplier = 1 }
        let duration = number * multiplier
        return duration.isFinite && (1...86_400).contains(duration) ? duration : nil
    }

    static func == (lhs: MuseCard, rhs: MuseCard) -> Bool {
        lhs.title == rhs.title
            && lhs.body == rhs.body
            && lhs.kind == rhs.kind
            && lhs.durationSeconds == rhs.durationSeconds
            && lhs.progress == rhs.progress
            && lhs.shownAt == rhs.shownAt
    }
}

/// What the speaker or microphone is doing because of a command, so the screen can say so.
enum MuseDeviceAudio {
    case speaking
    case listening
}

enum MuseSpeechVolume {
    private static let key = "speechVolume"

    /// 0 to 100. A missing value reads as full volume.
    static var current: Int {
        guard let stored = UserDefaults.standard.object(forKey: key) as? Int else { return 100 }
        return min(max(stored, 0), 100)
    }

    static func set(_ volume: Int) {
        UserDefaults.standard.set(min(max(volume, 0), 100), forKey: key)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .museSpeechVolumeChanged, object: nil)
        }
    }
}

extension Notification.Name {
    static let museDeviceAudioChanged = Notification.Name("MuseGadgetLegacy.deviceAudioChanged")
    static let museSpeechVolumeChanged = Notification.Name("MuseGadgetLegacy.speechVolumeChanged")
    static let museBrightnessChanged = Notification.Name("MuseGadgetLegacy.brightnessChanged")
    static let museCardChanged = Notification.Name("MuseGadgetLegacy.cardChanged")
}

/// `UIImpactFeedbackGenerator` silently does nothing before iPhone 7 while still looking successful,
/// so iPhone 6s and older use the system vibration, and devices without a vibration motor say so.
enum MuseHapticRoute: Equatable {
    case impactGenerator
    case systemVibration
    case unavailable

    static var current: MuseHapticRoute {
        route(machine: machineIdentifier)
    }

    static func route(machine: String) -> MuseHapticRoute {
        let prefix = "iPhone"
        guard machine.hasPrefix(prefix),
              let major = Int(machine.dropFirst(prefix.count).prefix(while: \.isNumber)) else {
            return .unavailable
        }
        return major >= 9 ? .impactGenerator : .systemVibration
    }

    static var machineIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

private extension CommandResult {
    static func failure(_ code: String) -> CommandResult {
        CommandResult(success: false, value: ["error": code])
    }
}

private final class NativeCompletionGate {
    private let lock = NSLock()
    private var completed = false
    private let completion: (CommandResult) -> Void

    init(_ completion: @escaping (CommandResult) -> Void) {
        self.completion = completion
    }

    @discardableResult
    func finish(_ result: CommandResult) -> Bool {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return false
        }
        completed = true
        lock.unlock()
        NativeCommandServices.deliver(result, to: completion)
        return true
    }
}

private final class NativeAudioActivity {
    private let lock = NSLock()
    private var active = false

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !active else { return false }
        active = true
        return true
    }

    func end() {
        lock.lock()
        active = false
        lock.unlock()
    }
}

/// Delegate callbacks and all mutation are confined to the main thread.
private final class NativeSpeechService: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let activity: NativeAudioActivity
    private var speechID: String?

    init(activity: NativeAudioActivity) {
        self.activity = activity
        super.init()
        synthesizer.delegate = self
    }

    func speak(text: String, completion: @escaping (CommandResult) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 1_000 else {
            NativeCommandServices.deliver(.failure("invalid_text"), to: completion)
            return
        }
        guard !synthesizer.isSpeaking else {
            NativeCommandServices.deliver(.failure("busy"), to: completion)
            return
        }
        guard activity.begin() else {
            NativeCommandServices.deliver(.failure("busy"), to: completion)
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            activity.end()
            NativeCommandServices.deliver(.failure("audio_session_failed"), to: completion)
            return
        }

        let identifier = UUID().uuidString.lowercased()
        speechID = identifier
        let utterance = AVSpeechUtterance(string: value)
        utterance.volume = Float(MuseSpeechVolume.current) / 100
        synthesizer.speak(utterance)
        NotificationCenter.default.post(name: .museDeviceAudioChanged, object: MuseDeviceAudio.speaking)
        NativeCommandServices.deliver(CommandResult(success: true, value: [
            "accepted": true,
            "speaking": true,
            "speech_id": identifier
        ]), to: completion)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finishAudioSession()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finishAudioSession()
    }

    private func finishAudioSession() {
        speechID = nil
        NotificationCenter.default.post(name: .museDeviceAudioChanged, object: nil)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        activity.end()
    }
}

private final class NativeLocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var gate: NativeCompletionGate?
    private var timeout: DispatchWorkItem?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func request(completion: @escaping (CommandResult) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard gate == nil else {
            NativeCommandServices.deliver(.failure("busy"), to: completion)
            return
        }
        guard CLLocationManager.locationServicesEnabled() else {
            NativeCommandServices.deliver(.failure("unavailable"), to: completion)
            return
        }

        gate = NativeCompletionGate(completion)
        let work = DispatchWorkItem { [weak self] in self?.finish(.failure("timeout")) }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last(where: {
            $0.horizontalAccuracy >= 0 && abs($0.timestamp.timeIntervalSinceNow) < 30
        }) else {
            finish(.failure("unavailable"))
            return
        }
        var payload: [String: Any] = [
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "horizontal_accuracy_m": location.horizontalAccuracy,
            "timestamp": ISO8601DateFormatter().string(from: location.timestamp)
        ]
        if location.verticalAccuracy >= 0 {
            payload["altitude_m"] = location.altitude
            payload["vertical_accuracy_m"] = location.verticalAccuracy
        }
        finish(CommandResult(success: true, value: payload))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(NativeCommandServices.locationFailure(error))
    }

    private func finish(_ result: CommandResult) {
        guard let gate else { return }
        timeout?.cancel()
        timeout = nil
        self.gate = nil
        gate.finish(result)
    }
}

private final class NativeMotionService {
    private let manager = CMMotionManager()
    private var gate: NativeCompletionGate?
    private var timeout: DispatchWorkItem?
    private var samples = 0

    func snapshot(completion: @escaping (CommandResult) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard gate == nil else {
            NativeCommandServices.deliver(.failure("busy"), to: completion)
            return
        }
        guard manager.isDeviceMotionAvailable else {
            NativeCommandServices.deliver(.failure("unavailable"), to: completion)
            return
        }

        gate = NativeCompletionGate(completion)
        samples = 0
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        let work = DispatchWorkItem { [weak self] in self?.finish(.failure("timeout")) }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        manager.startDeviceMotionUpdates(to: .main) { [weak self] data, error in
            guard let self else { return }
            if error != nil {
                self.finish(.failure("motion_failed"))
                return
            }
            guard let data else { return }
            self.samples += 1
            guard self.samples >= 3 else { return }
            let attitude = data.attitude
            self.finish(CommandResult(success: true, value: [
                "timestamp_s": data.timestamp,
                "gravity": Self.vector(data.gravity),
                "user_acceleration": Self.vector(data.userAcceleration),
                "rotation_rate": Self.vector(data.rotationRate),
                "attitude": [
                    "roll": attitude.roll,
                    "pitch": attitude.pitch,
                    "yaw": attitude.yaw,
                    "quaternion": [
                        "x": attitude.quaternion.x,
                        "y": attitude.quaternion.y,
                        "z": attitude.quaternion.z,
                        "w": attitude.quaternion.w
                    ]
                ]
            ]))
        }
    }

    private static func vector(_ value: CMAcceleration) -> [String: Double] {
        ["x": value.x, "y": value.y, "z": value.z]
    }

    private static func vector(_ value: CMRotationRate) -> [String: Double] {
        ["x": value.x, "y": value.y, "z": value.z]
    }

    private func finish(_ result: CommandResult) {
        guard let gate else { return }
        manager.stopDeviceMotionUpdates()
        timeout?.cancel()
        timeout = nil
        self.gate = nil
        gate.finish(result)
    }
}

enum MuseJPEG {
    static func bounded(_ data: Data, maxBytes: Int, maxDimension: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else { return nil }

        let dimensions = [maxDimension, 1_280, 1_024, 800, 640]
            .filter { $0 <= maxDimension }
        for dimension in dimensions {
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: dimension,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
                continue
            }
            for quality in [0.82, 0.70, 0.58, 0.46, 0.35] {
                let encoded = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(
                    encoded,
                    "public.jpeg" as CFString,
                    1,
                    nil
                ) else { continue }
                CGImageDestinationAddImage(destination, image, [
                    kCGImageDestinationLossyCompressionQuality: quality
                ] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { continue }
                let result = encoded as Data
                if result.count <= maxBytes { return result }
            }
        }
        return nil
    }
}

private final class NativeCameraService: NSObject, AVCapturePhotoCaptureDelegate {
    private let sessionQueue = DispatchQueue(label: "MuseGadgetLegacy.camera")
    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var configured = false
    private var gate: NativeCompletionGate?
    private var timeout: DispatchWorkItem?
    private var maxBytes = 1_048_576
    private var maxDimension = 1_600

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationEnteredBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func capture(
        maxBytes: Int,
        maxDimension: Int,
        completion: @escaping (CommandResult) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard UIApplication.shared.applicationState == .active else {
            NativeCommandServices.deliver(.failure("foreground_required"), to: completion)
            return
        }
        sessionQueue.async { [self] in
            guard self.gate == nil else {
                NativeCommandServices.deliver(.failure("busy"), to: completion)
                return
            }

            let gate = NativeCompletionGate(completion)
            self.gate = gate
            self.maxBytes = maxBytes
            self.maxDimension = maxDimension
            do {
                try self.configureIfNeeded()
                self.session.startRunning()
                guard self.session.isRunning else { throw NativeServiceError.unavailable }
                let settings: AVCapturePhotoSettings
                if self.output.availablePhotoCodecTypes.contains(.jpeg) {
                    settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                } else {
                    settings = AVCapturePhotoSettings()
                }
                settings.flashMode = .off
                let work = DispatchWorkItem { [weak self, weak gate] in
                    guard let self, let gate else { return }
                    self.finish(.failure("timeout"), gate: gate)
                }
                self.timeout = work
                self.sessionQueue.asyncAfter(deadline: .now() + 12, execute: work)
                // Exposure needs a moment after the session starts, or the first frame is dark.
                self.sessionQueue.asyncAfter(deadline: .now() + 0.7) { [weak gate] in
                    guard let gate, self.gate === gate else { return }
                    self.output.capturePhoto(with: settings, delegate: self)
                }
            } catch {
                self.finish(.failure("unavailable"), gate: gate)
            }
        }
    }

    private func configureIfNeeded() throws {
        guard !configured else { return }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw NativeServiceError.unavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw NativeServiceError.unavailable
        }
        session.addInput(input)
        session.addOutput(output)
        configured = true
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        sessionQueue.async {
            guard let gate = self.gate else { return }
            guard error == nil, let original = photo.fileDataRepresentation(),
                  let encoded = MuseJPEG.bounded(
                    original,
                    maxBytes: self.maxBytes,
                    maxDimension: self.maxDimension
                  ), let source = CGImageSourceCreateWithData(encoded as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
                self.finish(.failure("capture_failed"), gate: gate)
                return
            }
            self.finish(CommandResult(success: true, value: [
                "mime_type": "image/jpeg",
                "data_base64": encoded.base64EncodedString(),
                "byte_count": encoded.count,
                "width": width.intValue,
                "height": height.intValue,
                "captured_at": ISO8601DateFormatter().string(from: Date())
            ]), gate: gate)
        }
    }

    private func finish(_ result: CommandResult, gate: NativeCompletionGate) {
        guard self.gate === gate else { return }
        timeout?.cancel()
        timeout = nil
        if session.isRunning { session.stopRunning() }
        self.gate = nil
        gate.finish(result)
    }

    @objc private func applicationEnteredBackground() {
        sessionQueue.async {
            guard let gate = self.gate else { return }
            self.finish(.failure("foreground_required"), gate: gate)
        }
    }
}

private final class NativeVoiceRecorderService: NSObject, AVAudioRecorderDelegate {
    private let activity: NativeAudioActivity
    private var recorder: AVAudioRecorder?
    private var gate: NativeCompletionGate?
    private var timeout: DispatchWorkItem?
    private var fileURL: URL?
    private var maxBytes = 2 * 1024 * 1024

    init(activity: NativeAudioActivity) {
        self.activity = activity
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationEnteredBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func record(
        durationSeconds: TimeInterval,
        maxBytes: Int,
        completion: @escaping (CommandResult) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard gate == nil else {
            NativeCommandServices.deliver(.failure("busy"), to: completion)
            return
        }
        guard activity.begin() else {
            NativeCommandServices.deliver(.failure("busy"), to: completion)
            return
        }

        let gate = NativeCompletionGate(completion)
        self.gate = gate
        self.maxBytes = maxBytes
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-voice-\(UUID().uuidString.lowercased()).wav")
        fileURL = url

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
            try session.setActive(true)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 24_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            self.recorder = recorder
            guard recorder.prepareToRecord(), recorder.record(forDuration: durationSeconds) else {
                throw NativeServiceError.unavailable
            }
            let work = DispatchWorkItem { [weak self, weak gate] in
                guard let self, let gate else { return }
                self.finish(.failure("timeout"), gate: gate)
            }
            timeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + durationSeconds + 2, execute: work)
        } catch {
            finish(.failure("recording_failed"), gate: gate)
        }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        recorder?.stop()
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard let gate else { return }
        guard flag, let url = fileURL, let data = try? Data(contentsOf: url),
              !data.isEmpty, data.count <= maxBytes else {
            finish(.failure(flag ? "payload_too_large" : "recording_failed"), gate: gate)
            return
        }
        finish(CommandResult(success: true, value: [
            "mime_type": "audio/wav",
            "data_base64": data.base64EncodedString(),
            "byte_count": data.count,
            "duration_ms": data.count * 1_000 / 48_000,
            "sample_rate": 24_000,
            "channels": 1
        ]), gate: gate)
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        guard let gate else { return }
        finish(.failure("recording_failed"), gate: gate)
    }

    private func finish(_ result: CommandResult, gate: NativeCompletionGate) {
        guard self.gate === gate else { return }
        timeout?.cancel()
        timeout = nil
        self.gate = nil
        recorder?.stop()
        recorder = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        activity.end()
        gate.finish(result)
    }

    @objc private func applicationEnteredBackground() {
        guard let gate else { return }
        finish(.failure("foreground_required"), gate: gate)
    }
}

private enum NativeServiceError: Error {
    case unavailable
}

private func onMain(_ work: @escaping () -> Void) {
    if Thread.isMainThread { work() }
    else { DispatchQueue.main.async(execute: work) }
}
