import XCTest
@testable import App

final class UsageStatsTests: XCTestCase {
    func testLegacyStatsKeysStillLoadInCurrentApp() {
        let harness = makeIsolatedDefaults()
        defer { harness.reset() }

        let firstUseTimestamp = Date(timeIntervalSince1970: 1_700_000_000).timeIntervalSince1970
        harness.defaults.set(4_321, forKey: LegacyKey.totalWords)
        harness.defaults.set(21_098, forKey: LegacyKey.totalCharacters)
        harness.defaults.set(87, forKey: LegacyKey.totalUtterances)
        harness.defaults.set(45.5, forKey: LegacyKey.totalTranscriptionSeconds)
        harness.defaults.set(901.25, forKey: LegacyKey.totalSpeechSeconds)
        harness.defaults.set(firstUseTimestamp, forKey: LegacyKey.firstUseDate)

        let stats = UsageStats(defaults: harness.defaults, notificationCenter: NotificationCenter())

        XCTAssertEqual(stats.totalWords, 4_321)
        XCTAssertEqual(stats.totalCharacters, 21_098)
        XCTAssertEqual(stats.totalUtterances, 87)
        XCTAssertEqual(stats.totalTranscriptionSeconds, 45.5, accuracy: 0.0001)
        XCTAssertEqual(stats.totalSpeechSeconds, 901.25, accuracy: 0.0001)
        XCTAssertNotNil(stats.firstUseDate)
        XCTAssertEqual(stats.firstUseDate!.timeIntervalSince1970, firstUseTimestamp, accuracy: 0.0001)
    }

    func testRecordAndRecordStreamingPersistExpectedCounters() {
        let harness = makeIsolatedDefaults()
        defer { harness.reset() }

        let stats = UsageStats(defaults: harness.defaults, notificationCenter: NotificationCenter())
        stats.record(
            wordCount: 120,
            characterCount: 640,
            transcriptionDuration: 1.5,
            speechDuration: 30
        )
        stats.recordStreaming(wordCount: 10, characterCount: 55)

        XCTAssertEqual(stats.totalWords, 130)
        XCTAssertEqual(stats.totalCharacters, 695)
        XCTAssertEqual(stats.totalUtterances, 1)
        XCTAssertEqual(stats.totalTranscriptionSeconds, 1.5, accuracy: 0.0001)
        XCTAssertEqual(stats.totalSpeechSeconds, 30, accuracy: 0.0001)
        XCTAssertNotNil(stats.firstUseDate)

        XCTAssertEqual(stats.pagesOfText, 0.52, accuracy: 0.0001)
        XCTAssertEqual(stats.timeSavedVsTyping, 165, accuracy: 0.0001)
        XCTAssertEqual(stats.keypressesSaved, 2)
        XCTAssertEqual(stats.avgTranscriptionTime, 1.5, accuracy: 0.0001)
        XCTAssertEqual(stats.speakingWPM, 260, accuracy: 0.0001)
    }

    func testMutationsPostChangeNotificationsAndResetClearsCounters() {
        let harness = makeIsolatedDefaults()
        defer { harness.reset() }

        let notificationCenter = NotificationCenter()
        let stats = UsageStats(defaults: harness.defaults, notificationCenter: notificationCenter)
        let counter = NotificationCounter()
        let token = notificationCenter.addObserver(
            forName: .usageStatsDidChange,
            object: stats,
            queue: nil
        ) { _ in
            counter.count += 1
        }
        defer { notificationCenter.removeObserver(token) }

        stats.record(
            wordCount: 20,
            characterCount: 100,
            transcriptionDuration: 0.4,
            speechDuration: 5
        )
        stats.recordStreaming(wordCount: 5, characterCount: 20)
        stats.reset()

        XCTAssertEqual(stats.totalWords, 0)
        XCTAssertEqual(stats.totalCharacters, 0)
        XCTAssertEqual(stats.totalUtterances, 0)
        XCTAssertEqual(stats.totalTranscriptionSeconds, 0, accuracy: 0.0001)
        XCTAssertEqual(stats.totalSpeechSeconds, 0, accuracy: 0.0001)
        XCTAssertNotNil(stats.firstUseDate)
        XCTAssertEqual(counter.count, 3)
    }

    func testCleanupFixesAccumulateAndResetClearsThem() {
        let harness = makeIsolatedDefaults()
        defer { harness.reset() }
        let stats = UsageStats(defaults: harness.defaults, notificationCenter: NotificationCenter())

        XCTAssertEqual(stats.totalCleanupFixes, 0)
        stats.recordCleanupFixes(3)
        stats.recordCleanupFixes(0)
        stats.recordCleanupFixes(2)
        XCTAssertEqual(stats.totalCleanupFixes, 5)

        stats.reset()
        XCTAssertEqual(stats.totalCleanupFixes, 0)
    }

    private func makeIsolatedDefaults() -> IsolatedDefaults {
        let suiteName = "UsageStatsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return IsolatedDefaults(suiteName: suiteName, defaults: defaults)
    }
}

private enum LegacyKey {
    static let totalWords = "stats.totalWords"
    static let totalCharacters = "stats.totalCharacters"
    static let totalUtterances = "stats.totalUtterances"
    static let totalTranscriptionSeconds = "stats.totalTranscriptionSeconds"
    static let totalSpeechSeconds = "stats.totalSpeechSeconds"
    static let firstUseDate = "stats.firstUseDate"
}

private struct IsolatedDefaults {
    let suiteName: String
    let defaults: UserDefaults

    func reset() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private final class NotificationCounter {
    var count = 0
}
