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
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func write(snapshot: SharedSessionSnapshot) throws {
        try encoder.encode(snapshot).write(to: snapshotURL, options: .atomic)
    }

    func readSnapshot() throws -> SharedSessionSnapshot? {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return nil }
        return try decoder.decode(
            SharedSessionSnapshot.self,
            from: Data(contentsOf: snapshotURL)
        )
    }

    /// Immediately removes a transcript after the keyboard inserts it. The
    /// session check prevents an older keyboard refresh from clearing new work.
    func clearSnapshot(ifSessionID sessionID: UUID) throws {
        guard var snapshot = try readSnapshot(), snapshot.sessionID == sessionID else { return }
        snapshot.revision += 1
        snapshot.phase = .idle
        snapshot.finalizedText = ""
        snapshot.partialText = ""
        snapshot.processedText = ""
        snapshot.message = "Ready"
        snapshot.shouldAutoInsert = false
        snapshot.updatedAt = Date()
        try write(snapshot: snapshot)
    }

    func write(command: VoiceCommand) throws {
        try encoder.encode(command).write(to: commandURL, options: .atomic)
    }

    func readCommand() throws -> VoiceCommand? {
        guard FileManager.default.fileExists(atPath: commandURL.path) else { return nil }
        return try decoder.decode(VoiceCommand.self, from: Data(contentsOf: commandURL))
    }

    private var snapshotURL: URL {
        rootURL.appendingPathComponent("voice-session.json", isDirectory: false)
    }

    private var commandURL: URL {
        rootURL.appendingPathComponent("voice-command.json", isDirectory: false)
    }
}
