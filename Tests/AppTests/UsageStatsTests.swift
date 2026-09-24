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

    // MARK: - Milestones

    func testCurrentAndNextMilestone() {
        XCTAssertNil(UsageMilestone.current(forWords: 0))
        XCTAssertEqual(UsageMilestone.next(forWords: 0)?.words, 500)
        XCTAssertEqual(UsageMilestone.current(forWords: 500)?.name, "a short blog post")
        XCTAssertEqual(UsageMilestone.next(forWords: 500)?.name, "a blog post")
        XCTAssertEqual(UsageMilestone.current(forWords: 70_500)?.name, "a short novel")
        XCTAssertEqual(UsageMilestone.next(forWords: 70_500)?.name, "a full novel")
        XCTAssertEqual(UsageMilestone.current(forWords: 2_000_000)?.words, 1_000_000)
        XCTAssertNil(UsageMilestone.next(forWords: 2_000_000))
    }

    func testMilestoneRemainingTextAndProgress() {
        // 80,000 - 70,500 = 9,500 words = 38 pages.
        XCTAssertEqual(UsageMilestone.remainingText(forWords: 70_500), "38 pages to a full novel")
        // Partial pages round up.
        XCTAssertEqual(UsageMilestone.remainingText(forWords: 70_501), "38 pages to a full novel")
        XCTAssertEqual(UsageMilestone.remainingText(forWords: 79_700), "2 pages to a full novel")
        XCTAssertEqual(UsageMilestone.remainingText(forWords: 79_750), "1 page to a full novel")
        XCTAssertEqual(UsageMilestone.remainingText(forWords: 630), "120 words to a blog post")
        XCTAssertEqual(UsageMilestone.remainingText(forWords: 749), "1 word to a blog post")
        XCTAssertNil(UsageMilestone.remainingText(forWords: 1_000_000))

        XCTAssertEqual(UsageMilestone.progress(forWords: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(UsageMilestone.progress(forWords: 250), 0.5, accuracy: 0.0001)
        XCTAssertEqual(UsageMilestone.progress(forWords: 65_000), 0.5, accuracy: 0.0001)
        XCTAssertEqual(UsageMilestone.progress(forWords: 5_000_000), 1, accuracy: 0.0001)
    }

    func testMilestonesAreAscending() {
        let words = UsageMilestone.all.map(\.words)
        XCTAssertEqual(words, words.sorted())
        XCTAssertEqual(Set(words).count, words.count)
    }

    func testCrossingMilestoneIsCelebratedOnceAndPersists() {
        let harness = makeIsolatedDefaults()
        defer { harness.reset() }
        let stats = UsageStats(defaults: harness.defaults, notificationCenter: NotificationCenter())

        XCTAssertNil(stats.pendingCelebration)
        stats.record(wordCount: 400, characterCount: 0, transcriptionDuration: 0, speechDuration: 0)
        XCTAssertNil(stats.pendingCelebration)

        // Jumping past two milestones at once yields one toast, for the highest.
        stats.record(wordCount: 400, characterCount: 0, transcriptionDuration: 0, speechDuration: 0)
        XCTAssertEqual(stats.pendingCelebration?.words, 750)
        stats.markCelebrated(stats.pendingCelebration!)
        XCTAssertNil(stats.pendingCelebration)
        XCTAssertEqual(stats.celebratedMilestoneWords, [500, 750])

        // Persisted across instances.
        let reloaded = UsageStats(defaults: harness.defaults, notificationCenter: NotificationCenter())
        XCTAssertNil(reloaded.pendingCelebration)

        reloaded.recordStreaming(wordCount: 800, characterCount: 0)
        XCTAssertEqual(reloaded.pendingCelebration?.name, "a college essay")
    }

    func testExistingUsersAreSeededWithoutAStaleCelebration() {
        let harness = makeIsolatedDefaults()
        defer { harness.reset() }
        harness.defaults.set(20_000, forKey: LegacyKey.totalWords)
        let stats = UsageStats(defaults: harness.defaults, notificationCenter: NotificationCenter())

        XCTAssertNil(stats.pendingCelebration)
        stats.record(wordCount: 40_000, characterCount: 0, transcriptionDuration: 0, speechDuration: 0)
        XCTAssertEqual(stats.pendingCelebration?.name, "a short novel")
    }

    func testResetAllowsMilestonesToBeCelebratedAgain() {
        let harness = makeIsolatedDefaults()
        defer { harness.reset() }
        let stats = UsageStats(defaults: harness.defaults, notificationCenter: NotificationCenter())
        stats.record(wordCount: 600, characterCount: 0, transcriptionDuration: 0, speechDuration: 0)
        stats.markCelebrated(stats.pendingCelebration!)

        stats.reset()
        XCTAssertTrue(stats.celebratedMilestoneWords.isEmpty)
        XCTAssertNil(stats.pendingCelebration)
        stats.record(wordCount: 600, characterCount: 0, transcriptionDuration: 0, speechDuration: 0)
        XCTAssertEqual(stats.pendingCelebration?.words, 500)
    }

    // MARK: - Per-day words

    func testDailyWordsAccumulatePerDayAndResetClearsThem() {
        let harness = makeIsolatedDefaults()
        defer { harness.reset() }
        let stats = UsageStats(defaults: harness.defaults, notificationCenter: NotificationCenter())
        let day1 = makeDate(2026, 9, 23, hour: 9)
        let day1Late = makeDate(2026, 9, 23, hour: 23)
        let day2 = makeDate(2026, 9, 24, hour: 8)

        stats.record(wordCount: 100, characterCount: 0, transcriptionDuration: 0, speechDuration: 0, date: day1)
        stats.recordStreaming(wordCount: 20, characterCount: 0, date: day1Late)
        stats.record(wordCount: 7, characterCount: 0, transcriptionDuration: 0, speechDuration: 0, date: day2)
        stats.record(wordCount: 0, characterCount: 0, transcriptionDuration: 0, speechDuration: 0, date: makeDate(2026, 9, 25))

        XCTAssertEqual(stats.dailyWords, ["2026-09-23": 120, "2026-09-24": 7])
        XCTAssertEqual(stats.words(on: day1), 120)

        stats.reset()
        XCTAssertTrue(stats.dailyWords.isEmpty)
    }

    func testDailyWordsAreCappedToRetentionDroppingOldest() {
        let harness = makeIsolatedDefaults()
        defer { harness.reset() }
        let stats = UsageStats(defaults: harness.defaults, notificationCenter: NotificationCenter())
        let start = makeDate(2025, 1, 1, hour: 12)
        let total = UsageStats.dailyWordsRetention + 5
        for offset in 0..<total {
            let date = Calendar.current.date(byAdding: .day, value: offset, to: start)!
            stats.recordStreaming(wordCount: 1, characterCount: 0, date: date)
        }

        XCTAssertEqual(stats.dailyWords.count, UsageStats.dailyWordsRetention)
        XCTAssertNil(stats.dailyWords["2025-01-01"])
        XCTAssertNil(stats.dailyWords["2025-01-05"])
        XCTAssertNotNil(stats.dailyWords["2025-01-06"])
    }

    func testDayKeyIsZeroPadded() {
        XCTAssertEqual(UsageStats.dayKey(for: makeDate(2026, 3, 4)), "2026-03-04")
    }

    // MARK: - Usage page change detection

    func testSnapshotChangedKeys() {
        var old = UsageSnapshot()
        old.words = 10
        var new = old
        new.words = 20
        new.cleanupFixes = 1
        XCTAssertEqual(new.changedKeys(since: old.comparable), ["words", "cleanupFixes"])
        XCTAssertEqual(new.changedKeys(since: [:]), [])
        XCTAssertEqual(old.changedKeys(since: old.comparable), [])
    }

    private func makeDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
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
