import XCTest
@testable import VoiceKeyboardCore

final class TranscriptHistoryTests: XCTestCase {
    func testRoundTripAndIndependentRuns() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try TranscriptHistoryStore(root: folder)
        let first = TranscriptRun(engine: .maiTranscribe2, rawText: "Brecken", finalText: "Breccan", cleanup: .none)
        var entry = TranscriptHistoryEntry(runs: [first])
        try store.save(entry)
        entry.runs.append(TranscriptRun(engine: .appleSpeechAnalyzer, rawText: "Breccan", finalText: "Breccan", cleanup: .none))
        try store.save(entry)
        XCTAssertEqual(try store.load().first?.runs.first, first)
        XCTAssertEqual(try store.load().first?.runs.count, 2)
        XCTAssertTrue(entry.markdown.contains("### Original\n\nBrecken"))
    }
    func testRetentionPinsAndActiveEntry() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try TranscriptHistoryStore(root: folder)
        let old = Date().addingTimeInterval(-40 * 86400)
        let expired = TranscriptHistoryEntry(createdAt: old)
        let pinned = TranscriptHistoryEntry(createdAt: old, pinned: true)
        let active = TranscriptHistoryEntry(createdAt: old)
        for entry in [expired, pinned, active] { try store.save(entry); try Data([0]).write(to: store.audioURL(entry.id)) }
        try store.prune(textDays: 30, audioDays: 7, excluding: active.id)
        XCTAssertEqual(Set(try store.load().map(\.id)), Set([pinned.id, active.id]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audioURL(expired.id).path))
    }
    func testAudioExpiryPreservesTextAndCorruptManifestDoesNotHideOthers() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try TranscriptHistoryStore(root: folder)
        let entry = TranscriptHistoryEntry(createdAt: Date().addingTimeInterval(-10 * 86400))
        try store.save(entry); try Data([1]).write(to: store.audioURL(entry.id))
        try Data("invalid".utf8).write(to: store.manifestURL(UUID()))
        try store.prune(textDays: 30, audioDays: 7)
        XCTAssertEqual(try store.load().count, 1)
        XCTAssertFalse(try XCTUnwrap(store.load().first).hasAudio)
    }
    func testManifestCannotImpersonateAnotherRecording() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try TranscriptHistoryStore(root: folder)
        try JSONEncoder().encode(TranscriptHistoryEntry()).write(to: store.manifestURL(UUID()))
        XCTAssertTrue(try store.load().isEmpty)
    }
}
