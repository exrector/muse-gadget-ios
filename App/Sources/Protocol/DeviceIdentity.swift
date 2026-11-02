import Foundation
import Security

struct DeviceIdentity: Codable, Equatable {
    let mac: String

    var suffix: String {
        String(mac.replacingOccurrences(of: ":", with: "").suffix(6))
    }

    var nodeID: String { "homelink-\(suffix)" }
    var deviceID: String { "hatch-link:\(mac)" }
    var bluetoothName: String { "MuseGadget\(suffix.uppercased())" }
}

final class DeviceIdentityStore {
    private let defaults: UserDefaults
    private let key = "MuseGadgetLegacy.deviceIdentity.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadOrCreate() -> DeviceIdentity {
        if let data = defaults.data(forKey: key),
           let identity = try? JSONDecoder().decode(DeviceIdentity.self, from: data),
           Self.isValid(mac: identity.mac) {
            return identity
        }

        var bytes = [UInt8](repeating: 0, count: 6)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        bytes[0] = (bytes[0] & 0xFC) | 0x02
        let mac = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
        let identity = DeviceIdentity(mac: mac)
        defaults.set(try? JSONEncoder().encode(identity), forKey: key)
        return identity
    }

    private static func isValid(mac: String) -> Bool {
        mac.range(of: #"^[0-9a-f]{2}(:[0-9a-f]{2}){5}$"#, options: .regularExpression) != nil
    }
}

