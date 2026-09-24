import XCTest
@testable import App

/// Decisions 1 and 2: new installs get Manual + mic off between recordings;
/// existing installs keep their stored or de facto settings.
final class FirstLaunchDefaultsTests: XCTestCase {
    func testNewInstallDefaultsToManualAndMicOff() {
        let result = FirstLaunchPolicy.launchDefaults(
            resolution: .newInstall,
            hasCompletedOnboarding: false,
            storedRecordingMode: nil,
            hasStoredKeepMicPreference: false
        )
        XCTAssertEqual(result.recordingMode, .manual)
        XCTAssertEqual(result.disableKeepMicReady, true)
    }

    func testUpgraderWithNoSavedModeKeepsDeFactoAlwaysOn() {
        let result = FirstLaunchPolicy.launchDefaults(
            resolution: .alreadyDecided,
            hasCompletedOnboarding: true,
            storedRecordingMode: nil,
            hasStoredKeepMicPreference: false
        )
        XCTAssertEqual(result.recordingMode, .alwaysOn)
        XCTAssertNil(result.disableKeepMicReady, "Upgraders keep the old keep-mic-ready default")
    }

    func testMigratedLegacyInstallKeepsDeFactoAlwaysOn() {
        let result = FirstLaunchPolicy.launchDefaults(
            resolution: .existingInstall,
            hasCompletedOnboarding: true,
            storedRecordingMode: nil,
            hasStoredKeepMicPreference: false
        )
        XCTAssertEqual(result.recordingMode, .alwaysOn)
        XCTAssertNil(result.disableKeepMicReady)
    }

    func testStoredValuesAreNeverOverwritten() {
        let result = FirstLaunchPolicy.launchDefaults(
            resolution: .newInstall,
            hasCompletedOnboarding: false,
            storedRecordingMode: "alwaysOn",
            hasStoredKeepMicPreference: true
        )
        XCTAssertNil(result.recordingMode)
        XCTAssertNil(result.disableKeepMicReady)
    }

    func testRelaunchMidOnboardingWithNoSavedModeGetsManual() {
        let result = FirstLaunchPolicy.launchDefaults(
            resolution: .alreadyDecided,
            hasCompletedOnboarding: false,
            storedRecordingMode: nil,
            hasStoredKeepMicPreference: false
        )
        XCTAssertEqual(result.recordingMode, .manual)
    }

    func testApplyLaunchPolicyPersistsNewInstallDefaults() {
        let suiteName = "FirstLaunchDefaultsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        FirstLaunchPolicy.applyLaunchPolicy(
            defaults: defaults,
            keychainService: "FirstLaunchDefaultsTests.\(UUID().uuidString)",
            historyFileURL: nil
        )

        XCTAssertEqual(defaults.string(forKey: "recordingMode"), RecordingMode.manual.rawValue)
        XCTAssertTrue(defaults.bool(forKey: "disableKeepMicReady"))
    }

    func testApplyLaunchPolicyPersistsAlwaysOnForOnboardedUpgrader() {
        let suiteName = "FirstLaunchDefaultsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "hasCompletedOnboarding")

        let resolution = FirstLaunchPolicy.applyLaunchPolicy(
            defaults: defaults,
            keychainService: "FirstLaunchDefaultsTests.\(UUID().uuidString)",
            historyFileURL: nil
        )

        XCTAssertEqual(resolution, .alreadyDecided)
        XCTAssertEqual(defaults.string(forKey: "recordingMode"), RecordingMode.alwaysOn.rawValue)
        XCTAssertNil(defaults.object(forKey: "disableKeepMicReady"))
    }
}
