import Foundation

struct MuseVM: Decodable {
    let url: String
    let authorizationToken: String
    let name: String
    let identifier: String
    let isDefault: Bool

    init?(wire: [String: Any]) {
        guard let url = (wire["vm_ws_url"] ?? wire["vm_url"]) as? String,
              let token = wire["vm_auth_token"] as? String else { return nil }
        self.url = url
        self.authorizationToken = token
        self.name = wire["vm_name"] as? String ?? ""
        self.identifier = wire["vm_id"] as? String ?? ""
        self.isDefault = wire["default"] as? Bool ?? false
    }
}

enum MuseAPIError: Error {
    case invalidURL
    case invalidResponse
    case unauthorized
    case server(Int)
}

final class MuseAPIClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchVMs(credentials: DeviceCredentials, completion: @escaping (Result<[MuseVM], Error>) -> Void) {
        let root = credentials.apiURLV2.isEmpty ? "https://api.muse.ai" : credentials.apiURLV2
        guard let url = URL(string: root.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/fetch_vms") else {
            completion(.failure(MuseAPIError.invalidURL)); return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("1.0.0", forHTTPHeaderField: "X-API-Version")
        request.setValue("muse-gadget-ios/0.1.0", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(MuseAPIError.invalidResponse)); return
            }
            if http.statusCode == 401 { completion(.failure(MuseAPIError.unauthorized)); return }
            guard (200..<300).contains(http.statusCode), let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = object["vm_list"] as? [[String: Any]] else {
                completion(.failure(MuseAPIError.server(http.statusCode))); return
            }
            completion(.success(list.compactMap(MuseVM.init(wire:))))
        }.resume()
    }
}

final class MuseWebSocketTransport {
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func connect(url: URL, bearer: String) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("muse-gadget-ios/0.1.0", forHTTPHeaderField: "User-Agent")
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
    }

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        task?.send(.data(data), completionHandler: completion)
    }

    func receive(_ completion: @escaping (Result<Data, Error>) -> Void) {
        task?.receive { result in
            completion(result.flatMap { message in
                switch message {
                case .data(let data): return .success(data)
                case .string(let text): return .success(Data(text.utf8))
                @unknown default: return .failure(MuseAPIError.invalidResponse)
                }
            })
        }
    }

    func close() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
}

enum RuntimeMilestone: String {
    case pairedCredentials = "paired_credentials"
    case fetchedVM = "fetched_vm"
    case webSocketConnected = "websocket_connected"
    case noiseEstablished = "noise_established"
    case linkRegistered = "link_registered"
}

/// Integration seam for the next stage. Noise XX and Link framing are kept
/// separate from BLE pairing so Bluetooth can stop immediately after auth_ok.
final class MuseRuntime {
    private let api = MuseAPIClient()
    private let webSocket = MuseWebSocketTransport()

    func start(credentials: DeviceCredentials, milestone: @escaping (RuntimeMilestone) -> Void) {
        milestone(.pairedCredentials)
        api.fetchVMs(credentials: credentials) { result in
            guard case .success(let vms) = result, let vm = vms.first(where: { $0.isDefault }) ?? vms.first else { return }
            milestone(.fetchedVM)
            // Noise URL construction and handshake intentionally remain the
            // next verified milestone; do not report registration before it.
            _ = vm
        }
    }
}

