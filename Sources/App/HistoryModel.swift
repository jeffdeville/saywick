@preconcurrency import AVFoundation
import Foundation
import Observation
import UIKit
import VoiceKeyboardCore

@MainActor @Observable
final class HistoryModel {
    var entries: [TranscriptHistoryEntry] = []
    var inbox: [URL] = []
    var message = ""
    var isWorking = false
    var keepAudio: Bool {
        didSet { UserDefaults.standard.set(keepAudio, forKey: "keepAudio") }
    }
    var textDays: Int { didSet { UserDefaults.standard.set(textDays, forKey: "historyTextDays") } }
    var audioDays: Int { didSet { UserDefaults.standard.set(audioDays, forKey: "historyAudioDays") } }
    var playingID: UUID?
    @ObservationIgnored var store: TranscriptHistoryStore?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored var activeID: UUID?

    init() {
        let defaults = UserDefaults.standard
        keepAudio = defaults.object(forKey: "keepAudio") == nil ? true : defaults.bool(forKey: "keepAudio")
        textDays = defaults.object(forKey: "historyTextDays") == nil ? 30 : defaults.integer(forKey: "historyTextDays")
        audioDays = defaults.object(forKey: "historyAudioDays") == nil ? 7 : defaults.integer(forKey: "historyAudioDays")
        do {
            var root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true).appendingPathComponent("SaywickHistory")
            store = try TranscriptHistoryStore(root: root)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try root.setResourceValues(values)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
            reload()
        } catch { message = "History unavailable: \(error.localizedDescription)" }
    }

    func reload() {
        do {
            try store?.prune(textDays: textDays, audioDays: audioDays, excluding: activeID)
            entries = try store?.load() ?? []
            inbox = (try? SharedAudioInbox.pending()) ?? []
        } catch { message = "History: \(error.localizedDescription)" }
    }

    func begin(id: UUID) throws -> URL? {
        guard let store else { throw SpeechEngineError.unavailable("History storage is unavailable. Restart Saywick.") }
        stopPlayback()
        activeID = id
        try store.save(TranscriptHistoryEntry(id: id, hasAudio: keepAudio))
        reload()
        return keepAudio ? store.audioURL(id) : nil
    }

    func checkpoint(id: UUID, run: TranscriptRun, status: String) {
        do {
            guard let store, var entry = try store.load().first(where: { $0.id == id }) else { return }
            entry.runs = [run]; entry.status = status
            entry.title = String((run.finalText.isEmpty ? run.rawText : run.finalText).prefix(70))
            if entry.title.isEmpty { entry.title = "Dictation" }
            entry.hasAudio = FileManager.default.fileExists(atPath: store.audioURL(id).path)
            try store.save(entry)
            entries = try store.load()
        } catch { message = "Could not save transcript: \(error.localizedDescription)" }
    }

    func audioURL(_ entry: TranscriptHistoryEntry) -> URL? {
        guard entry.hasAudio, let url = store?.audioURL(entry.id), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
    func stopPlayback() { player?.stop(); player = nil; playingID = nil }
    func play(_ entry: TranscriptHistoryEntry) {
        if playingID == entry.id { stopPlayback(); return }
        stopPlayback()
        guard let url = audioURL(entry) else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(contentsOf: url)
            player?.play(); playingID = entry.id
        } catch { message = error.localizedDescription }
    }
    func pin(_ entry: TranscriptHistoryEntry) {
        var updated = entry; updated.pinned.toggle()
        do { try store?.save(updated); reload() } catch { message = error.localizedDescription }
    }
    func delete(_ entry: TranscriptHistoryEntry, audioOnly: Bool = false) {
        stopPlayback()
        do {
            if audioOnly { try store?.deleteAudio(entry.id) }
            else { try store?.delete(entry) }
            reload()
        } catch { message = error.localizedDescription }
    }
    func cancelWork() { work?.cancel(); message = "Cancelling…" }
    func deleteSharedAudio(_ url: URL) {
        guard !isWorking, activeID == nil, inbox.contains(url) else { return }
        do { try FileManager.default.removeItem(at: url); reload(); message = "Shared audio deleted permanently." }
        catch { message = error.localizedDescription }
    }

    func importAudio(_ source: URL, fromInbox: Bool = false) {
        guard !isWorking, activeID == nil, let store else { return }
        isWorking = true; message = "Importing audio locally…"
        work = Task { @MainActor in
            defer { isWorking = false; work = nil }
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            var entry = TranscriptHistoryEntry(title: source.deletingPathExtension().lastPathComponent, source: "Imported audio", hasAudio: true, status: "Imported — choose a model")
            do {
                try await AudioFileTranscriber.normalizedCopy(from: source, to: store.audioURL(entry.id))
                try Task.checkCancellation()
                entry.hasAudio = true
                try store.save(entry); reload()
                if fromInbox, inbox.contains(source) {
                    try? FileManager.default.removeItem(at: source)
                    reload()
                }
                message = "Imported locally. Open the recording and choose a model. Cloud runs require confirmation."
            } catch {
                try? store.deleteAudio(entry.id)
                message = error is CancellationError ? "Import cancelled" : error.localizedDescription
            }
        }
    }

    func compare(_ entry: TranscriptHistoryEntry, engine: SpeechEngineID, cleanup: PostProcessorID,
                 instructions: String, vocabulary: String, reprocess: TranscriptRun? = nil) {
        guard !isWorking, activeID == nil else { return }
        let url = audioURL(entry)
        guard reprocess != nil || url != nil else { message = "No retained audio for this entry."; return }
        stopPlayback(); isWorking = true; message = "Preparing comparison…"
        work = Task { @MainActor in
            defer { isWorking = false; work = nil }
            let started = Date()
            var raw = reprocess?.rawText ?? ""
            do {
                let words = try CustomVocabulary(vocabulary)
                if reprocess == nil {
                    raw = try await AudioFileTranscriber.transcribe(url!, engine: engine) { self.message = $0 }
                }
                try Task.checkCancellation()
                message = "Applying cleanup on device…"
                let cleaned = try await TranscriptPostProcessor.process(raw, using: cleanup, customInstructions: instructions,
                                                                        preferredWords: words.preferredWords)
                try Task.checkCancellation()
                let run = TranscriptRun(engine: engine, rawText: raw, finalText: words.apply(to: cleaned), cleanup: cleanup,
                                        cleanupInstructions: instructions, vocabulary: vocabulary,
                                        elapsedSeconds: Date().timeIntervalSince(started))
                try append(run, to: entry.id)
                message = "Saved a new comparison; earlier runs are unchanged."
            } catch {
                let run = TranscriptRun(engine: engine, rawText: raw, finalText: "", cleanup: cleanup,
                                        cleanupInstructions: instructions, vocabulary: vocabulary,
                                        elapsedSeconds: Date().timeIntervalSince(started),
                                        error: error is CancellationError ? "Cancelled" : error.localizedDescription)
                do { try append(run, to: entry.id) }
                catch { message = "Could not save failed run: \(error.localizedDescription)"; return }
                message = run.error ?? "Failed"
            }
        }
    }

    private func append(_ run: TranscriptRun, to id: UUID) throws {
        guard let store, var entry = try store.load().first(where: { $0.id == id }) else { return }
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
