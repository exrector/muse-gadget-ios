import AVFoundation
import Foundation
import UIKit

struct CommandDefinition {
    let name: String
    let summary: String
    let parameters: [String: Any]
}

struct CommandResult {
    let success: Bool
    let value: [String: Any]
}

typealias CommandHandler = ([String: Any], @escaping (CommandResult) -> Void) -> Void

final class IOSCommandRegistry {
    private var definitions: [String: CommandDefinition] = [:]
    private var handlers: [String: CommandHandler] = [:]

    var commandSpecs: [String: Any] {
        Dictionary(uniqueKeysWithValues: definitions.values.map { definition in
            (definition.name, [
                "description": definition.summary,
                "parameters": definition.parameters
            ])
        })
    }

    var names: [String] { definitions.keys.sorted() }

    func register(_ definition: CommandDefinition, handler: @escaping CommandHandler) {
        precondition(definitions[definition.name] == nil, "Duplicate command \(definition.name)")
        definitions[definition.name] = definition
        handlers[definition.name] = handler
    }

    func invoke(name: String, arguments: [String: Any], completion: @escaping (CommandResult) -> Void) {
        guard let handler = handlers[name] else {
            completion(CommandResult(success: false, value: ["error": "unsupported_command"]))
            return
        }
        handler(arguments, completion)
    }

    static func defaultRegistry(permissions: PermissionCenter) -> IOSCommandRegistry {
        let registry = IOSCommandRegistry()

        registry.register(CommandDefinition(
            name: "device.health",
            summary: "Report app-visible device health without private user data.",
            parameters: [:]
        )) { _, completion in
            UIDevice.current.isBatteryMonitoringEnabled = true
            let battery = UIDevice.current.batteryLevel
            let fileValues = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            let free = fileValues?[.systemFreeSize] as? NSNumber
            completion(CommandResult(success: true, value: [
                "system": UIDevice.current.systemName,
                "system_version": UIDevice.current.systemVersion,
                "model": UIDevice.current.model,
                "battery_percent": battery < 0 ? NSNull() : Int(battery * 100),
                "free_bytes": free?.int64Value ?? 0,
                "uptime_seconds": Int(ProcessInfo.processInfo.systemUptime)
            ]))
        }

        registry.register(CommandDefinition(
            name: "display.set_caption",
            summary: "Show a short plain-text caption inside the gadget app.",
            parameters: ["text": ["type": "string", "maxLength": 500]]
        )) { arguments, completion in
            guard let text = arguments["text"] as? String, text.utf8.count <= 500 else {
                completion(CommandResult(success: false, value: ["error": "invalid_text"]))
                return
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .museCaptionChanged, object: text)
                completion(CommandResult(success: true, value: ["displayed": true]))
            }
        }

        registry.register(CommandDefinition(
            name: "audio.speak",
            summary: "Speak supplied text through the device speaker while the app is active.",
            parameters: ["text": ["type": "string", "maxLength": 1000]]
        )) { arguments, completion in
            guard let text = arguments["text"] as? String, text.utf8.count <= 1000 else {
                completion(CommandResult(success: false, value: ["error": "invalid_text"]))
                return
            }
            DispatchQueue.main.async {
                let utterance = AVSpeechUtterance(string: text)
                AVSpeechSynthesizer().speak(utterance)
                completion(CommandResult(success: true, value: ["speaking": true]))
            }
        }

        registry.register(CommandDefinition(
            name: "haptics.impact",
            summary: "Play a user-visible impact haptic.",
            parameters: [:]
        )) { _, completion in
            DispatchQueue.main.async {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                completion(CommandResult(success: true, value: ["played": true]))
            }
        }

        for (name, summary, permission) in [
            ("camera.capture", "Capture a photo after user-granted camera access.", AppPermission.camera),
            ("location.current", "Read location while the app is active and permission is granted.", AppPermission.location),
            ("motion.snapshot", "Read a bounded motion sensor snapshot.", AppPermission.motion),
            ("voice.record", "Record a bounded voice note after microphone permission.", AppPermission.microphone)
        ] {
            registry.register(CommandDefinition(name: name, summary: summary, parameters: [:])) { _, completion in
                let state = permissions.status(for: permission)
                completion(CommandResult(success: false, value: [
                    "error": state == .granted ? "not_implemented" : "permission_required",
                    "permission": permission.title,
                    "permission_state": state.rawValue
                ]))
            }
        }
        return registry
    }
}

extension Notification.Name {
    static let museCaptionChanged = Notification.Name("MuseGadgetLegacy.captionChanged")
}

