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

    /// Keys the app itself writes on a fresh first launch (preset migration,
    /// default text cleanup, telemetry, launch-at-login, crash flag, Setup step).
    private func writeFirstLaunchAppKeys(to defaults: UserDefaults) {
        defaults.set("stable", forKey: "transcriptionPreset")
        defaults.set(false, forKey: "experimentalMode")
        defaults.set("parakeetV3", forKey: "experimentalEngine")
        defaults.set(true, forKey: "llmCleanupEnabled")
        defaults.set("regex", forKey: "llmCleanupModel")
        defaults.set(true, forKey: "shortcutMigrationV2")
        defaults.set(true, forKey: "launchAtLoginDefaultApplied")
        defaults.set(UUID().uuidString, forKey: "telemetryInstallID")
        defaults.set(true, forKey: "posthogDidTrackInstall")
        defaults.set(true, forKey: "appIsRunning")
        defaults.set("manual", forKey: "recordingMode")
        defaults.set("MacBook Pro Microphone", forKey: "preferredInputDevice")
    }

    func testKeysWrittenByTheAppOnFirstLaunchAreNotExistingInstallEvidence() {
        // An install that was mid-onboarding on an older build: the app already wrote
        // its own defaults, but hasCompletedOnboarding was never stored.
        let harness = makeHarness()
        defer { harness.reset() }

        writeFirstLaunchAppKeys(to: harness.defaults)

        XCTAssertFalse(
            AppDelegate.shouldSkipOnboardingForExistingInstall(
                defaults: harness.defaults,
                keychainService: harness.keychainService
            )
        )
    }

    func testRelaunchMidOnboardingDoesNotSkipOnboarding() {
        let harness = makeHarness()
        defer { harness.reset() }

        // First launch: new install.
        let first = FirstLaunchPolicy.applyLaunchPolicy(
            defaults: harness.defaults,
            keychainService: harness.keychainService,
            historyFileURL: nil
        )
        XCTAssertEqual(first, .newInstall)
        XCTAssertEqual(harness.defaults.object(forKey: "hasCompletedOnboarding") as? Bool, false)

        // The rest of launch writes its defaults; the user quits during Setup.
        writeFirstLaunchAppKeys(to: harness.defaults)

        // Second launch: onboarding must still be pending.
        let second = FirstLaunchPolicy.applyLaunchPolicy(
            defaults: harness.defaults,
            keychainService: harness.keychainService,
            historyFileURL: nil
        )
        XCTAssertEqual(second, .alreadyDecided)
        XCTAssertFalse(harness.defaults.bool(forKey: "hasCompletedOnboarding"))
        XCTAssertFalse(
            AppDelegate.shouldSkipOnboardingForExistingInstall(
                defaults: harness.defaults,
                keychainService: harness.keychainService
            )
        )
    }

    func testSkipsOnboardingForExistingInstallWithRealUsage() {
        let harness = makeHarness()
        defer { harness.reset() }

        harness.defaults.set(12, forKey: "stats.totalUtterances")

        XCTAssertTrue(
            AppDelegate.shouldSkipOnboardingForExistingInstall(
                defaults: harness.defaults,
                keychainService: harness.keychainService
            )
        )
    }

    func testZeroUsageCountersAreNotEvidence() {
        let harness = makeHarness()
        defer { harness.reset() }

        harness.defaults.set(0, forKey: "stats.totalUtterances")
        harness.defaults.set(0, forKey: "stats.totalWords")

        XCTAssertFalse(
            AppDelegate.shouldSkipOnboardingForExistingInstall(
                defaults: harness.defaults,
                keychainService: harness.keychainService
            )
        )
    }

    func testSkipsOnboardingWhenHistoryHasEntries() throws {
        let harness = makeHarness()
        defer { harness.reset() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnboardingMigrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let emptyHistory = directory.appendingPathComponent("empty.json")
        try Data("[]".utf8).write(to: emptyHistory)
        XCTAssertFalse(
            AppDelegate.shouldSkipOnboardingForExistingInstall(
                defaults: harness.defaults,
                keychainService: harness.keychainService,
                historyFileURL: emptyHistory
            )
        )

        let history = directory.appendingPathComponent("history.json")
        try Data(#"[{"id":"x","text":"hello"}]"#.utf8).write(to: history)
        XCTAssertTrue(
            AppDelegate.shouldSkipOnboardingForExistingInstall(
                defaults: harness.defaults,
                keychainService: harness.keychainService,
                historyFileURL: history
            )
        )
    }

    func testExistingInstallResolutionMarksOnboardingComplete() {
        let harness = makeHarness()
        defer { harness.reset() }

        harness.defaults.set(Date().timeIntervalSince1970, forKey: "trialStartDate")

        let resolution = FirstLaunchPolicy.applyLaunchPolicy(
            defaults: harness.defaults,
            keychainService: harness.keychainService,
            historyFileURL: nil
        )
        XCTAssertEqual(resolution, .existingInstall)
        XCTAssertTrue(harness.defaults.bool(forKey: "hasCompletedOnboarding"))
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
