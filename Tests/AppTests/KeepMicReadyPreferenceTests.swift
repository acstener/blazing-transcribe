import XCTest
@testable import App

final class KeepMicReadyPreferenceTests: XCTestCase {
    func testDefaultsToOffWhenPreferenceIsMissing() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        XCTAssertFalse(KeepMicReadyPreference.isEnabled(defaults: defaults))
    }

    func testPersistsExplicitOn() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        KeepMicReadyPreference.setEnabled(true, defaults: defaults)

        XCTAssertTrue(KeepMicReadyPreference.isEnabled(defaults: defaults))
    }

    func testManualRealtimeDoesNotForceStandby() {
        XCTAssertFalse(
            KeepMicReadyPreference.shouldKeepCaptureRunning(
                recordingMode: .manual,
                keepMicReady: false
            )
        )
    }

    func testAlwaysOnKeepsCaptureRunning() {
        XCTAssertTrue(
            KeepMicReadyPreference.shouldKeepCaptureRunning(
                recordingMode: .alwaysOn,
                keepMicReady: false
            )
        )
    }
}
