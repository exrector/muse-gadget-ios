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

}
