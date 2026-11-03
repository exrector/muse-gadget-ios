import Foundation
import UIKit

enum MuseShortcutCallback: Equatable {
    case success(result: String?)
    case cancelled
    case failed(message: String?)
}

/// Builds and reads the documented `shortcuts://x-callback-url` links.
enum MuseShortcutLink {
    static let callbackScheme = "musegadget"
    private static let callbackHost = "shortcut"

    static func runURL(name: String, input: String?, token: String) -> URL? {
        var parts = [
            "name=\(encode(name))",
            "x-success=\(encode(callback("success", token: token)))",
            "x-cancel=\(encode(callback("cancel", token: token)))",
            "x-error=\(encode(callback("error", token: token)))"
        ]
        if let input, !input.isEmpty {
            parts.insert(contentsOf: ["input=text", "text=\(encode(input))"], at: 1)
        }
        return URL(string: "shortcuts://x-callback-url/run-shortcut?" + parts.joined(separator: "&"))
    }

    static func parse(_ url: URL) -> (token: String, callback: MuseShortcutCallback)? {
        guard url.scheme == callbackScheme, url.host == callbackHost,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let token = items.first(where: { $0.name == "token" })?.value else { return nil }
        let value = { (name: String) in items.first(where: { $0.name == name })?.value }
        switch url.path {
        case "/success": return (token, .success(result: value("result")))
        case "/cancel": return (token, .cancelled)
        case "/error": return (token, .failed(message: value("errorMessage")))
        default: return nil
        }
    }

    private static func callback(_ outcome: String, token: String) -> String {
        "\(callbackScheme)://\(callbackHost)/\(outcome)?token=\(token)"
    }

    private static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

/// Runs only the Shortcuts the user approved on this device. Main thread only.
final class MuseShortcutsBridge {
    private struct ActiveRun {
        let token: String
        let completion: (CommandResult) -> Void
        let timeout: DispatchWorkItem
        var backgroundTask: UIBackgroundTaskIdentifier
    }

    private static let maxInputBytes = 4 * 1024
    private static let maxResultBytes = 16 * 1024

    private let grants: MuseGrantStore
    private let approvals: MuseApprovalCenter
    private var active: ActiveRun?

    init(grants: MuseGrantStore, approvals: MuseApprovalCenter) {
        self.grants = grants
        self.approvals = approvals
    }

    func run(name rawName: String, input: String?, completion: @escaping (CommandResult) -> Void) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200, name == MuseDisplayText.sanitized(name) else {
            completion(CommandResult(success: false, value: ["error": "invalid_name"]))
            return
        }
        guard (input?.utf8.count ?? 0) <= Self.maxInputBytes else {
            completion(CommandResult(success: false, value: ["error": "input_too_large"]))
            return
        }
        guard UIApplication.shared.applicationState == .active else {
            completion(CommandResult(success: false, value: ["error": "foreground_required"]))
            return
        }
        guard active == nil else {
            completion(CommandResult(success: false, value: ["error": "busy"]))
            return
        }
        if grants.allowsShortcut(name) {
            launch(name: name, input: input, completion: completion)
            return
        }
        approvals.ask(
            title: "Запустить Быструю команду?",
            message: "Muse просит запустить «\(name)». Если разрешить, дальше она будет запускаться без вопроса. Отозвать можно в настройках."
        ) { [weak self] decision in
            guard let self else { return }
            guard case .granted = decision else {
                completion(CommandResult(success: false, value: ["error": decision.errorCode]))
                return
            }
            self.grants.allowShortcut(name)
            self.launch(name: name, input: input, completion: completion)
        }
    }

    /// Returns true when the URL belonged to the shortcut run in progress.
    @discardableResult
    func handleCallback(_ url: URL) -> Bool {
        guard let parsed = MuseShortcutLink.parse(url), parsed.token == active?.token else { return false }
        switch parsed.callback {
        case .success(let result):
            var value: [String: Any] = ["started": true, "finished": true]
            if let result {
                value["result"] = String(decoding: result.utf8.prefix(Self.maxResultBytes), as: UTF8.self)
            }
            finish(CommandResult(success: true, value: value))
        case .cancelled:
            finish(CommandResult(success: false, value: ["error": "shortcut_cancelled"]))
        case .failed:
            // Shortcuts' own message can quote user data, so only the code goes back to Muse.
            finish(CommandResult(success: false, value: ["error": "shortcut_failed"]))
        }
        return true
    }

    private func launch(name: String, input: String?, completion: @escaping (CommandResult) -> Void) {
        let token = UUID().uuidString.lowercased()
        guard active == nil, let url = MuseShortcutLink.runURL(name: name, input: input, token: token) else {
            completion(CommandResult(success: false, value: ["error": active == nil ? "invalid_name" : "busy"]))
            return
        }
        let timeout = DispatchWorkItem { [weak self] in
            // The shortcut may still be working; report that honestly rather than a failure.
            self?.finish(CommandResult(success: true, value: ["started": true, "finished": false]))
        }
        // Keeps the Muse connection alive long enough to report the result from behind Shortcuts.
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "MuseShortcut") { [weak self] in
            self?.finish(CommandResult(success: true, value: ["started": true, "finished": false]))
        }
        active = ActiveRun(token: token, completion: completion, timeout: timeout, backgroundTask: backgroundTask)
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: timeout)
        UIApplication.shared.open(url, options: [:]) { [weak self] opened in
            if !opened {
                self?.finish(CommandResult(success: false, value: ["error": "shortcuts_unavailable"]))
            }
        }
    }

    private func finish(_ result: CommandResult) {
        guard let run = active else { return }
        active = nil
        run.timeout.cancel()
        run.completion(result)
        if run.backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(run.backgroundTask)
        }
    }
}
