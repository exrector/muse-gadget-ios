import Foundation
import UIKit

struct MuseLANGrant: Codable, Equatable, Identifiable {
    let host: String
    let port: Int
    var certificateSHA256: String?

    var id: String { "\(host):\(port)" }
}

/// What the user has allowed Muse to reach. Grants are made only by a tap on this device.
final class MuseGrantStore {
    private struct Stored: Codable {
        var shortcuts: [String] = []
        var lanDevices: [MuseLANGrant] = []
    }

    var onChange: (() -> Void)?

    private let defaults: UserDefaults
    private let key = "MuseGadgetLegacy.grants"
    private let lock = NSLock()
    private var stored: Stored

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        stored = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
    }

    var shortcuts: [String] { read { $0.shortcuts } }
    var lanDevices: [MuseLANGrant] { read { $0.lanDevices } }

    func allowsShortcut(_ name: String) -> Bool { read { $0.shortcuts.contains(name) } }

    func allowShortcut(_ name: String) {
        update { if !$0.shortcuts.contains(name) { $0.shortcuts.append(name) } }
    }

    func revokeShortcut(_ name: String) {
        update { $0.shortcuts.removeAll { $0 == name } }
    }

    func lanGrant(host: String, port: Int) -> MuseLANGrant? {
        read { $0.lanDevices.first { $0.host == host && $0.port == port } }
    }

    func allowLANDevice(host: String, port: Int) {
        update { stored in
            if !stored.lanDevices.contains(where: { $0.host == host && $0.port == port }) {
                stored.lanDevices.append(MuseLANGrant(host: host, port: port, certificateSHA256: nil))
            }
        }
    }

    func revokeLANDevice(_ grant: MuseLANGrant) {
        update { $0.lanDevices.removeAll { $0.id == grant.id } }
    }

    /// Trust on first use: the user approved this device, so its first certificate is the one to expect.
    func trustCertificate(host: String, port: Int, sha256: String) -> Bool {
        var trusted = false
        update { stored in
            guard let index = stored.lanDevices.firstIndex(where: { $0.host == host && $0.port == port }) else {
                return
            }
            if let expected = stored.lanDevices[index].certificateSHA256 {
                trusted = expected == sha256
            } else {
                stored.lanDevices[index].certificateSHA256 = sha256
                trusted = true
            }
        }
        return trusted
    }

    private func read<T>(_ body: (Stored) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(stored)
    }

    private func update(_ body: (inout Stored) -> Void) {
        lock.lock()
        let before = try? JSONEncoder().encode(stored)
        body(&stored)
        let after = try? JSONEncoder().encode(stored)
        let changed = before != after
        if changed { defaults.set(after, forKey: key) }
        lock.unlock()
        guard changed else { return }
        DispatchQueue.main.async { self.onChange?() }
    }
}

struct MuseApprovalPrompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

enum MuseApprovalDecision {
    case granted
    case denied
    case timedOut
    case busy
    case notVisible

    var errorCode: String {
        switch self {
        case .granted: return ""
        case .denied: return "denied_by_user"
        case .timedOut: return "approval_timeout"
        case .busy: return "busy"
        case .notVisible: return "foreground_required"
        }
    }
}

/// Holds a remote command until the person at the device answers. Main thread only.
final class MuseApprovalCenter {
    var onPromptChange: ((MuseApprovalPrompt?) -> Void)?

    private var completion: ((MuseApprovalDecision) -> Void)?
    private var timeout: DispatchWorkItem?

    func ask(
        title: String,
        message: String,
        waitSeconds: TimeInterval = 20,
        completion: @escaping (MuseApprovalDecision) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard UIApplication.shared.applicationState == .active else {
            completion(.notVisible)
            return
        }
        guard self.completion == nil else {
            completion(.busy)
            return
        }
        self.completion = completion
        let work = DispatchWorkItem { [weak self] in self?.finish(.timedOut) }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + waitSeconds, execute: work)
        onPromptChange?(MuseApprovalPrompt(title: title, message: message))
    }

    func answer(granted: Bool) {
        finish(granted ? .granted : .denied)
    }

    private func finish(_ decision: MuseApprovalDecision) {
        guard let completion else { return }
        self.completion = nil
        timeout?.cancel()
        timeout = nil
        onPromptChange?(nil)
        completion(decision)
    }
}

enum MuseDisplayText {
    /// Remote text shown in a prompt: controls removed and bounded, so it cannot hide what is asked.
    static func sanitized(_ text: String, maxLength: Int = 200) -> String {
        let scalars = text.unicodeScalars.filter { scalar in
            !(scalar.value < 0x20 || (0x7f...0x9f).contains(scalar.value))
                && !(0x202a...0x202e).contains(scalar.value)
                && !(0x2066...0x2069).contains(scalar.value)
        }
        let clean = String(String.UnicodeScalarView(scalars))
        return clean.count > maxLength ? String(clean.prefix(maxLength)) + "…" : clean
    }
}
