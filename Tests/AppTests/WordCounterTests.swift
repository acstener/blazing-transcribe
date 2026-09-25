import XCTest
@testable import App

final class WordCounterTests: XCTestCase {
    func testCountsWordsAcrossWhitespaceAndPunctuation() {
        let text = "Hello, world.\nThis is\tBlazing Transcribe."
        XCTAssertEqual(WordCounter.countWords(in: text), 6)
    }

    func testReturnsZeroForEmptyOrWhitespaceOnlyText() {
        XCTAssertEqual(WordCounter.countWords(in: ""), 0)
        XCTAssertEqual(WordCounter.countWords(in: "   \n\t  "), 0)
    }
}

final class SpokenContentTests: XCTestCase {
    func testPunctuationOnlyTranscriptsHaveNoSpokenContent() {
        // Real outputs seen in logs after filler cleanup of "Mm." / "Um -."
        XCTAssertFalse(WordCounter.hasSpokenContent("."))
        XCTAssertFalse(WordCounter.hasSpokenContent("-."))
        XCTAssertFalse(WordCounter.hasSpokenContent(""))
        XCTAssertFalse(WordCounter.hasSpokenContent("  , ... "))
    }

    func testRealWordsAndNumbersCount() {
        XCTAssertTrue(WordCounter.hasSpokenContent("Yes."))
        XCTAssertTrue(WordCounter.hasSpokenContent("42"))
        XCTAssertTrue(WordCounter.hasSpokenContent("Café"))
    }
}
