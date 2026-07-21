import XCTest
@testable import App

final class BrowserHostPolicyTests: XCTestCase {
    func testChromePrefersDirectRealtimeTyping() {
        XCTAssertTrue(
            BrowserHostPolicy.prefersDirectRealtimeTyping(
                bundleIdentifier: "com.google.Chrome",
                appName: "Google Chrome"
            )
        )
    }

    func testTerminalDoesNotPreferDirectRealtimeTyping() {
        XCTAssertFalse(
            BrowserHostPolicy.prefersDirectRealtimeTyping(
                bundleIdentifier: "com.apple.Terminal",
                appName: "Terminal"
            )
        )
    }

    func testTurboPresetPrefersDirectTypingInBrowser() {
        XCTAssertTrue(
            AppDelegate.shouldPreferDirectRealtimeTyping(
                preset: .powerUserFastest,
                bundleIdentifier: "com.google.Chrome",
                appName: "Google Chrome"
            )
        )
    }

    func testStablePresetKeepsBrowserOnDefaultRealtimePath() {
        XCTAssertFalse(
            AppDelegate.shouldPreferDirectRealtimeTyping(
                preset: .stable,
                bundleIdentifier: "com.google.Chrome",
                appName: "Google Chrome"
            )
        )
    }
}
