import XCTest
@testable import App

final class FreeTierUsageTrackerTests: XCTestCase {
    func testRecordsWordsAndResetsAfterSevenDays() {
        let harness = makeHarness()
        defer { harness.reset() }

        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let notificationCenter = NotificationCenter()
        let tracker = FreeTierUsageTracker(
            defaults: harness.defaults,
            notificationCenter: notificationCenter,
            keychainService: harness.keychainService
        ) {
            now
        }

        let counter = TestNotificationCounter()
        let token = notificationCenter.addObserver(
            forName: .freeTierPeriodDidReset,
            object: tracker,
            queue: nil
        ) { _ in
            counter.count += 1
        }
        defer { notificationCenter.removeObserver(token) }

        tracker.resetUsage()
        tracker.recordWords(1_250)

        XCTAssertEqual(tracker.wordsUsed, 1_250)
        XCTAssertEqual(tracker.wordsRemaining, 750)
        XCTAssertFalse(tracker.isLimitReached)

        now = now.addingTimeInterval(Constants.freeTierPeriodDuration + 60)

        XCTAssertEqual(tracker.wordsUsed, 0)
        XCTAssertEqual(tracker.wordsRemaining, Constants.freeTierWordLimitPerWeek)
        XCTAssertEqual(counter.count, 2)
    }

    func testRestoresUsageFromKeychainAfterDefaultsReset() {
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

        tracker.resetUsage()
        tracker.recordWords(420)

        harness.defaults.removePersistentDomain(forName: harness.suiteName)

        let restoredDefaults = UserDefaults(suiteName: harness.suiteName)!
        let restoredTracker = FreeTierUsageTracker(
            defaults: restoredDefaults,
            notificationCenter: NotificationCenter(),
            keychainService: harness.keychainService
        ) {
            now
        }

        XCTAssertEqual(restoredTracker.wordsUsed, 420)
        XCTAssertEqual(restoredTracker.wordsRemaining, 1_580)
    }

    private func makeHarness() -> KeyedStorageHarness {
        let suiteName = "FreeTierUsageTrackerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return KeyedStorageHarness(
            suiteName: suiteName,
            defaults: defaults,
            keychainService: "FreeTierUsageTrackerTests.\(UUID().uuidString)"
        )
    }
}
