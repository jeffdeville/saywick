import XCTest
@testable import VoiceKeyboardCore

final class CustomVocabularyTests: XCTestCase {
    func testExplicitCorrectionValidatesFieldsAndTranscript() throws {
        let updated = try CustomVocabulary.addingCorrection(to: "Saywick", heard: "new york", preferred: "New York", transcript: "Visit new york tomorrow.")
        XCTAssertEqual(try CustomVocabulary(updated).apply(to: "new york and Saywick"), "New York and Saywick")
        for heard in ["", "new\nyork", "new = york", "yorkshire"] {
            XCTAssertThrowsError(try CustomVocabulary.addingCorrection(to: "", heard: heard, preferred: "New York", transcript: "new york"))
        }
        XCTAssertThrowsError(try CustomVocabulary.addingCorrection(to: "", heard: "new", preferred: "new"))
        XCTAssertThrowsError(try CustomVocabulary.addingCorrection(to: "", heard: "new", preferred: "New\nYork"))
        XCTAssertThrowsError(try CustomVocabulary.addingCorrection(to: "new = old", heard: "NEW", preferred: "New York"))
        XCTAssertThrowsError(try CustomVocabulary.addingCorrection(to: "broken =", heard: "new", preferred: "New York"))
    }

    func testNamesCaseAndPossessivesPreserveSurroundingText() throws {
        let words = try CustomVocabulary("Brecken = Breccan\nBreccan")
        XCTAssertEqual(words.apply(to: "BRECKEN, meet breccan. Brecken’s book.\n\nBrecken's bag."),
                       "Breccan, meet Breccan. Breccan’s book.\n\nBreccan's bag.")
    }

    func testWholeWordsAndUnicodeBoundaries() throws {
        let words = try CustomVocabulary("Brecken = Breccan")
        XCTAssertEqual(words.apply(to: "Breckenridge éBrecken Brecken2 Brecken_name Brecken."),
                       "Breckenridge éBrecken Brecken2 Brecken_name Breccan.")
    }

    func testLongestPhraseWinsAndReplacementsDoNotCascade() throws {
        let words = try CustomVocabulary("new york = New York\nnew = old\nold = ancient")
        XCTAssertEqual(words.apply(to: "new york new old"), "New York old ancient")
    }

    func testLiteralMetacharactersAndReplacementCharacters() throws {
        let words = try CustomVocabulary("C++ = C Plus Plus\nmoney = $1\\value")
        XCTAssertEqual(words.apply(to: "C++ money"), "C Plus Plus $1\\value")
    }

    func testEmptyAndInvalidConfiguration() throws {
        XCTAssertEqual(try CustomVocabulary("\n ").apply(to: "  Unchanged.\n"), "  Unchanged.\n")
        for text in ["= name", "wrong =", "a = b = c", "word\nWORD = other"] {
            XCTAssertThrowsError(try CustomVocabulary(text))
        }
    }
}
