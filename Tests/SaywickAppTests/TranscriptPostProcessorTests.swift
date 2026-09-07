import XCTest
import FoundationModels
@testable import LocalVoiceKeyboard

@MainActor
final class TranscriptPostProcessorTests: XCTestCase {
    func testThinkingPauseWithOnDeviceModel() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires Apple Intelligence on a physical device")
        #else
        guard case .available = SystemLanguageModel.default.availability else {
            throw XCTSkip("Apple Intelligence is unavailable")
        }
        let examples = [
            ("I would like to. Move the meeting to Friday.", "I would like to move the meeting to Friday."),
            ("Could you check. Whether Breccan has the API details?", "Could you check whether Breccan has the API details?"),
            ("Please call Breccan. The API is ready.", "Please call Breccan. The API is ready.")
        ]
        for (original, expected) in examples {
            let result = try await TranscriptPostProcessor.process(original, using: .foundationModels,
                customInstructions: "", preferredWords: ["Breccan", "API"])
            XCTAssertEqual(result, expected)
        }
        #endif
    }
    func testLongTranscriptWithOnDeviceModel() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires Apple Intelligence on a physical device")
        #else
        guard case .available = SystemLanguageModel.default.availability else {
            throw XCTSkip("Apple Intelligence is unavailable")
        }
        let original = (0..<90).map { "Record \($0) is ready." }.joined(separator: " ")
        let result = try await TranscriptPostProcessor.process(original, using: .foundationModels,
            customInstructions: "")
        XCTAssertEqual(result, original)
        #endif
    }

}
