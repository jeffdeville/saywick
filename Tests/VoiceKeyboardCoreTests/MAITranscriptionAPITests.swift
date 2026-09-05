import XCTest
@testable import VoiceKeyboardCore

final class MAITranscriptionAPITests: XCTestCase {
    func testEndpointAcceptsResourceAndRejectsCredentialLeakTargets() throws {
        XCTAssertEqual(try MAITranscriptionAPI.endpoint(" https://example.cognitiveservices.azure.com/ ").absoluteString,
                       "https://example.cognitiveservices.azure.com/speechtotext/transcriptions:transcribe?api-version=2025-10-15")
        for invalid in ["http://example.cognitiveservices.azure.com", "https://example.com", "https://example.cognitiveservices.azure.com.evil.org", "https://user:password@example.cognitiveservices.azure.com", "https://example.cognitiveservices.azure.com/?key=secret"] {
            XCTAssertThrowsError(try MAITranscriptionAPI.endpoint(invalid))
        }
    }

    func testUsesCombinedTranscriptOnceAndPreservesIntentionalRepetition() throws {
        let data = Data(#"{"combinedPhrases":[{"text":"Very, very good.\nNext paragraph."}],"phrases":[{"text":"Very, very good."},{"text":"Next paragraph."}]}"#.utf8)
        XCTAssertEqual(try MAITranscriptionAPI.transcript(from: data), "Very, very good.\nNext paragraph.")
        XCTAssertEqual(try MAITranscriptionAPI.transcript(from: Data(#"{"combinedPhrases":[]}"#.utf8)), "")
        XCTAssertThrowsError(try MAITranscriptionAPI.transcript(from: Data(#"{"error":"bad request"}"#.utf8)))
    }

    func testMultipartSelectsOnlyMAICleanAndContainsAudioBytes() {
        let audio = Data([0, 1, 2, 255])
        let body = MAITranscriptionAPI.multipart(audio: audio, boundary: "test-boundary")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains(#""model":"MAI-Transcribe-2","modelOptions":{"transcribeStyle":"clean"}"#))
        XCTAssertTrue(text.contains("name=\"audio\"; filename=\"dictation.wav\""))
        XCTAssertNotNil(body.range(of: audio))
        XCTAssertTrue(text.hasSuffix("\r\n--test-boundary--\r\n"))
    }
}
