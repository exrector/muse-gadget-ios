import Foundation
import UIKit

struct CommandDefinition {
    let name: String
    let summary: String
    let parameters: [String: Any]
    var optional: [String: Any] = [:]
    var timeoutMS = 30_000
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
                "required": Self.parameterSpecs(definition.parameters),
                "optional": Self.parameterSpecs(definition.optional),
                "timeout_ms": definition.timeoutMS
            ])
        })
    }

    private static func parameterSpecs(_ parameters: [String: Any]) -> [String: [String: String]] {
        Dictionary(uniqueKeysWithValues: parameters.map { name, rawSpec in
            let spec = rawSpec as? [String: Any]
            let type = spec?["type"] as? String ?? "string"
            let description = spec?["description"] as? String
                ?? "Value for \(name.replacingOccurrences(of: "_", with: " "))."
            return (name, ["type": type, "description": description])
        })
    }

    var names: [String] { definitions.keys.sorted() }

    func register(_ definition: CommandDefinition, handler: @escaping CommandHandler) {
        precondition(definitions[definition.name] == nil, "Duplicate command \(definition.name)")
        definitions[definition.name] = definition
        handlers[definition.name] = handler
    }

    func invoke(name: String, arguments: [String: Any], completion: @escaping (CommandResult) -> Void) {
        guard let handler = handlers[name], let definition = definitions[name] else {
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
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + .milliseconds(definition.timeoutMS),
            execute: timeout!
        )
        handler(arguments, finish)
    }

    static func defaultRegistry(
        nativeServices: NativeCommandServices,
        shortcuts: MuseShortcutsBridge,
        grants: MuseGrantStore,
        lan: MuseLANServices
    ) -> IOSCommandRegistry {
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

        registry.register(CommandDefinition(
            name: "display.set_brightness",
            summary: "Set the screen brightness while the app is visible.",
            parameters: ["level": ["type": "number", "description": "Brightness from 0.0 to 1.0."]]
        )) { arguments, completion in
            guard let level = (arguments["level"] as? NSNumber)?.doubleValue, (0...1).contains(level) else {
                completion(CommandResult(success: false, value: ["error": "invalid_level"]))
                return
            }
            nativeServices.setBrightness(level, completion: completion)
        }

        registry.register(CommandDefinition(
            name: "display.show_card",
            summary: "Show a card with a title and optional text at the top of the gadget's chat screen.",
            parameters: ["title": ["type": "string", "description": "Short title, up to 120 characters."]],
            optional: ["body": ["type": "string", "description": "Plain text, up to 1000 characters."]]
        )) { arguments, completion in
            guard let title = arguments["title"] as? String, !title.isEmpty, title.count <= 120 else {
                completion(CommandResult(success: false, value: ["error": "invalid_title"]))
                return
            }
            let body = arguments["body"] as? String ?? ""
            guard body.count <= 1_000 else {
                completion(CommandResult(success: false, value: ["error": "invalid_body"]))
                return
            }
            nativeServices.showCard(MuseCard(title: title, body: body), completion: completion)
        }

        registry.register(CommandDefinition(
            name: "display.clear_card",
            summary: "Remove the card shown on the gadget's screen.",
            parameters: [:]
        )) { _, completion in
            nativeServices.showCard(nil, completion: completion)
        }

        registry.register(CommandDefinition(
            name: "torch.set",
            summary: "Turn the device flashlight on or off while the app is visible. Fails on devices without one.",
            parameters: ["on": ["type": "boolean", "description": "True to turn the flashlight on."]],
            optional: ["level": ["type": "number", "description": "Strength from 0.1 to 1.0. Default 1.0."]]
        )) { arguments, completion in
            guard let on = arguments["on"] as? Bool else {
                completion(CommandResult(success: false, value: ["error": "invalid_arguments"]))
                return
            }
            let level = (arguments["level"] as? NSNumber)?.doubleValue ?? 1
            guard (0.1...1).contains(level) else {
                completion(CommandResult(success: false, value: ["error": "invalid_level"]))
                return
            }
            nativeServices.setTorch(on: on, level: level, completion: completion)
        }

        registry.register(CommandDefinition(
            name: "shortcuts.run",
            summary: "Run an Apple Shortcut by its exact name, to reach things like the Home app, reminders or messages. "
                + "The person at the device approves each new name on screen. The screen switches to Shortcuts and back. "
                + "Returns finished=false if the shortcut is still running after 25 seconds, and the shortcut's text output as result.",
            parameters: ["name": ["type": "string", "description": "Exact name of the shortcut."]],
            optional: ["input": ["type": "string", "description": "Text passed to the shortcut, up to 4 KiB."]],
            timeoutMS: 55_000
        )) { arguments, completion in
            guard let name = arguments["name"] as? String else {
                completion(CommandResult(success: false, value: ["error": "invalid_name"]))
                return
            }
            let input = arguments["input"] as? String
            DispatchQueue.main.async { shortcuts.run(name: name, input: input, completion: completion) }
        }

        registry.register(CommandDefinition(
            name: "shortcuts.list",
            summary: "List the shortcut names already approved on this device. iOS does not let apps see any others.",
            parameters: [:]
        )) { _, completion in
            completion(CommandResult(success: true, value: ["approved": grants.shortcuts]))
        }

        registry.register(CommandDefinition(
            name: "lan.discover",
            summary: "Browse the local network for about 4 seconds using Bonjour and list devices with name, service_type, "
                + "txt, host and port. Service types: " + MuseLANDiscovery.declaredServiceTypes.joined(separator: ", ") + ".",
            parameters: [:],
            optional: ["service_type": ["type": "string", "description": "Browse only this service type, such as _hue._tcp."]]
        )) { arguments, completion in
            lan.discover(arguments: arguments, completion: completion)
        }

        registry.register(CommandDefinition(
            name: "lan.request",
            summary: "Send one HTTP request to a device on the local network and return status, headers and body. "
                + "Only private IPv4 addresses and .local names. The person at the device approves each new host and port on screen. "
                + "Redirects are returned, not followed. Bodies over 128 KiB are cut off with truncated=true. "
                + "HTTP and HTTPS only; no WebSocket, MQTT, UDP or raw TCP.",
            parameters: ["host": ["type": "string", "description": "Private IPv4 address or .local name."]],
            optional: [
                "port": ["type": "integer", "description": "Default 80 for http, 443 for https."],
                "scheme": ["type": "string", "description": "http or https. Default http."],
                "method": ["type": "string", "description": "GET, HEAD, POST, PUT, PATCH or DELETE. Default GET."],
                "path": ["type": "string", "description": "Path and query, starting with /. Default /."],
                "headers": ["type": "object", "description": "Request headers as string values."],
                "body": ["type": "string", "description": "Text body, up to 256 KiB."],
                "body_base64": ["type": "string", "description": "Binary body, base64-encoded."],
                "timeout_ms": ["type": "integer", "description": "From 1000 to 15000. Default 8000."]
            ],
            timeoutMS: 45_000
        )) { arguments, completion in
            lan.request(arguments: arguments, completion: completion)
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

