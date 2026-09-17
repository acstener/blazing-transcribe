import XCTest
@testable import App

final class DockVisibilityPolicyTests: XCTestCase {
    func testDefaultsToHiddenDockWhenPreferenceIsMissing() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        XCTAssertFalse(DockVisibilityPolicy.wantsDockIcon(defaults: defaults))
    }

    func testPersistsExplicitDockOn() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        DockVisibilityPolicy.setWantsDockIcon(true, defaults: defaults)

        XCTAssertTrue(DockVisibilityPolicy.wantsDockIcon(defaults: defaults))
    }

    func testPersistsExplicitDockOff() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        DockVisibilityPolicy.setWantsDockIcon(true, defaults: defaults)
        DockVisibilityPolicy.setWantsDockIcon(false, defaults: defaults)

        XCTAssertFalse(DockVisibilityPolicy.wantsDockIcon(defaults: defaults))
    }
}
