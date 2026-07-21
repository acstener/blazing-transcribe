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
