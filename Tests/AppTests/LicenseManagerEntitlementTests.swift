import XCTest
@testable import App

final class LicenseManagerEntitlementTests: XCTestCase {
    func testResolveCurrentEntitlementStartsOneTimeV2TrialForNewUser() async {
        let harness = makeHarness()
        defer { harness.reset() }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tracker = FreeTierUsageTracker(
            defaults: harness.defaults,
            notificationCenter: NotificationCenter(),
            keychainService: harness.keychainService
        ) {
            now
        }
        let manager = LicenseManager(
            defaults: harness.defaults,
            keychainService: harness.keychainService,
            nowProvider: { now },
            freeTierUsageTracker: tracker,
            isFreeBuild: false
        )

        let status = await manager.resolveCurrentEntitlement()

        XCTAssertEqual(status, .trial(daysRemaining: 7))
        XCTAssertEqual(
            harness.defaults.string(forKey: "monetizationResetVersion"),
            Constants.monetizationResetVersion
        )
        XCTAssertEqual(harness.defaults.double(forKey: "trialStartDate"), now.timeIntervalSince1970, accuracy: 0.001)
    }

    func testRefreshLocalEntitlementFallsBackToFreeTierAfterTrialExpires() async {
        let harness = makeHarness()
        defer { harness.reset() }

        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let tracker = FreeTierUsageTracker(
            defaults: harness.defaults,
            notificationCenter: NotificationCenter(),
            keychainService: harness.keychainService
        ) {
            now
        }
        let manager = LicenseManager(
            defaults: harness.defaults,
            keychainService: harness.keychainService,
            nowProvider: { now },
            freeTierUsageTracker: tracker,
            isFreeBuild: false
        )

        _ = await manager.resolveCurrentEntitlement()
        now = now.addingTimeInterval(Constants.trialDurationSeconds + 60)

        XCTAssertEqual(manager.refreshLocalEntitlement(), .freeTier)
    }

    func testHandledMigrationDoesNotResetExpiredTrialAgain() async {
        let harness = makeHarness()
        defer { harness.reset() }

        let oldTrialStart = Date(timeIntervalSince1970: 1_700_000_000)
        let now = oldTrialStart.addingTimeInterval(Constants.trialDurationSeconds * 2)
        harness.defaults.set(oldTrialStart.timeIntervalSince1970, forKey: "trialStartDate")
        harness.defaults.set(Constants.monetizationResetVersion, forKey: "monetizationResetVersion")
        AppKeychainStore.save(
            key: "com.blazing.fast-transcription.trialStartDate",
            value: String(oldTrialStart.timeIntervalSince1970),
            service: harness.keychainService
        )
        AppKeychainStore.save(
            key: "com.blazing.fast-transcription.monetizationResetVersion",
            value: Constants.monetizationResetVersion,
            service: harness.keychainService
        )

        let tracker = FreeTierUsageTracker(
            defaults: harness.defaults,
            notificationCenter: NotificationCenter(),
            keychainService: harness.keychainService
        ) {
            now
        }
        let manager = LicenseManager(
            defaults: harness.defaults,
            keychainService: harness.keychainService,
            nowProvider: { now },
            freeTierUsageTracker: tracker,
            isFreeBuild: false
        )

        let status = await manager.resolveCurrentEntitlement()

        XCTAssertEqual(status, .freeTier)
        XCTAssertEqual(harness.defaults.double(forKey: "trialStartDate"), oldTrialStart.timeIntervalSince1970, accuracy: 0.001)
    }

    func testFreeBuildResolvesValidEverywhereWithoutTouchingTrialState() async {
        let harness = makeHarness()
        defer { harness.reset() }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tracker = FreeTierUsageTracker(
            defaults: harness.defaults,
            notificationCenter: NotificationCenter(),
            keychainService: harness.keychainService
        ) {
            now
        }
        let manager = LicenseManager(
            defaults: harness.defaults,
            keychainService: harness.keychainService,
            nowProvider: { now },
            freeTierUsageTracker: tracker,
            isFreeBuild: true
        )

        let resolved = await manager.resolveCurrentEntitlement()
        XCTAssertEqual(resolved, .valid)
        XCTAssertEqual(manager.resolveLocalEntitlementFast(), .valid)
        XCTAssertEqual(manager.refreshLocalEntitlement(), .valid)
        XCTAssertEqual(manager.checkTrial(), .valid)
        // Free build must not seed trial state — keeps a future flag-flip clean.
        XCTAssertEqual(harness.defaults.double(forKey: "trialStartDate"), 0)
    }

    private func makeHarness() -> KeyedStorageHarness {
        let suiteName = "LicenseManagerEntitlementTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return KeyedStorageHarness(
            suiteName: suiteName,
            defaults: defaults,
            keychainService: "LicenseManagerEntitlementTests.\(UUID().uuidString)"
        )
    }
}
