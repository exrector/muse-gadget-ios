import Combine
import Foundation
import MetricKit
import UIKit

/// Opt-in crash diagnostics, asked once in both TestFlight and App Store builds. This service
/// deliberately accepts only short, controlled event names. It never receives chat text, tokens,
/// account details, gadget names, filenames, photos or audio.
final class MuseDiagnostics: NSObject, ObservableObject {
    enum Consent: Int {
        case unknown
        case enabled
        case disabled
    }

    struct Breadcrumb: Codable, Equatable {
        let at: Date
        let event: String
        let detail: String?
    }

    private struct ReportEnvelope: Codable {
        let schemaVersion: Int
        let reportID: UUID
        let sentAt: Date
        let appVersion: String
        let build: String
        let platform: String
        let osVersion: String
        let model: String
        let locale: String
        let testFlight: Bool
        let kind: String
        let reason: String?
        let diagnostic: JSONValue
        let breadcrumbs: [Breadcrumb]
    }

    private enum JSONValue: Codable {
        case object([String: JSONValue])
        case array([JSONValue])
        case string(String)
        case number(Double)
        case bool(Bool)
        case null

        init(any value: Any) {
            switch value {
            case let value as [String: Any]: self = .object(value.mapValues(JSONValue.init(any:)))
            case let value as [Any]: self = .array(value.map(JSONValue.init(any:)))
            case let value as String: self = .string(String(value.prefix(8_192)))
            case let value as NSNumber:
                self = CFGetTypeID(value) == CFBooleanGetTypeID() ? .bool(value.boolValue) : .number(value.doubleValue)
            default: self = .null
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .object(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .bool(let value): try container.encode(value)
            case .null: try container.encodeNil()
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
            else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
            else if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else if let value = try? container.decode(Double.self) { self = .number(value) }
            else { self = .string(try container.decode(String.self)) }
        }
    }

    @Published private(set) var consent: Consent
    @Published private(set) var pendingReportCount = 0
    @Published private(set) var lastUploadStatus: String?

    private static let consentKey = "palDiagnosticsConsent"
    private static let endpoint = URL(string: "https://pal-again-diagnostics.exrector.workers.dev/v1/reports")!
    private static let maxBreadcrumbs = 100
    private static let maxDiagnosticBytes = 192 * 1024
    private let queue = DispatchQueue(label: "com.exrector.palagain.diagnostics", qos: .utility)
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    private var breadcrumbs: [Breadcrumb] = []
    private var isUploading = false
    private var observers: [NSObjectProtocol] = []

    var sharingEnabled: Bool { consent == .enabled }
    var shouldAskForConsent: Bool { consent == .unknown }
    let isTestFlight: Bool

    override init() {
        isTestFlight = MuseAppVersion.isTestFlight
        consent = Consent(rawValue: UserDefaults.standard.integer(forKey: Self.consentKey)) ?? .unknown
        super.init()
        prepareStorage()
        loadBreadcrumbs()
        MXMetricManager.shared.add(self)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.record("app_foreground")
                self?.uploadPending()
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.record("app_background")
            }
        ]
        record("app_launch", detail: isTestFlight ? "testflight" : "direct")
        refreshPendingCount()
        uploadPending()
    }

    deinit {
        MXMetricManager.shared.remove(self)
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func setSharingEnabled(_ enabled: Bool) {
        consent = enabled ? .enabled : .disabled
        UserDefaults.standard.set(consent.rawValue, forKey: Self.consentKey)
        record("diagnostics_consent", detail: enabled ? "enabled" : "disabled")
        if enabled { uploadPending() }
    }

    func record(_ event: String, detail: String? = nil) {
        let safeEvent = Self.safe(event, limit: 64)
        guard !safeEvent.isEmpty else { return }
        let safeDetail = detail.map { Self.safe($0, limit: 160) }
        queue.async { [weak self] in
            guard let self else { return }
            breadcrumbs.append(Breadcrumb(at: Date(), event: safeEvent, detail: safeDetail))
            if breadcrumbs.count > Self.maxBreadcrumbs {
                breadcrumbs.removeFirst(breadcrumbs.count - Self.maxBreadcrumbs)
            }
            persistBreadcrumbs()
        }
    }

    func sendCurrentSnapshot() {
        queue.async { [weak self] in
            guard let self else { return }
            persistReport(kind: "manual", reason: "user_requested", diagnostic: .object(["snapshot": .bool(true)]))
            uploadPendingLocked()
        }
    }

    func uploadPending() {
        queue.async { [weak self] in self?.uploadPendingLocked() }
    }

    private func persistDiagnosticPayload(_ payload: MXDiagnosticPayload) {
        let raw = payload.jsonRepresentation()
        let diagnostic: JSONValue
        if raw.count <= Self.maxDiagnosticBytes,
           let object = try? JSONSerialization.jsonObject(with: raw) {
            diagnostic = JSONValue(any: object)
        } else {
            diagnostic = .object([
                "truncated": .bool(true),
                "originalBytes": .number(Double(raw.count))
            ])
        }
        if !(payload.crashDiagnostics ?? []).isEmpty {
            persistReport(kind: "metrickit_crash", reason: "MetricKit crash diagnostic", diagnostic: diagnostic)
        }
        if !(payload.hangDiagnostics ?? []).isEmpty {
            persistReport(kind: "metrickit_hang", reason: "MetricKit hang diagnostic", diagnostic: diagnostic)
        }
    }

    private func persistReport(kind: String, reason: String?, diagnostic: JSONValue) {
        let report = ReportEnvelope(
            schemaVersion: 1,
            reportID: UUID(),
            sentAt: Date(),
            appVersion: MuseAppVersion.current,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            platform: UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios",
            osVersion: UIDevice.current.systemVersion,
            model: MuseHapticRoute.machineIdentifier,
            locale: Locale.current.identifier,
            testFlight: isTestFlight,
            kind: kind,
            reason: reason,
            diagnostic: diagnostic,
            breadcrumbs: Array(breadcrumbs.suffix(Self.maxBreadcrumbs))
        )
        guard let data = try? encoder.encode(report) else { return }
        let url = pendingDirectory.appendingPathComponent("\(report.reportID.uuidString.lowercased()).json")
        try? data.write(to: url, options: .atomic)
        refreshPendingCountLocked()
    }

    private func uploadPendingLocked() {
        guard consent == .enabled, !isUploading else { return }
        guard let file = pendingFiles.first else {
            publishStatus(nil)
            return
        }
        guard let data = try? Data(contentsOf: file) else {
            try? FileManager.default.removeItem(at: file)
            refreshPendingCountLocked()
            uploadPendingLocked()
            return
        }
        isUploading = true
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        URLSession(configuration: configuration).dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            self.queue.async {
                self.isUploading = false
                let status = (response as? HTTPURLResponse)?.statusCode
                if error == nil, let status, (200..<300).contains(status) {
                    try? FileManager.default.removeItem(at: file)
                    self.publishStatus("sent")
                    self.refreshPendingCountLocked()
                    self.uploadPendingLocked()
                } else {
                    self.publishStatus(status.map { "HTTP \($0)" } ?? "offline")
                }
            }
        }.resume()
    }

    private var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PalAgainDiagnostics", isDirectory: true)
    }

    private var pendingDirectory: URL { supportDirectory.appendingPathComponent("Pending", isDirectory: true) }
    private var breadcrumbsURL: URL { supportDirectory.appendingPathComponent("breadcrumbs.json") }
    private var pendingFiles: [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func prepareStorage() {
        try? FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = supportDirectory
        try? directory.setResourceValues(values)
    }

    private func loadBreadcrumbs() {
        guard let data = try? Data(contentsOf: breadcrumbsURL),
              let decoded = try? decoder.decode([Breadcrumb].self, from: data) else { return }
        breadcrumbs = Array(decoded.suffix(Self.maxBreadcrumbs))
    }

    private func persistBreadcrumbs() {
        guard let data = try? encoder.encode(breadcrumbs) else { return }
        try? data.write(to: breadcrumbsURL, options: .atomic)
    }

    private func refreshPendingCount() { queue.async { [weak self] in self?.refreshPendingCountLocked() } }
    private func refreshPendingCountLocked() {
        let count = pendingFiles.count
        DispatchQueue.main.async { [weak self] in self?.pendingReportCount = count }
    }

    private func publishStatus(_ status: String?) {
        DispatchQueue.main.async { [weak self] in self?.lastUploadStatus = status }
    }

    /// The name of an enum case without its associated values, so a state such as
    /// `advertising("MuseGadgetA1B2C3")` or `failed("…")` is logged as `advertising` or `failed`.
    static func label(_ value: Any) -> String {
        let text = String(describing: value)
        return String(text.prefix { $0 != "(" })
    }

    private static func safe(_ value: String, limit: Int) -> String {
        String(value.prefix(limit)).replacingOccurrences(
            of: "[\\u{0000}-\\u{001F}\\u{007F}]",
            with: "",
            options: .regularExpression
        )
    }
}

extension MuseDiagnostics: MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        queue.async { [weak self] in
            guard let self else { return }
            payloads.forEach(persistDiagnosticPayload)
            uploadPendingLocked()
        }
    }
}
