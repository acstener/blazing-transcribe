import XCTest
@testable import App

final class RealtimeOverlayPartialVisibilityTests: XCTestCase {
    func testAlwaysOnSessionsKeepOverlayPartialsVisible() {
        XCTAssertTrue(
            AppDelegate.shouldAllowRealtimeOverlayPartialDisplay(
                recordingMode: .alwaysOn,
                isManualRecording: false,
                isToggleRecording: false
            )
        )
    }

    func testManualRealtimePartialsRemainVisibleWhileRecording() {
        XCTAssertTrue(
            AppDelegate.shouldAllowRealtimeOverlayPartialDisplay(
                recordingMode: .manual,
                isManualRecording: true,
                isToggleRecording: false
            )
        )
        XCTAssertTrue(
            AppDelegate.shouldAllowRealtimeOverlayPartialDisplay(
                recordingMode: .manual,
                isManualRecording: false,
                isToggleRecording: true
            )
        )
    }

    func testManualRealtimePartialsAreHiddenAfterRelease() {
        XCTAssertFalse(
            AppDelegate.shouldAllowRealtimeOverlayPartialDisplay(
                recordingMode: .manual,
                isManualRecording: false,
                isToggleRecording: false
            )
        )
    }
}
