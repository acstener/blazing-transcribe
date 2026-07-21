import XCTest
@testable import App

final class TextDeliveryPolicyTests: XCTestCase {
    func testSingleLineTextUsesTyping() {
        XCTAssertEqual(
            TextDeliveryPolicy.method(
                for: "Ship it today.",
                bundleIdentifier: "com.google.Chrome",
                appName: "Google Chrome"
            ),
            .typing
        )
    }

    func testMultilineBrowserTextUsesClipboardPaste() {
        XCTAssertEqual(
            TextDeliveryPolicy.method(
                for: "First paragraph.\n\nSecond paragraph.",
                bundleIdentifier: "com.google.Chrome",
                appName: "Google Chrome"
            ),
            .clipboardPaste
        )
    }

    func testMultilineStrictTerminalTextStaysTyped() {
        XCTAssertEqual(
            TextDeliveryPolicy.method(
                for: "echo one\necho two",
                bundleIdentifier: "com.apple.Terminal",
                appName: "Terminal"
            ),
            .typing
        )
    }

    func testMultilineEditorTextStillUsesClipboardPaste() {
        XCTAssertEqual(
            TextDeliveryPolicy.method(
                for: "line one\nline two",
                bundleIdentifier: "com.microsoft.VSCode",
                appName: "Visual Studio Code"
            ),
            .clipboardPaste
        )
    }

    func testNormalizedTextCollapsesCarriageReturnsToLineFeeds() {
        XCTAssertEqual(
            TextDeliveryPolicy.normalizedText("hello\r\nworld\ragain"),
            "hello\nworld\nagain"
        )
    }
}
