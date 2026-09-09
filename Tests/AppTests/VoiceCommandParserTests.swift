import XCTest
@testable import App

final class VoiceCommandParserTests: XCTestCase {
    func testDeleteThat() {
        XCTAssertEqual(VoiceCommandParser.parse("delete that"), .deleteThat)
        XCTAssertEqual(VoiceCommandParser.parse("Delete that."), .deleteThat)
        XCTAssertEqual(VoiceCommandParser.parse("  scratch that  "), .deleteThat)
    }

    func testCopyCommands() {
        XCTAssertEqual(VoiceCommandParser.parse("copy that"), .copy)
        XCTAssertEqual(VoiceCommandParser.parse("Copy."), .copy)
        XCTAssertEqual(VoiceCommandParser.parse("copy"), .copy)
    }

    func testPasteCommands() {
        XCTAssertEqual(VoiceCommandParser.parse("paste"), .paste)
        XCTAssertEqual(VoiceCommandParser.parse("Paste that"), .paste)
        XCTAssertEqual(VoiceCommandParser.parse("paste that."), .paste)
    }

    func testNonCommandsAreTyped() {
        XCTAssertNil(VoiceCommandParser.parse("please delete that"))
        XCTAssertNil(VoiceCommandParser.parse("delete that file"))
        XCTAssertNil(VoiceCommandParser.parse("copy that file over"))
        XCTAssertNil(VoiceCommandParser.parse("paste the password"))
        XCTAssertNil(VoiceCommandParser.parse("hello world"))
        XCTAssertNil(VoiceCommandParser.parse(""))
    }

    func testDeleteThatRemovesLastDictationCharacters() {
        XCTAssertEqual(
            VoiceCommandParser.effect(for: .deleteThat, lastDictatedText: "hello world "),
            .deleteCharacters(12)
        )
        XCTAssertEqual(
            VoiceCommandParser.effect(for: .deleteThat, lastDictatedText: ""),
            .none
        )
    }

    func testCopyThatUsesLastDictationWithoutKeystrokes() {
        XCTAssertEqual(
            VoiceCommandParser.effect(for: .copy, lastDictatedText: "ship it "),
            .copyToClipboard("ship it")
        )
        XCTAssertEqual(
            VoiceCommandParser.effect(for: .copy, lastDictatedText: ""),
            .pressCopy
        )
    }

    func testPasteSendsPasteShortcut() {
        XCTAssertEqual(
            VoiceCommandParser.effect(for: .paste, lastDictatedText: "ignored"),
            .pressPaste
        )
    }

    func testStreamedPartialOfCommandIsRetracted() {
        XCTAssertTrue(VoiceCommandParser.streamedTextLooksLikeCommand("delete tha", commandText: "delete that"))
        XCTAssertTrue(VoiceCommandParser.streamedTextLooksLikeCommand("delete that", commandText: "delete that"))
        XCTAssertFalse(VoiceCommandParser.streamedTextLooksLikeCommand("hello world", commandText: "delete that"))
        XCTAssertFalse(VoiceCommandParser.streamedTextLooksLikeCommand("", commandText: "delete that"))
        XCTAssertFalse(VoiceCommandParser.streamedTextLooksLikeCommand("copy the file", commandText: "copy"))
        XCTAssertFalse(VoiceCommandParser.streamedTextLooksLikeCommand("paste extra", commandText: "paste"))
    }
}
