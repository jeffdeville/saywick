import CryptoKit
import Foundation
import OSLog

/// No localized descriptions, userInfo, URLs, transcript text or contact names.
struct DiagnosticEvent: Codable, Sendable {
    let date: Date
    let operation: String
    let domain: String
    let code: Int
    let version: String
    let build: String

    init(operation: StaticString, error: Error, now: Date = Date()) {
        let failure = error as NSError
        date = now
        self.operation = String(describing: operation)
        let known = [NSCocoaErrorDomain, NSURLErrorDomain, NSPOSIXErrorDomain, "AVFoundationErrorDomain", "NSOSStatusErrorDomain"]
        domain = known.contains(failure.domain) ? failure.domain
            : "domain-" + SHA256.hash(data: Data(failure.domain.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        code = failure.code
        version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }
}

/// Called only on DiagnosticLog's serial queue; injectable storage for failure tests.
struct DiagnosticStore {
    let root: URL
    let process: String
    static let limit = 100
    static let payloadLimit = 5
    static let payloadByteLimit = 2_000_000

    init(root: URL, process: String) throws {
        guard !process.isEmpty, process.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        self.root = root; self.process = process
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var directory = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }
    private var eventsURL: URL { root.appendingPathComponent(process + ".events.json") }
    func readEvents() throws -> [DiagnosticEvent] {
        guard FileManager.default.fileExists(atPath: eventsURL.path) else { return [] }
        return try JSONDecoder().decode([DiagnosticEvent].self, from: Data(contentsOf: eventsURL))
    }
    func append(_ event: DiagnosticEvent) throws {
        // A corrupt diagnostics log must never prevent recording a new failure.
        var events = (try? readEvents()) ?? []
        // Polling the same unavailable container must not flood disk or hide other failures.
        if let last = events.last, last.operation == event.operation, last.domain == event.domain,
           last.code == event.code, event.date.timeIntervalSince(last.date) < 60 { return }
        events.append(event)
        try JSONEncoder().encode(Array(events.suffix(Self.limit))).write(to: eventsURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func savePayload(_ data: Data) throws {
        guard data.count <= Self.payloadByteLimit,
              (try JSONSerialization.jsonObject(with: data)) is [String: Any] else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        let digest = SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
        let files = try payloads()
        let url = root.appendingPathComponent("metric-" + digest + ".json")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        // Bounded by count and size, without querying file timestamp APIs.
        for old in files.prefix(max(0, files.count - Self.payloadLimit + 1)) { try FileManager.default.removeItem(at: old) }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func payloads() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("metric-") && $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

enum DiagnosticLog {
    private static let logger = Logger(subsystem: "com.saywick", category: "Failures")
    private static let queue = DispatchQueue(label: "com.saywick.diagnostics", qos: .utility)
    private static func store() throws -> DiagnosticStore {
        let group = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
        let shared = group.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
        let base = try shared ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try DiagnosticStore(root: base.appendingPathComponent("Diagnostics"), process: Bundle.main.bundleIdentifier ?? "saywick")
    }
    static func error(_ operation: StaticString, _ error: Error) {
        let event = DiagnosticEvent(operation: operation, error: error)
        logger.error("\(event.operation, privacy: .public) domain=\(event.domain, privacy: .public) code=\(event.code) build=\(event.build, privacy: .public)")
        queue.async {
            do { try store().append(event) }
            catch { logger.error("Could not persist diagnostic event") }
        }
    }
    static func metricPayload(_ data: Data) {
        queue.async {
            do { try store().savePayload(data) }
            catch { logger.error("Could not persist MetricKit diagnostic payload") }
        }
    }
    static func export() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let store = try store()
                    let files = try FileManager.default.contentsOfDirectory(at: store.root, includingPropertiesForKeys: nil)
                        .filter { $0.lastPathComponent.hasSuffix(".events.json") || $0.lastPathComponent.hasPrefix("metric-") }
                    var reports: [String: Any] = [:]
                    for file in files.prefix(16) {
                        let data = try Data(contentsOf: file)
                        guard data.count <= DiagnosticStore.payloadByteLimit else { continue }
                        reports[file.lastPathComponent] = try JSONSerialization.jsonObject(with: data)
                    }
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SaywickDiagnostics")
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let url = directory.appendingPathComponent("Saywick-diagnostics.json")
                    try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys]).write(to: url,
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    continuation.resume(returning: url)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
