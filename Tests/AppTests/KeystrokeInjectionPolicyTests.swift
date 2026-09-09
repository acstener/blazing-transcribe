import XCTest
@testable import App

final class KeystrokeInjectionPolicyTests: XCTestCase {
    func testFirefoxWebAreaDoesNotReceiveKeystrokes() {
        XCTAssertFalse(
            KeystrokeInjectionPolicy.shouldInjectKeystrokes(
                bundleIdentifier: "org.mozilla.firefox",
                appName: "Firefox",
                focused: .webArea
            )
        )
    }

    func testFirefoxWithNoFocusedElementDoesNotReceiveKeystrokes() {
        XCTAssertFalse(
            KeystrokeInjectionPolicy.shouldInjectKeystrokes(
                bundleIdentifier: "org.mozilla.firefox",
                appName: "Firefox",
                focused: .none
            )
        )
    }

    func testFirefoxEditableFieldStillReceivesKeystrokes() {
        XCTAssertTrue(
            KeystrokeInjectionPolicy.shouldInjectKeystrokes(
                bundleIdentifier: "org.mozilla.firefox",
                appName: "Firefox",
                focused: .editableText
            )
        )
    }

    func testFirefoxSearchFieldStillReceivesKeystrokes() {
        XCTAssertTrue(
            KeystrokeInjectionPolicy.shouldInjectKeystrokes(
                bundleIdentifier: "org.mozilla.firefox",
                appName: "Firefox",
                focused: .searchField
            )
        )
    }

    func testSafariWebAreaDoesNotReceiveKeystrokes() {
        XCTAssertFalse(
            KeystrokeInjectionPolicy.shouldInjectKeystrokes(
                bundleIdentifier: "com.apple.Safari",
                appName: "Safari",
                focused: .webArea
            )
        )
    }

    func testChromePageWithoutFieldDoesNotReceiveKeystrokes() {
        XCTAssertFalse(
            KeystrokeInjectionPolicy.shouldInjectKeystrokes(
                bundleIdentifier: "com.google.Chrome",
                appName: "Google Chrome",
                focused: .other
            )
        )
    }

    func testTerminalWithoutAXFieldStillReceivesKeystrokes() {
        XCTAssertTrue(
            KeystrokeInjectionPolicy.shouldInjectKeystrokes(
                bundleIdentifier: "com.apple.Terminal",
                appName: "Terminal",
                focused: .none
            )
        )
    }

    func testClassifyWebArea() {
        XCTAssertEqual(
            KeystrokeInjectionPolicy.classify(role: "AXWebArea", subrole: nil, valueIsSettable: false),
            .webArea
        )
    }

    func testClassifySearchFieldBySubrole() {
        XCTAssertEqual(
            KeystrokeInjectionPolicy.classify(role: "AXTextField", subrole: "AXSearchField", valueIsSettable: true),
            .searchField
        )
    }

    func testClassifyTextFieldAsEditable() {
        XCTAssertEqual(
            KeystrokeInjectionPolicy.classify(role: "AXTextField", subrole: nil, valueIsSettable: false),
            .editableText
        )
    }

    func testClassifyContentEditableSettableValueAsEditable() {
        XCTAssertEqual(
            KeystrokeInjectionPolicy.classify(role: "AXGroup", subrole: nil, valueIsSettable: true),
            .editableText
        )
    }

    func testClassifySecureFieldIsNotEditable() {
        XCTAssertEqual(
            KeystrokeInjectionPolicy.classify(role: "AXTextField", subrole: "AXSecureTextField", valueIsSettable: true),
            .other
        )
    }

    func testClassifyMissingElementAsNone() {
        XCTAssertEqual(
            KeystrokeInjectionPolicy.classify(role: nil, subrole: nil, valueIsSettable: false),
            .none
        )
    }
}
