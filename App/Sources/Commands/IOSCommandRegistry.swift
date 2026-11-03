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
            let required = Dictionary(uniqueKeysWithValues: definition.parameters.map { name, rawSpec in
                let spec = rawSpec as? [String: Any]
                let type = spec?["type"] as? String ?? "string"
                let description = spec?["description"] as? String
                    ?? "Value for \(name.replacingOccurrences(of: "_", with: " "))."
                return (name, ["type": type, "description": description])
            })
            return (definition.name, [
                "description": definition.summary,
                "required": required,
                "optional": [:],
                "timeout_ms": 30_000
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
        let lock = NSLock()
        var completed = false
        var timeout: DispatchWorkItem?
        let finish: (CommandResult) -> Void = { result in
            lock.lock()
            guard !completed else { lock.unlock(); return }
            completed = true
            lock.unlock()
            timeout?.cancel()
            completion(result)
        }
        timeout = DispatchWorkItem {
            finish(CommandResult(success: false, value: ["error": "command_timeout"]))
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30, execute: timeout!)
        handler(arguments, finish)
    }

    static func defaultRegistry(nativeServices: NativeCommandServices) -> IOSCommandRegistry {
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
            nativeServices.speak(text: text, completion: completion)
        }

        registry.register(CommandDefinition(
            name: "haptics.impact",
            summary: "Play a user-visible impact haptic.",
            parameters: [:]
        )) { _, completion in
            nativeServices.playHaptic(completion: completion)
        }

        // Results travel over link.result, which Muse bounds at 256 KiB after base64.
        registry.register(CommandDefinition(
            name: "camera.capture",
            summary: "Capture a compact JPEG while the app is visible and camera access is granted.",
            parameters: [:]
        )) { _, completion in
            nativeServices.capturePhoto(maxBytes: 96 * 1024, maxDimension: 800, completion: completion)
        }

        registry.register(CommandDefinition(
            name: "location.current",
            summary: "Read one location while the app is visible and access is granted.",
            parameters: [:]
        )) { _, completion in
            nativeServices.currentLocation(completion: completion)
        }

        registry.register(CommandDefinition(
            name: "motion.snapshot",
            summary: "Read a bounded motion sensor snapshot while the app is visible.",
            parameters: [:]
        )) { _, completion in
            nativeServices.motionSnapshot(completion: completion)
        }

        registry.register(CommandDefinition(
            name: "voice.record",
            summary: "Record a short voice sample while the app is visible and microphone access is granted.",
            parameters: [:]
        )) { _, completion in
            nativeServices.recordVoice(durationSeconds: 2, completion: completion)
        }

        return registry
    }
}

extension Notification.Name {
    static let museCaptionChanged = Notification.Name("MuseGadgetLegacy.captionChanged")
}

