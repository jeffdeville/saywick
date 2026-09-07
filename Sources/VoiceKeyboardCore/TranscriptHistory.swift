import Foundation

public struct TranscriptRun: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var createdAt = Date()
    public var engine: SpeechEngineID
    public var model: String
    public var rawText: String
    public var finalText: String
    public var cleanup: PostProcessorID
    public var cleanupInstructions: String
    public var vocabulary: String
    public var elapsedSeconds: Double
    public var error: String?

    public init(engine: SpeechEngineID, rawText: String, finalText: String, cleanup: PostProcessorID,
                cleanupInstructions: String = "", vocabulary: String = "", elapsedSeconds: Double = 0,
                error: String? = nil) {
        self.engine = engine
        self.model = engine.modelLabel
        self.rawText = rawText
        self.finalText = finalText
        self.cleanup = cleanup
        self.cleanupInstructions = cleanupInstructions
        self.vocabulary = vocabulary
        self.elapsedSeconds = elapsedSeconds
        self.error = error
    }
}

public struct TranscriptHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var title: String
    public var source: String
    public var hasAudio: Bool
    public var pinned: Bool
    public var status: String
    public var runs: [TranscriptRun]
    public init(id: UUID = UUID(), createdAt: Date = Date(), title: String = "Dictation",
                source: String = "Microphone", hasAudio: Bool = false, pinned: Bool = false,
                status: String = "Recording", runs: [TranscriptRun] = []) {
        self.id = id; self.createdAt = createdAt; self.title = title; self.source = source
        self.hasAudio = hasAudio; self.pinned = pinned; self.status = status; self.runs = runs
    }
    public var markdown: String {
        var text = "# \(title)\n\n\(createdAt.formatted()) · \(source)\n"
        for run in runs {
            text += "\n## \(run.model)\n\n### Original\n\n\(run.rawText)\n\n### Final\n\n\(run.finalText)\n"
            if let error = run.error { text += "\nError: \(error)\n" }
        }
        return text
    }
}

/// One atomic manifest per recording. Paths are derived solely from UUIDs;
/// imported filenames and decoded metadata can never select a filesystem path.
public struct TranscriptHistoryStore: Sendable {
    public let root: URL
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    public func audioURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".wav") }
    public func manifestURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".json") }
    public func save(_ entry: TranscriptHistoryEntry) throws {
        try JSONEncoder().encode(entry).write(to: manifestURL(entry.id), options: .atomic)
    }
    public func load() throws -> [TranscriptHistoryEntry] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .compactMap { url in
                guard var entry = try? JSONDecoder().decode(TranscriptHistoryEntry.self, from: Data(contentsOf: url)),
                      url.lastPathComponent == entry.id.uuidString + ".json" else { return nil }
                entry.hasAudio = FileManager.default.fileExists(atPath: audioURL(entry.id).path)
                return entry
            }.sorted { $0.createdAt > $1.createdAt }
    }
    public func delete(_ entry: TranscriptHistoryEntry) throws {
        try deleteAudio(entry.id)
        try FileManager.default.removeItem(at: manifestURL(entry.id))
    }
    public func deleteAudio(_ id: UUID) throws {
        let url = audioURL(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    public func prune(textDays: Int, audioDays: Int, now: Date = Date(), excluding: UUID? = nil) throws {
        for var entry in try load() where !entry.pinned && entry.id != excluding {
            let age = now.timeIntervalSince(entry.createdAt) / 86400
            if textDays > 0 && age >= Double(textDays) { try delete(entry) }
            else if audioDays > 0 && age >= Double(audioDays) && entry.hasAudio {
                try deleteAudio(entry.id); entry.hasAudio = false; try save(entry)
            }
        }
    }
}

extension SpeechEngineID {
    public var modelLabel: String {
        switch self {
        case .maiTranscribe2: "MAI-Transcribe-2 · clean · API 2025-10-15"
        case .maiVoiceLive: "mai-transcribe (version unconfirmed) · Voice Live 2026-04-10"
        case .moonshineMediumStreaming: "Moonshine Medium Streaming · SDK 0.1.5"
        case .appleSpeechAnalyzer: "Apple SpeechAnalyzer · system model"
        case .parakeetStreaming: "Parakeet Unified English 0.6B Q8_0 · transcribe.cpp 0.2.0 · CPU + Accelerate"
        }
    }
}
