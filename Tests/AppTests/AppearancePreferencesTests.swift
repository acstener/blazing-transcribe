import XCTest
@testable import App

final class AppearancePreferencesTests: XCTestCase {
    func testDefaultsToSystemWhenPreferenceIsMissing() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        XCTAssertEqual(AppearancePreferences.current(defaults: defaults), .system)
        XCTAssertNil(AppearancePreferences.system.windowAppearanceName)
        XCTAssertNil(AppearancePreferences.system.preferredColorScheme)
    }

    func testPersistsExplicitDarkSelection() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        AppearancePreferences.dark.persist(defaults: defaults)

        XCTAssertEqual(AppearancePreferences.current(defaults: defaults), .dark)
        XCTAssertEqual(AppearancePreferences.dark.windowAppearanceName, .darkAqua)
        XCTAssertEqual(AppearancePreferences.dark.preferredColorScheme, .dark)
    }

    func testPersistsExplicitLightSelection() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        AppearancePreferences.light.persist(defaults: defaults)

        XCTAssertEqual(AppearancePreferences.current(defaults: defaults), .light)
        XCTAssertEqual(AppearancePreferences.light.windowAppearanceName, .aqua)
        XCTAssertEqual(AppearancePreferences.light.preferredColorScheme, .light)
    }

    func testIgnoresUnknownStoredValue() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set("sepia", forKey: AppearancePreferences.defaultsKey)

        XCTAssertEqual(AppearancePreferences.current(defaults: defaults), .system)
    }
}
