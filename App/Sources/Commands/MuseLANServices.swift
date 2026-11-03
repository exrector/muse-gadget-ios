import CryptoKit
import Foundation
import Network
import Security
import UIKit

struct MuseLANRequest: Equatable {
    let url: URL
    let host: String
    let port: Int
    let method: String
    let headers: [String: String]
    let body: Data?
    let timeout: TimeInterval
}

/// Decides what a remote command may ask of the local network. It holds no state, so it can be tested.
enum MuseLANPolicy {
    static let maxRequestBodyBytes = 256 * 1024
    static let maxResponseBodyBytes = 128 * 1024

    private static let methods: Set<String> = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"]
    // URLSession owns these; letting a command set them could smuggle a second request.
    private static let forbiddenHeaders: Set<String> = [
        "host", "connection", "content-length", "transfer-encoding", "upgrade", "proxy-authorization"
    ]

    /// Only private IPv4 literals and `.local` names, so a command cannot reach the Internet.
    static func isAllowedHost(_ host: String) -> Bool {
        let host = host.lowercased()
        if host.hasSuffix(".local"), host.count > 6 {
            return host.unicodeScalars.allSatisfy { scalar in
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.").contains(scalar)
            }
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false).map { part -> Int? in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber),
                  part == "0" || !part.hasPrefix("0") else { return nil }
            return Int(part)
        }
        guard octets.count == 4, !octets.contains(where: { $0 == nil || $0! > 255 }) else { return false }
        let first = octets[0]!, second = octets[1]!
        return first == 10
            || (first == 172 && (16...31).contains(second))
            || (first == 192 && second == 168)
            || (first == 169 && second == 254)
    }

    static func request(from arguments: [String: Any]) -> Result<MuseLANRequest, MuseLANRequestError> {
        guard let host = (arguments["host"] as? String)?.lowercased(), isAllowedHost(host) else {
            return .failure(.init("host_not_local"))
        }
        let scheme = (arguments["scheme"] as? String)?.lowercased() ?? "http"
        guard scheme == "http" || scheme == "https" else { return .failure(.init("invalid_scheme")) }
        let port = (arguments["port"] as? NSNumber)?.intValue ?? (scheme == "https" ? 443 : 80)
        guard (1...65_535).contains(port) else { return .failure(.init("invalid_port")) }
        let method = ((arguments["method"] as? String) ?? "GET").uppercased()
        guard methods.contains(method) else { return .failure(.init("invalid_method")) }
        let path = (arguments["path"] as? String) ?? "/"
        guard path.hasPrefix("/"), path.utf8.count <= 4_096,
              !path.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7f }),
              let url = URL(string: "\(scheme)://\(host):\(port)\(path)") else {
            return .failure(.init("invalid_path"))
        }
        var headers: [String: String] = [:]
        if let raw = arguments["headers"] {
            guard let supplied = raw as? [String: String], supplied.count <= 32 else {
                return .failure(.init("invalid_headers"))
            }
            for (name, value) in supplied {
                guard !forbiddenHeaders.contains(name.lowercased()),
                      !name.isEmpty, name.utf8.count <= 128, value.utf8.count <= 8_192,
                      !(name + value).unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" }) else {
                    return .failure(.init("invalid_headers"))
                }
                headers[name] = value
            }
        }
        var body: Data?
        if let text = arguments["body"] as? String {
            body = Data(text.utf8)
        } else if let encoded = arguments["body_base64"] as? String {
            guard let decoded = Data(base64Encoded: encoded) else { return .failure(.init("invalid_body")) }
            body = decoded
        }
        guard (body?.count ?? 0) <= maxRequestBodyBytes else { return .failure(.init("body_too_large")) }
        let timeoutMS = (arguments["timeout_ms"] as? NSNumber)?.doubleValue ?? 8_000
        return .success(MuseLANRequest(
            url: url,
            host: host,
            port: port,
            method: method,
            headers: headers,
            body: body,
            timeout: min(max(timeoutMS / 1_000, 1), 15)
        ))
    }

    static func responseValue(
        status: Int,
        headers: [AnyHashable: Any],
        body: Data,
        truncated: Bool
    ) -> [String: Any] {
        var value: [String: Any] = ["status": status, "truncated": truncated]
        var shownHeaders: [String: String] = [:]
        for (name, content) in headers.prefix(64) {
            guard let name = name as? String else { continue }
            shownHeaders[name] = String(String(describing: content).prefix(2_048))
        }
        value["headers"] = shownHeaders
        // A truncated body can end inside a character, so trim the tail before deciding it is binary.
        var text = String(data: body, encoding: .utf8)
        if text == nil, truncated {
            for trim in 1...3 where body.count >= trim {
                text = String(data: body.dropLast(trim), encoding: .utf8)
                if text != nil { break }
            }
        }
        if let text { value["body"] = text } else { value["body_base64"] = body.base64EncodedString() }
        return value
    }
}

struct MuseLANRequestError: Error, Equatable {
    let code: String

    init(_ code: String) {
        self.code = code
    }
}

/// HTTP to devices the user approved. Redirects are never followed, so a device cannot point the
/// request anywhere else, and each device's certificate is pinned on first use.
final class MuseLANClient: NSObject, URLSessionDataDelegate {
    private final class Exchange {
        var response: HTTPURLResponse?
        var body = Data()
        var truncated = false
        var failure: String?
        let completion: (CommandResult) -> Void

        init(completion: @escaping (CommandResult) -> Void) {
            self.completion = completion
        }
    }

    private let grants: MuseGrantStore
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "MuseGadgetLegacy.lan"
        return queue
    }()
    private var exchanges: [Int: Exchange] = [:]

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.allowsCellularAccess = false
        configuration.waitsForConnectivity = false
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }()

    init(grants: MuseGrantStore) {
        self.grants = grants
    }

    func perform(_ request: MuseLANRequest, completion: @escaping (CommandResult) -> Void) {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let task = session.dataTask(with: urlRequest)
        queue.addOperation {
            self.exchanges[task.taskIdentifier] = Exchange(completion: completion)
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        exchanges[dataTask.taskIdentifier]?.response = response as? HTTPURLResponse
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let exchange = exchanges[dataTask.taskIdentifier] else { return }
        let room = MuseLANPolicy.maxResponseBodyBytes - exchange.body.count
        exchange.body.append(data.prefix(room))
        if data.count > room {
            exchange.truncated = true
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            // Device logins stay with Muse: it gets the 401 and its headers, and answers with its own.
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let trust = space.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            exchanges[task.taskIdentifier]?.failure = "tls_failed"
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let fingerprint = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
            .map { String(format: "%02x", $0) }.joined()
        if grants.trustCertificate(host: space.host.lowercased(), port: space.port, sha256: fingerprint) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            exchanges[task.taskIdentifier]?.failure = "tls_certificate_changed"
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let exchange = exchanges.removeValue(forKey: task.taskIdentifier) else { return }
        if let response = exchange.response, error == nil || exchange.truncated {
            exchange.completion(CommandResult(success: true, value: MuseLANPolicy.responseValue(
                status: response.statusCode,
                headers: response.allHeaderFields,
                body: exchange.body,
                truncated: exchange.truncated
            )))
        } else {
            let code = exchange.failure ?? Self.errorCode(error)
            exchange.completion(CommandResult(success: false, value: ["error": code]))
        }
    }

    private static func errorCode(_ error: Error?) -> String {
        switch (error as? URLError)?.code {
        case .timedOut: return "timeout"
        case .cannotFindHost, .dnsLookupFailed: return "host_not_found"
        case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet: return "connection_failed"
        case .appTransportSecurityRequiresSecureConnection: return "transport_security_blocked"
        case .secureConnectionFailed, .serverCertificateUntrusted: return "tls_failed"
        default: return "request_failed"
        }
    }
}

/// Bounded Bonjour browse over the service types declared in Info.plist; never a port scan.
final class MuseLANDiscovery {
    private struct Found {
        let name: String
        let type: String
        let endpoint: NWEndpoint
        let txt: [String: String]
    }

    private let queue = DispatchQueue(label: "MuseGadgetLegacy.lanDiscovery")
    private var browsers: [NWBrowser] = []
    private var found: [String: Found] = [:]
    private var resolved: [String: (host: String, port: Int)] = [:]
    private var connections: [NWConnection] = []
    private var completion: (([[String: Any]]) -> Void)?

    static var declaredServiceTypes: [String] {
        (Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String]) ?? []
    }

    /// Returns false when a browse is already running.
    func discover(types: [String], completion: @escaping ([[String: Any]]) -> Void) -> Bool {
        queue.sync {
            guard self.completion == nil else { return false }
            self.completion = completion
            found.removeAll()
            resolved.removeAll()
            for type in types { startBrowser(type: type) }
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.stopBrowsingAndResolve() }
            return true
        }
    }

    private func startBrowser(type: String) {
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: type, domain: nil),
            using: NWParameters()
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.collect(results, type: type)
        }
        browser.start(queue: queue)
        browsers.append(browser)
    }

    private func collect(_ results: Set<NWBrowser.Result>, type: String) {
        for result in results.prefix(40) {
            guard case .service(let name, _, _, _) = result.endpoint, found.count < 40 else { continue }
            var txt: [String: String] = [:]
            if case .bonjour(let record) = result.metadata {
                for (key, value) in record.dictionary.prefix(24) {
                    txt[String(key.prefix(64))] = String(value.prefix(256))
                }
            }
            found["\(type)/\(name)"] = Found(name: name, type: type, endpoint: result.endpoint, txt: txt)
        }
    }

    private func stopBrowsingAndResolve() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        guard !found.isEmpty else {
            finish()
            return
        }
        for (key, service) in found { resolve(key: key, service: service) }
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.finish() }
    }

    /// Bonjour hands out names, and `lan.request` needs an address, so ask the system to connect.
    private func resolve(key: String, service: Found) {
        let parameters: NWParameters = service.type.hasSuffix("_udp") ? .udp : .tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: service.endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard case .ready = state, let self, let connection,
                  case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint else { return }
            let address = String(describing: host).split(separator: "%").first.map(String.init) ?? ""
            self.resolved[key] = (address, Int(port.rawValue))
            connection.cancel()
        }
        connection.start(queue: queue)
        connections.append(connection)
    }

    private func finish() {
        guard let completion else { return }
        self.completion = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
        let devices = found.map { key, service -> [String: Any] in
            var device: [String: Any] = ["name": service.name, "service_type": service.type, "txt": service.txt]
            if let address = resolved[key] {
                device["host"] = address.host
                device["port"] = address.port
            }
            return device
        }
        DispatchQueue.main.async { completion(devices) }
    }
}

/// `lan.discover` and `lan.request`, gated on the local network permission and on-screen approval.
final class MuseLANServices {
    private let permissions: PermissionCenter
    private let grants: MuseGrantStore
    private let approvals: MuseApprovalCenter
    private let client: MuseLANClient
    private let discovery = MuseLANDiscovery()

    init(permissions: PermissionCenter, grants: MuseGrantStore, approvals: MuseApprovalCenter) {
        self.permissions = permissions
        self.grants = grants
        self.approvals = approvals
        client = MuseLANClient(grants: grants)
    }

    func discover(arguments: [String: Any], completion: @escaping (CommandResult) -> Void) {
        DispatchQueue.main.async {
            guard UIApplication.shared.applicationState == .active else {
                completion(CommandResult(success: false, value: ["error": "foreground_required"]))
                return
            }
            guard self.permissions.status(for: .localNetwork) != .denied else {
                completion(CommandResult(success: false, value: ["error": "permission_required"]))
                return
            }
            let declared = MuseLANDiscovery.declaredServiceTypes
            var types = declared
            if let requested = arguments["service_type"] as? String {
                guard declared.contains(requested) else {
                    completion(CommandResult(success: false, value: [
                        "error": "service_type_not_declared"
                    ]))
                    return
                }
                types = [requested]
            }
            let started = self.discovery.discover(types: types) { devices in
                completion(CommandResult(success: true, value: ["devices": devices, "count": devices.count]))
            }
            if !started {
                completion(CommandResult(success: false, value: ["error": "busy"]))
            }
        }
    }

    func request(arguments: [String: Any], completion: @escaping (CommandResult) -> Void) {
        let request: MuseLANRequest
        switch MuseLANPolicy.request(from: arguments) {
        case .success(let parsed): request = parsed
        case .failure(let error):
            completion(CommandResult(success: false, value: ["error": error.code]))
            return
        }
        if grants.lanGrant(host: request.host, port: request.port) != nil {
            client.perform(request, completion: completion)
            return
        }
        DispatchQueue.main.async {
            let target = "\(request.host):\(request.port)"
            let action = "\(request.method) \(MuseDisplayText.sanitized(request.url.path, maxLength: 80))"
            self.approvals.ask(
                title: "Разрешить доступ к устройству?",
                message: "Muse просит обратиться к \(target) в вашей сети: \(action). Если разрешить, дальше доступ к этому устройству будет без вопроса. Отозвать можно в настройках."
            ) { decision in
                guard case .granted = decision else {
                    completion(CommandResult(success: false, value: ["error": decision.errorCode]))
                    return
                }
                self.grants.allowLANDevice(host: request.host, port: request.port)
                self.client.perform(request, completion: completion)
            }
        }
    }
}
