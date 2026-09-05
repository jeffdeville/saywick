import XCTest
@testable import VoiceKeyboardCore

final class CustomVocabularyTests: XCTestCase {
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
