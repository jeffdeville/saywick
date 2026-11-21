import Foundation
import VoiceKeyboardCore

enum SharedContainerError: LocalizedError {
    case missingAppGroupIdentifier
    case appGroupUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingAppGroupIdentifier:
            "AppGroupIdentifier is missing from Info.plist."
        case .appGroupUnavailable(let identifier):
            "The shared container \(identifier) is unavailable. Check signing and App Groups."
        }
    }
}

struct SharedContainerStore {
    private let rootURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(bundle: Bundle = .main) throws {
        guard let identifier = bundle.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
              !identifier.isEmpty else {
            throw SharedContainerError.missingAppGroupIdentifier
        }
        guard let rootURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
        ) else {
            throw SharedContainerError.appGroupUnavailable(identifier)
        }

        self.rootURL = rootURL
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.dateEncodingStrategy = .millisecondsSince1970
        self.decoder.dateDecodingStrategy = Self.dateDecoding
    }

    private static var dateDecoding: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let milliseconds = try? container.decode(Double.self) { return Date(timeIntervalSince1970: milliseconds / 1000) }
            let string = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid session date")
            }
            return date
        }
    }

    func write(snapshot: SharedSessionSnapshot) throws {
        try encoder.encode(snapshot).write(to: snapshotURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func readSnapshot() throws -> SharedSessionSnapshot? {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return nil }
        return try decoder.decode(
            SharedSessionSnapshot.self,
            from: Data(contentsOf: snapshotURL)
        )
    }

    init(rootURL: URL) throws {
        self.rootURL = rootURL
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        encoder = JSONEncoder(); decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970; decoder.dateDecodingStrategy = Self.dateDecoding
    }

    func write(receipt: ResultReceipt) throws {
        let folder = rootURL.appendingPathComponent("result-receipts")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(receipt).write(to: folder.appendingPathComponent(receipt.resultID.uuidString + ".json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func readReceipt(_ id: UUID) throws -> ResultReceipt? {
        let url = rootURL.appendingPathComponent("result-receipts/" + id.uuidString + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(ResultReceipt.self, from: Data(contentsOf: url))
    }

    func write(correctionContext: VocabularyCorrectionContext) throws {
        try encoder.encode(correctionContext).write(to: rootURL.appendingPathComponent("correction-context.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func removeCorrectionContext() throws {
        let url = rootURL.appendingPathComponent("correction-context.json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func readCorrectionContext() throws -> VocabularyCorrectionContext? {
        let url = rootURL.appendingPathComponent("correction-context.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(VocabularyCorrectionContext.self, from: Data(contentsOf: url))
    }

    func cleanupEnabled() throws -> Bool {
        let url = rootURL.appendingPathComponent("cleanup-enabled.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        return try decoder.decode(Bool.self, from: Data(contentsOf: url))
    }

    func setCleanupEnabled(_ enabled: Bool) throws {
        try encoder.encode(enabled).write(to: rootURL.appendingPathComponent("cleanup-enabled.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func write(command: VoiceCommand) throws {
        try encoder.encode(command).write(to: commandURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func readCommand() throws -> VoiceCommand? {
        guard FileManager.default.fileExists(atPath: commandURL.path) else { return nil }
        return try decoder.decode(VoiceCommand.self, from: Data(contentsOf: commandURL))
    }

    func write(presence: KeyboardPresence) throws {
        // Preserve subsecond ordering against the recording start time.
        let presenceEncoder = JSONEncoder()
        presenceEncoder.dateEncodingStrategy = .millisecondsSince1970
        try presenceEncoder.encode(presence).write(to: presenceURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func readKeyboardPresence() throws -> KeyboardPresence? {
        guard FileManager.default.fileExists(atPath: presenceURL.path) else { return nil }
        let presenceDecoder = JSONDecoder()
        presenceDecoder.dateDecodingStrategy = .millisecondsSince1970
        return try presenceDecoder.decode(KeyboardPresence.self, from: Data(contentsOf: presenceURL))
    }

    private var presenceURL: URL {
        rootURL.appendingPathComponent("keyboard-presence.json", isDirectory: false)
    }

    private var snapshotURL: URL {
        rootURL.appendingPathComponent("voice-session.json", isDirectory: false)
    }

    private var commandURL: URL {
        rootURL.appendingPathComponent("voice-command.json", isDirectory: false)
    }
}
