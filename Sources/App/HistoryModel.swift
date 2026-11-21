@preconcurrency import AVFoundation
import Foundation
import Observation
import UIKit
import VoiceKeyboardCore

@MainActor @Observable
final class HistoryModel {
    var entries: [TranscriptHistoryEntry] = []
    var message = ""
    var isWorking = false
    var keepAudio: Bool {
        didSet { defaults.set(keepAudio, forKey: "keepAudio") }
    }
    var textDays: Int { didSet { defaults.set(textDays, forKey: "historyTextDays") } }
    var audioDays: Int { didSet { defaults.set(audioDays, forKey: "historyAudioDays") } }
    private var workingID: UUID?
    var playingID: UUID?
    @ObservationIgnored var store: TranscriptHistoryStore?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private(set) var work: Task<Void, Never>?
    @ObservationIgnored var activeID: UUID?

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, root: URL? = nil) {
        self.defaults = defaults
        keepAudio = defaults.object(forKey: "keepAudio") == nil ? true : defaults.bool(forKey: "keepAudio")
        textDays = defaults.object(forKey: "historyTextDays") == nil ? 30 : defaults.integer(forKey: "historyTextDays")
        audioDays = defaults.object(forKey: "historyAudioDays") == nil ? 7 : defaults.integer(forKey: "historyAudioDays")
        do {
            var root = try root ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true).appendingPathComponent("SaywickHistory")
            store = try TranscriptHistoryStore(root: root)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try root.setResourceValues(values)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
            reload()
        } catch { DiagnosticLog.error("history.operation", error); message = "History unavailable: \(error.localizedDescription)" }
    }

    func reload() {
        do {
            try store?.prune(textDays: textDays, audioDays: audioDays, excluding: activeID ?? workingID)
            entries = try store?.load() ?? []
        } catch { DiagnosticLog.error("history.operation", error); message = "History: \(error.localizedDescription)" }
    }

    func begin(id: UUID, meeting: Bool = false) throws -> URL? {
        guard let store else { throw SpeechEngineError.unavailable("History storage is unavailable. Restart Saywick.") }
        stopPlayback()
        activeID = id
        try store.save(TranscriptHistoryEntry(id: id, title: meeting ? "Meeting" : "Dictation",
            source: meeting ? "Meeting recording" : "Microphone", hasAudio: keepAudio || meeting))
        reload()
        return keepAudio || meeting ? store.audioURL(id) : nil
    }

    func completeMeeting(id: UUID, status: String = "Audio saved — transcribe with Parakeet") throws {
        guard let store, var entry = try store.load().first(where: { $0.id == id }) else {
            throw SpeechEngineError.unavailable("Meeting history entry is unavailable.")
        }
        entry.status = status
        entry.hasAudio = FileManager.default.fileExists(atPath: store.audioURL(id).path)
        try store.save(entry)
        reload()
    }

    func checkpoint(id: UUID, run: TranscriptRun, status: String) {
        do { try saveCheckpoint(id: id, run: run, status: status) }
        catch { DiagnosticLog.error("history.operation", error); message = "Could not save transcript: \(error.localizedDescription)" }
    }
    func saveCheckpoint(id: UUID, run: TranscriptRun, status: String) throws {
            guard let store, var entry = try store.load().first(where: { $0.id == id }) else {
                throw SpeechEngineError.unavailable("Recording history is unavailable. Check retained audio in History.")
            }
            entry.runs = [run]; entry.status = status
            entry.title = String((run.finalText.isEmpty ? run.rawText : run.finalText).prefix(70))
            if entry.title.isEmpty { entry.title = "Dictation" }
            entry.hasAudio = FileManager.default.fileExists(atPath: store.audioURL(id).path)
            try store.save(entry)
            entries = try store.load()
    }

    @ObservationIgnored private let recordingWriter = RecordingHistoryWriter()
    func beginRecording(id: UUID, meeting: Bool) async throws -> URL? {
        guard let store else { throw SpeechEngineError.unavailable("History storage is unavailable. Restart Saywick.") }
        stopPlayback(); activeID = id
        let retain = keepAudio || meeting
        entries = try await recordingWriter.begin(store: store, id: id, meeting: meeting, retain: retain)
        return retain ? store.audioURL(id) : nil
    }
    func recordCheckpoint(id: UUID, run: TranscriptRun, status: String) async throws {
        guard let store else { throw SpeechEngineError.unavailable("History storage is unavailable.") }
        entries = try await recordingWriter.checkpoint(store: store, id: id, run: run, status: status)
    }
    func saveMeeting(id: UUID, status: String) async throws {
        guard let store else { throw SpeechEngineError.unavailable("History storage is unavailable.") }
        entries = try await recordingWriter.meeting(store: store, id: id, status: status)
    }

    func audioURL(_ entry: TranscriptHistoryEntry) -> URL? {
        guard entry.hasAudio, let url = store?.audioURL(entry.id), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
    func stopPlayback() { player?.stop(); player = nil; playingID = nil }
    func play(_ entry: TranscriptHistoryEntry) {
        guard !MicrophoneCapture.shared.isRunning else {
            message = "End the microphone session before playing a recording."
            return
        }
        if playingID == entry.id { stopPlayback(); return }
        stopPlayback()
        guard let url = audioURL(entry) else { return }
        do {
            RecordingErrorSound.shared.stop()
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(contentsOf: url)
            player?.play(); playingID = entry.id
        } catch { DiagnosticLog.error("history.operation", error); message = error.localizedDescription }
    }
    func pin(_ entry: TranscriptHistoryEntry) {
        var updated = entry; updated.pinned.toggle()
        do { try store?.save(updated); reload() } catch { DiagnosticLog.error("history.operation", error); message = error.localizedDescription }
    }
    func delete(_ entry: TranscriptHistoryEntry, audioOnly: Bool = false) {
        guard !isWorking, activeID != entry.id else { message = "Finish the active recording or transcription before deleting it."; return }
        stopPlayback()
        do {
            if audioOnly { try store?.deleteAudio(entry.id) }
            else { try store?.delete(entry) }
            reload()
        } catch { DiagnosticLog.error("history.operation", error); message = error.localizedDescription }
    }
    func cancelWork() { work?.cancel(); message = "Cancelling…" }
    func compare(_ entry: TranscriptHistoryEntry, engine: SpeechEngineID, cleanup: PostProcessorID,
                 instructions: String, vocabulary: String, reprocess: TranscriptRun? = nil) {
        guard !isWorking, activeID == nil else { return }
        let url = audioURL(entry)
        guard reprocess != nil || url != nil else { message = "No retained audio for this entry."; return }
        stopPlayback(); isWorking = true; workingID = entry.id; message = "Preparing comparison…"
        work = Task { @MainActor in
            defer { isWorking = false; workingID = nil; work = nil }
            let started = Date()
            var raw = reprocess?.rawText ?? ""
            do {
                let words = try CustomVocabulary(vocabulary)
                if reprocess == nil {
                    raw = try await AudioFileTranscriber.transcribe(url!, engine: engine) { self.message = $0 }
                }
                try Task.checkCancellation()
                message = "Applying cleanup…"
                let cleaned = try await TranscriptPostProcessor.process(words.apply(to: raw), using: cleanup, customInstructions: instructions,
                                                                        preferredWords: words.preferredWords)
                try Task.checkCancellation()
                let run = TranscriptRun(engine: engine, rawText: raw, finalText: cleaned, cleanup: cleanup,
                                        cleanupInstructions: instructions, vocabulary: vocabulary,
                                        elapsedSeconds: Date().timeIntervalSince(started))
                try append(run, to: entry.id)
                message = "Saved a new comparison; earlier runs are unchanged."
            } catch {
                DiagnosticLog.error("history.transcribe", error)
                let run = TranscriptRun(engine: engine, rawText: raw, finalText: "", cleanup: cleanup,
                                        cleanupInstructions: instructions, vocabulary: vocabulary,
                                        elapsedSeconds: Date().timeIntervalSince(started),
                                        error: error is CancellationError ? "Cancelled" : error.localizedDescription)
                do { try append(run, to: entry.id) }
                catch { DiagnosticLog.error("history.operation", error); message = "Could not save failed run: \(error.localizedDescription)"; return }
                message = run.error ?? "Failed"
            }
        }
    }

    private func append(_ run: TranscriptRun, to id: UUID) throws {
        guard let store, var entry = try store.load().first(where: { $0.id == id }) else {
            throw SpeechEngineError.unavailable("The recording is no longer available; the new result could not be saved.")
        }
        entry.runs.append(run); entry.status = run.error == nil ? "Ready" : "Run failed — audio retained"
        try store.save(entry); reload()
    }

    func export(_ entry: TranscriptHistoryEntry, markdown: Bool) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SaywickExports")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(entry.id.uuidString + (markdown ? ".md" : ".txt"))
        let text = markdown ? entry.markdown : entry.runs.last(where: { $0.error == nil })?.finalText ?? ""
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// Serial recording persistence never blocks UI updates or microphone callbacks.
actor RecordingHistoryWriter {
    func begin(store: TranscriptHistoryStore, id: UUID, meeting: Bool, retain: Bool) throws -> [TranscriptHistoryEntry] {
        try store.save(TranscriptHistoryEntry(id: id, title: meeting ? "Meeting" : "Dictation",
            source: meeting ? "Meeting recording" : "Microphone", hasAudio: retain))
        return try store.load()
    }
    func checkpoint(store: TranscriptHistoryStore, id: UUID, run: TranscriptRun, status: String) throws -> [TranscriptHistoryEntry] {
        guard var entry = try store.load().first(where: { $0.id == id }) else {
            throw SpeechEngineError.unavailable("Recording history is unavailable. Check retained audio in History.")
        }
        entry.runs = [run]; entry.status = status
        entry.title = String((run.finalText.isEmpty ? run.rawText : run.finalText).prefix(70))
        if entry.title.isEmpty { entry.title = "Dictation" }
        try store.save(entry)
        return try store.load()
    }
    func meeting(store: TranscriptHistoryStore, id: UUID, status: String) throws -> [TranscriptHistoryEntry] {
        guard var entry = try store.load().first(where: { $0.id == id }) else {
            throw SpeechEngineError.unavailable("Meeting history is unavailable.")
        }
        entry.status = status; try store.save(entry)
        return try store.load()
    }
}
