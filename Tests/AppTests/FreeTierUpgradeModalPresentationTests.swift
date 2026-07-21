import XCTest
@testable import App

final class FreeTierUpgradeModalPresentationTests: XCTestCase {
    func testShowsWhenTrialTransitionsToFreeTier() {
        XCTAssertTrue(
            AppDelegate.shouldPresentFreeTierUpgradeModal(
                previousStatus: .trial(daysRemaining: 1),
                currentStatus: .freeTier,
                source: "transcriptionFinalize",
                hasShownForCurrentResetVersion: false
            )
        )
    }

    func testShowsOnLaunchWhenUserStartsInFreeTier() {
        XCTAssertTrue(
            AppDelegate.shouldPresentFreeTierUpgradeModal(
                previousStatus: .noKey,
                currentStatus: .freeTier,
                source: "launch",
                hasShownForCurrentResetVersion: false
            )
        )
    }

    func testDoesNotShowAgainAfterDismissal() {
        XCTAssertFalse(
            AppDelegate.shouldPresentFreeTierUpgradeModal(
                previousStatus: .trial(daysRemaining: 1),
                currentStatus: .freeTier,
                source: "transcriptionFinalize",
                hasShownForCurrentResetVersion: true
            )
        )
    }

    func testDoesNotShowWhenAlreadyInFreeTier() {
        XCTAssertFalse(
            AppDelegate.shouldPresentFreeTierUpgradeModal(
                previousStatus: .freeTier,
                currentStatus: .freeTier,
                source: "pttDidPress",
                hasShownForCurrentResetVersion: false
            )
        )
    }

    func testDoesNotShowForPaidStatus() {
        XCTAssertFalse(
            AppDelegate.shouldPresentFreeTierUpgradeModal(
                previousStatus: .trial(daysRemaining: 1),
                currentStatus: .valid,
                source: "launch",
                hasShownForCurrentResetVersion: false
            )
        )
    }
}
