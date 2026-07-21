import XCTest
@testable import App

final class OnboardingMigrationTests: XCTestCase {
    func testDoesNotSkipOnboardingForBrandNewInstall() {
        let harness = makeHarness()
        defer { harness.reset() }

        XCTAssertFalse(
            AppDelegate.shouldSkipOnboardingForExistingInstall(
                defaults: harness.defaults,
                keychainService: harness.keychainService
            )
        )
    }

    func testSkipsOnboardingForExistingInstallWithTrialState() {
        let harness = makeHarness()
        defer { harness.reset() }

        harness.defaults.set(Date().timeIntervalSince1970, forKey: "trialStartDate")

        XCTAssertTrue(
            AppDelegate.shouldSkipOnboardingForExistingInstall(
                defaults: harness.defaults,
                keychainService: harness.keychainService
            )
        )
    }

    func testSkipsOnboardingForExistingInstallWithKeychainLicenseState() {
        let harness = makeHarness()
        defer { harness.reset() }

        AppKeychainStore.save(
            key: "com.blazing.fast-transcription.licenseKey",
            value: "test-license",
            service: harness.keychainService
        )

        XCTAssertTrue(
            AppDelegate.shouldSkipOnboardingForExistingInstall(
                defaults: harness.defaults,
                keychainService: harness.keychainService
            )
        )
    }

    func testDoesNotOverrideExplicitReplayFlag() {
        let harness = makeHarness()
        defer { harness.reset() }

        harness.defaults.set(false, forKey: "hasCompletedOnboarding")
        harness.defaults.set(Date().timeIntervalSince1970, forKey: "trialStartDate")

        XCTAssertFalse(
            AppDelegate.shouldSkipOnboardingForExistingInstall(
                defaults: harness.defaults,
                keychainService: harness.keychainService
            )
        )
    }

    private func makeHarness() -> KeyedStorageHarness {
        let suiteName = "OnboardingMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keychainService = "OnboardingMigrationTests.\(UUID().uuidString)"
        let harness = KeyedStorageHarness(
            suiteName: suiteName,
            defaults: defaults,
            keychainService: keychainService
        )
        harness.reset()
        return harness
    }
}
