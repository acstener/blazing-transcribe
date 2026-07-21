import XCTest
@testable import App

final class ModeToggleEligibilityTests: XCTestCase {
    func testAllowsModeToggleAfterPttReleaseWhileManualTeardownFinishes() {
        XCTAssertTrue(
            AppDelegate.shouldAllowModeToggle(
                isManualRecording: true,
                isToggleRecording: false,
                isPTTShortcutHeld: false
            )
        )
    }

    func testBlocksModeToggleWhilePttShortcutStillHeld() {
        XCTAssertFalse(
            AppDelegate.shouldAllowModeToggle(
                isManualRecording: true,
                isToggleRecording: false,
                isPTTShortcutHeld: true
            )
        )
    }

    func testBlocksModeToggleDuringToggleRecording() {
        XCTAssertFalse(
            AppDelegate.shouldAllowModeToggle(
                isManualRecording: true,
                isToggleRecording: true,
                isPTTShortcutHeld: false
            )
        )
    }

    func testAllowsModeToggleWhenIdle() {
        XCTAssertTrue(
            AppDelegate.shouldAllowModeToggle(
                isManualRecording: false,
                isToggleRecording: false,
                isPTTShortcutHeld: false
            )
        )
    }
}
