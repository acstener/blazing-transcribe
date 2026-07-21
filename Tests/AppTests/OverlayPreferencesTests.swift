import XCTest
@testable import App

final class OverlayPreferencesTests: XCTestCase {
    func testOverlayDefaultsToEnabledWhenPreferenceIsMissing() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        XCTAssertTrue(OverlayPreferences.isEnabled(defaults: defaults))
    }

    func testOverlayPreferencePersistsExplicitOffSelection() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        OverlayPreferences.setEnabled(false, defaults: defaults)

        XCTAssertFalse(OverlayPreferences.isEnabled(defaults: defaults))
    }

    func testOverlayPreferencePersistsExplicitOnSelection() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        OverlayPreferences.setEnabled(true, defaults: defaults)

        XCTAssertTrue(OverlayPreferences.isEnabled(defaults: defaults))
    }
}
