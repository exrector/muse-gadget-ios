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

/// How this gadget describes itself to Muse, as the SDK's protocols/DEVICE.md asks: device_family
/// "gadget", a stable model_id with a prefix of our own, a model name people know, and the
/// Markdown guide that `device.guide` returns.
enum MuseDeviceDescription {
    static let deviceFamily = "gadget"
    static let guideCommand = "device.guide"
    static let maxGuideBytes = 4096

    /// Names the hardware class, not the build: `pal-again-iphone`, `pal-again-ipad`.
    static func modelID(isPad: Bool) -> String { isPad ? "pal-again-ipad" : "pal-again-iphone" }

    /// "iPhone 6s", "iPad (6th generation)"; an unknown identifier keeps it, as "iPhone (iPhone18,2)".
    static func modelName(machine: String, isPad: Bool) -> String {
        if let known = knownModels[machine] { return known }
        let family = isPad ? "iPad" : "iPhone"
        let clean = String(machine.unicodeScalars.filter { (0x20...0x7e).contains($0.value) && $0 != "\"" && $0 != "\\" }
            .map(Character.init).prefix(100))
        return clean.isEmpty ? family : "\(family) (\(clean))"
    }

    private static let knownModels: [String: String] = [
        "iPhone8,1": "iPhone 6s", "iPhone8,2": "iPhone 6s Plus", "iPhone8,4": "iPhone SE",
        "iPhone9,1": "iPhone 7", "iPhone9,3": "iPhone 7", "iPhone9,2": "iPhone 7 Plus", "iPhone9,4": "iPhone 7 Plus",
        "iPhone10,1": "iPhone 8", "iPhone10,4": "iPhone 8", "iPhone10,2": "iPhone 8 Plus", "iPhone10,5": "iPhone 8 Plus",
        "iPhone10,3": "iPhone X", "iPhone10,6": "iPhone X", "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max",
        "iPhone11,6": "iPhone XS Max", "iPhone11,8": "iPhone XR", "iPhone12,1": "iPhone 11",
        "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max", "iPhone12,8": "iPhone SE (2nd generation)",
        "iPad5,1": "iPad mini 4", "iPad5,2": "iPad mini 4", "iPad5,3": "iPad Air 2", "iPad5,4": "iPad Air 2",
        "iPad6,11": "iPad (5th generation)", "iPad6,12": "iPad (5th generation)",
        "iPad7,5": "iPad (6th generation)", "iPad7,6": "iPad (6th generation)",
        "iPad7,11": "iPad (7th generation)", "iPad7,12": "iPad (7th generation)",
        "iPad11,1": "iPad mini (5th generation)", "iPad11,2": "iPad mini (5th generation)",
        "iPad11,3": "iPad Air (3rd generation)", "iPad11,4": "iPad Air (3rd generation)",
        "iPad6,3": "iPad Pro (9.7-inch)", "iPad6,4": "iPad Pro (9.7-inch)",
        "iPad6,7": "iPad Pro (12.9-inch)", "iPad6,8": "iPad Pro (12.9-inch)"
    ]

    static let guide = """
# Pal Again

An iPhone or iPad running Pal Again, an app that makes the device a Muse gadget. It keeps an encrypted Link session with Muse over the device's own internet connection. Muse uses it only through the commands it lists; each command's description says what it does and returns.

## What it is for

A screen, speaker, microphone, camera and set of sensors next to the owner, with a chat with Muse on its screen. The owner can also type, send photos, voice notes and documents, and talk with Muse live by voice or video from the app. Those reach Muse as chat messages, not as commands.

## Using it

- It works only while Pal Again is open on screen. iOS suspends apps in the background, so commands then fail with `foreground_required`. Ask the owner to open the app rather than retrying.
- Protected features need an iOS permission the owner already gave. A command never shows a permission prompt; it fails with `permission_required`, and only the owner can allow it in iOS Settings.
- `display.set_caption` and `display.show_card` put text on the screen; a card stays until `display.clear_card`. `display.draw_file` shows a picture from the VM above the chat until `display.clear_image`.
- `display.set_avatar`, `display.set_name` and `display.play_avatar` set Muse's own face and name on this gadget. Change them only when the owner asks.
- `audio.speak` uses the device's speaker. `voice.record` records about two seconds from its microphone, only while the app is on screen.
- `shortcuts.run` runs an Apple Shortcut by its exact name. The first time a name is used the owner must tap Allow on the device; until then it fails. `shortcuts.list` returns only names already allowed: iOS does not let apps see the owner's shortcuts.
- `lan.discover` lists devices that announce themselves on the local network. `lan.request` sends one HTTP or HTTPS request, only to private IPv4 addresses and `.local` names, and the first request to each device needs the owner's tap. WebSocket, MQTT, UDP and raw sockets are not available.

## Hardware differences

- iPads have no vibration motor: `haptics.impact` returns `haptics_unavailable`.
- Devices without a flash return `torch_unavailable` from `torch.set`.
- `device.health` reports battery, thermal state, storage, permissions, the app version and recent connection events.

## Limits

- No shell, no files outside the app's own folder, no reading the owner's photos, messages or other apps.
- Up to four commands run at once; more are refused with `device busy`.
- If the gadget stops answering, the owner reopens Pal Again; it reconnects by itself.
"""
}

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
        lan: MuseLANServices,
        images: MuseVMImageService
    ) -> IOSCommandRegistry {
        let registry = IOSCommandRegistry()

        registry.register(CommandDefinition(
            name: MuseDeviceDescription.guideCommand,
            summary: "This device's usage guide (Markdown): what it is, its controls and limits.",
            parameters: [:],
            timeoutMS: 5_000
        )) { _, completion in
            completion(CommandResult(success: true, value: ["format": "markdown", "guide": MuseDeviceDescription.guide]))
        }

        registry.register(CommandDefinition(
            name: "device.health",
            summary: "Report app-visible power, thermal, storage, display, permission and version health without private user data.",
            parameters: [:]
        )) { _, completion in
            DispatchQueue.main.async {
                completion(CommandResult(success: true, value: nativeServices.deviceHealth()))
            }
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
            summary: "Show or update the pinned live card above the gadget chat. Use kind=timer with duration_seconds for a countdown, or kind=progress with progress from 0 to 1.",
            parameters: ["title": ["type": "string", "description": "Short title, up to 120 characters."]],
            optional: [
                "body": ["type": "string", "description": "Plain text, up to 1000 characters."],
                "kind": ["type": "string", "description": "Card type: info, timer, or progress."],
                "duration_seconds": ["type": "number", "description": "For a timer: countdown duration from 1 to 86400 seconds."],
                "progress": ["type": "number", "description": "For progress: completion from 0.0 to 1.0."]
            ]
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
            let explicitKind = (arguments["kind"] as? String).flatMap(MuseCard.Kind.init(rawValue:))
            let kind = explicitKind ?? .info
            let duration = (arguments["duration_seconds"] as? NSNumber)?.doubleValue
            let progress = (arguments["progress"] as? NSNumber)?.doubleValue
            guard duration.map({ $0.isFinite && (1...86_400).contains($0) }) ?? true,
                  progress.map({ $0.isFinite && (0...1).contains($0) }) ?? true else {
                completion(CommandResult(success: false, value: ["error": "invalid_card_state"]))
                return
            }
            guard kind != .timer || duration != nil,
                  kind != .progress || progress != nil else {
                completion(CommandResult(success: false, value: ["error": "missing_card_state"]))
                return
            }
            nativeServices.showCard(
                MuseCard.interpreted(
                    title: title,
                    body: body,
                    kind: explicitKind,
                    durationSeconds: duration,
                    progress: progress
                ),
                completion: completion
            )
        }

        registry.register(CommandDefinition(
            name: "display.clear_card",
            summary: "Remove the card shown on the gadget's screen.",
            parameters: [:]
        )) { _, completion in
            nativeServices.showCard(nil, completion: completion)
        }

        registry.register(CommandDefinition(
            name: "display.set_avatar",
            summary: "Set this gadget's picture of you from a file on your VM, ideally what you already have in your profile. The device keeps it and shows it beside your name. To make it move, call this once for each of idle, listening, thinking and speaking that you have. A state you don't have plays idle, so nothing has to be drawn. For live voice calls, add call_speaking too: a short loop of you facing forward and talking, mouth opening and closing, with no gestures. The device plays it only while your voice is heard in a call. MP4 with H.264 plays at once; GIF, APNG and WebP also work, but take the device a long time to prepare, so converting to MP4 is welcome. Keep workspace/pal-again/avatars.json up to date, as {\"name\":\"Your name\",\"animations\":{\"idle\":{\"path\":\"workspace/idle.mp4\",\"bytes\":123}}}: the user's other gadgets read it when they connect and fetch what is new, so they need no separate call.",
            parameters: ["path": [
                "type": "string",
                "description": "Path of the image file on this VM, relative, as the VM's file API takes it, such as workspace/avatar.mp4. At most 32 MiB."
            ]],
            optional: ["state": [
                "type": "string",
                "description": "Which movement this animation is: idle, listening, thinking or speaking, which the device plays by itself, or any other short name you start with display.play_avatar. Leave it out for a still picture."
            ]],
            timeoutMS: 180_000
        )) { arguments, completion in
            images.installAvatar(
                path: arguments["path"] as? String ?? "",
                state: arguments["state"] as? String,
                completion: completion
            )
        }

        registry.register(CommandDefinition(
            name: "display.set_name",
            summary: "Set the name shown beside your avatar on this gadget. Use your own name in Muse. The device keeps it across restarts.",
            parameters: ["name": ["type": "string", "description": "Your name, one line of up to 40 characters."]]
        )) { arguments, completion in
            guard MuseAgentName.save(arguments["name"] as? String ?? "") else {
                completion(CommandResult(success: false, value: ["error": "invalid_name"]))
                return
            }
            completion(CommandResult(success: true, value: ["name": MuseAgentName.saved ?? ""]))
        }

        registry.register(CommandDefinition(
            name: "display.play_avatar",
            summary: "Play one of the avatar's movements once, such as a reaction you added with display.set_avatar, then go back to what it was doing. An unknown name fails and lists the available ones.",
            parameters: ["name": ["type": "string", "description": "Name of the movement."]]
        )) { arguments, completion in
            images.playAvatar(name: arguments["name"] as? String ?? "", completion: completion)
        }

        registry.register(CommandDefinition(
            name: "display.clear_avatar",
            summary: "Remove the picture set with display.set_avatar and go back to the default mark.",
            parameters: [:]
        )) { _, completion in
            images.clearAvatar()
            completion(CommandResult(success: true, value: ["cleared": true]))
        }

        registry.register(CommandDefinition(
            name: "display.draw_file",
            summary: "Show an image file from your VM above the gadget's chat. The device reads the file over its connection to the VM, so the file need not be on the internet: to show a picture from the web, save it on the VM first. Replies when the image is on screen. It stays until the user closes it or you call display.clear_image.",
            parameters: ["path": [
                "type": "string",
                "description": "Path of the image file on this VM, relative, as the VM's file API takes it, such as workspace/picture.jpg. At most 32 MiB."
            ]],
            timeoutMS: 180_000
        )) { arguments, completion in
            images.draw(path: arguments["path"] as? String ?? "", completion: completion)
        }

        registry.register(CommandDefinition(
            name: "display.clear_image",
            summary: "Remove the image shown with display.draw_file.",
            parameters: [:]
        )) { _, completion in
            images.clearDrawnImage()
            completion(CommandResult(success: true, value: ["cleared": true]))
        }

        registry.register(CommandDefinition(
            name: "voice.configure",
            summary: "Set how loud audio.speak speaks on this device, kept across restarts. Without volume, reports the current one. The device's own volume buttons still apply on top.",
            parameters: [:],
            optional: ["volume": ["type": "integer", "description": "Speech volume, 0 to 100."]]
        )) { arguments, completion in
            if let raw = arguments["volume"] {
                guard let volume = (raw as? NSNumber)?.doubleValue, (0...100).contains(volume) else {
                    completion(CommandResult(success: false, value: ["error": "invalid_volume"]))
                    return
                }
                MuseSpeechVolume.set(Int(volume))
            }
            completion(CommandResult(success: true, value: ["volume": MuseSpeechVolume.current]))
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

