import Foundation

extension Notification.Name {
    static let usageStatsDidChange = Notification.Name("UsageStatsDidChange")
}

/// A word-count landmark shown on the Usage page and celebrated once on Home.
struct UsageMilestone: Equatable, Sendable {
    let words: Int
    let name: String
    let emoji: String

    static let wordsPerPage = 250

    /// Ascending. Names line up with `UsageStats.funEquivalent`.
    static let all: [UsageMilestone] = [
        UsageMilestone(words: 500, name: "a short blog post", emoji: "\u{270D}\u{FE0F}"),
        UsageMilestone(words: 750, name: "a blog post", emoji: "\u{1F4DD}"),
        UsageMilestone(words: 1_500, name: "a college essay", emoji: "\u{1F393}"),
        UsageMilestone(words: 3_000, name: "a short story", emoji: "\u{1F4DC}"),
        UsageMilestone(words: 6_000, name: "a long report", emoji: "\u{1F4C4}"),
        UsageMilestone(words: 15_000, name: "a novella", emoji: "\u{1F4D8}"),
        UsageMilestone(words: 50_000, name: "a short novel", emoji: "\u{1F4D6}"),
        UsageMilestone(words: 80_000, name: "a full novel", emoji: "\u{1F4DA}"),
        UsageMilestone(words: 250_000, name: "an epic saga", emoji: "\u{1F409}"),
        UsageMilestone(words: 1_000_000, name: "a million words", emoji: "\u{1F525}"),
    ]

    static func current(forWords words: Int) -> UsageMilestone? {
        all.last { $0.words <= words }
    }

    static func next(forWords words: Int) -> UsageMilestone? {
        all.first { $0.words > words }
    }

    /// 0...1 progress from the previous milestone (or zero) towards the next one. 1 when all passed.
    static func progress(forWords words: Int) -> Double {
        guard let next = next(forWords: words) else { return 1 }
        let floor = current(forWords: words)?.words ?? 0
        let span = Double(next.words - floor)
        return min(1, max(0, Double(words - floor) / span))
    }

    /// e.g. "38 pages to a full novel", or "120 words to a blog post" when under a page away.
    static func remainingText(forWords words: Int) -> String? {
        guard let next = next(forWords: words) else { return nil }
        let remaining = next.words - words
        if remaining >= wordsPerPage {
            let pages = Int((Double(remaining) / Double(wordsPerPage)).rounded(.up))
            return "\(pages) \(pages == 1 ? "page" : "pages") to \(next.name)"
        }
        return "\(remaining) \(remaining == 1 ? "word" : "words") to \(next.name)"
    }

    var celebrationText: String { "You just passed \(name) \(emoji)" }
}

final class UsageStats {
    static let shared = UsageStats()

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter

    // MARK: - Keys

    private enum Key {
        static let totalWords = "stats.totalWords"
        static let totalCharacters = "stats.totalCharacters"
        static let totalUtterances = "stats.totalUtterances"
        static let totalTranscriptionSeconds = "stats.totalTranscriptionSeconds"
        static let totalSpeechSeconds = "stats.totalSpeechSeconds"
        static let firstUseDate = "stats.firstUseDate"
        static let totalCleanupFixes = "stats.totalCleanupFixes"
        static let dailyWords = "stats.dailyWords"
        static let celebratedMilestones = "stats.celebratedMilestones"
        static let lastViewedValues = "stats.lastViewedValues"
    }

    /// How many days of per-day word counts to keep (a little over a year, for a future heatmap).
    static let dailyWordsRetention = 400

    // MARK: - Persisted Counters

    var totalWords: Int {
        defaults.integer(forKey: Key.totalWords)
    }

    var totalCharacters: Int {
        defaults.integer(forKey: Key.totalCharacters)
    }

    var totalUtterances: Int {
        defaults.integer(forKey: Key.totalUtterances)
    }

    var totalTranscriptionSeconds: Double {
        defaults.double(forKey: Key.totalTranscriptionSeconds)
    }

    var totalSpeechSeconds: Double {
        defaults.double(forKey: Key.totalSpeechSeconds)
    }

    /// Total fixes made by cleanup (change runs in the raw → cleaned word diff), summed over
    /// every saved history record that has a diff. Feeds the Usage page.
    var totalCleanupFixes: Int {
        defaults.integer(forKey: Key.totalCleanupFixes)
    }

    var firstUseDate: Date? {
        let ts = defaults.double(forKey: Key.firstUseDate)
        return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
    }

    // MARK: - Derived Stats

    /// Equivalent pages of text (250 words per page)
    var pagesOfText: Double {
        Double(totalWords) / 250.0
    }

    /// Time saved vs typing at 40 WPM (in seconds)
    var timeSavedVsTyping: Double {
        let typingSeconds = Double(totalWords) / 40.0 * 60.0
        return typingSeconds - totalSpeechSeconds
    }

    /// Keypresses saved vs hold-to-talk tools like Wispr Flow.
    /// 2 per utterance: hold key to start + release key to stop.
    /// (Wispr Flow auto-pastes, so no Cmd+V/Enter needed.)
    /// Conservative: treats each VAD utterance as a separate dictation.
    var keypressesSaved: Int {
        totalUtterances * 2
    }

    /// Time saved from not waiting for cloud processing.
    /// Wispr Flow targets ~700ms e2e; real-world reports 0.5–1.5s.
    /// We use 1.0s — the conservative middle of that range.
    var timeSavedVsShortcutTools: Double {
        Double(totalUtterances) * 1.0
    }

    /// Average transcription time per utterance (in seconds)
    var avgTranscriptionTime: Double {
        guard totalUtterances > 0 else { return 0 }
        return totalTranscriptionSeconds / Double(totalUtterances)
    }

    /// Speaking rate in words per minute
    var speakingWPM: Double {
        guard totalSpeechSeconds > 0 else { return 0 }
        return Double(totalWords) / (totalSpeechSeconds / 60.0)
    }

    /// Fun real-world equivalent for the word count
    var funEquivalent: String {
        let w = totalWords
        switch w {
        case ..<10:
            return "a sticky note"
        case ..<50:
            return "a text message"
        case ..<140:
            return "a long text message"
        case ..<280:
            return "\(w / 35) tweets"
        case ..<500:
            return "\(w / 35) tweets"
        case ..<750:
            return "a short blog post"
        case ..<1500:
            return "a blog post"
        case ..<3000:
            return "a college essay"
        case ..<6000:
            return "a short story"
        case ..<15000:
            return "\(w / 250) pages \u{2014} a long report"
        case ..<50000:
            return "\(w / 250) pages \u{2014} a novella"
        case ..<80000:
            return "\(w / 250) pages \u{2014} a short novel"
        default:
            return "\(w / 250) pages \u{2014} a full novel"
        }
    }

    /// Weeks since first use
    var weeksActive: Int {
        guard let firstUse = firstUseDate else { return 0 }
        let days = Calendar.current.dateComponents([.day], from: firstUse, to: Date()).day ?? 0
        return max(1, days / 7)
    }

    /// Formatted total words (e.g. "1.2K", "110.1K")
    var formattedTotalWords: String {
        let w = totalWords
        if w >= 100_000 {
            return String(format: "%.1fK", Double(w) / 1000.0)
        } else if w >= 1_000 {
            return String(format: "%.1fK", Double(w) / 1000.0)
        } else {
            return "\(w)"
        }
    }

    // MARK: - Recording

    func record(
        wordCount: Int,
        characterCount: Int,
        transcriptionDuration: Double,
        speechDuration: Double,
        date: Date = Date()
    ) {
        ensureFirstUseDate()
        seedCelebratedMilestonesIfNeeded()
        addDailyWords(wordCount, on: date)
        defaults.set(totalWords + wordCount, forKey: Key.totalWords)
        defaults.set(totalCharacters + characterCount, forKey: Key.totalCharacters)
        defaults.set(totalUtterances + 1, forKey: Key.totalUtterances)
        defaults.set(totalTranscriptionSeconds + transcriptionDuration, forKey: Key.totalTranscriptionSeconds)
        defaults.set(totalSpeechSeconds + speechDuration, forKey: Key.totalSpeechSeconds)
        notifyDidChange()
    }

    func recordStreaming(wordCount: Int, characterCount: Int, date: Date = Date()) {
        ensureFirstUseDate()
        seedCelebratedMilestonesIfNeeded()
        addDailyWords(wordCount, on: date)
        defaults.set(totalWords + wordCount, forKey: Key.totalWords)
        defaults.set(totalCharacters + characterCount, forKey: Key.totalCharacters)
        notifyDidChange()
    }

    func recordCleanupFixes(_ count: Int) {
        guard count > 0 else { return }
        defaults.set(totalCleanupFixes + count, forKey: Key.totalCleanupFixes)
        notifyDidChange()
    }

    func reset() {
        defaults.removeObject(forKey: Key.totalWords)
        defaults.removeObject(forKey: Key.totalCharacters)
        defaults.removeObject(forKey: Key.totalUtterances)
        defaults.removeObject(forKey: Key.totalTranscriptionSeconds)
        defaults.removeObject(forKey: Key.totalSpeechSeconds)
        defaults.removeObject(forKey: Key.totalCleanupFixes)
        defaults.removeObject(forKey: Key.dailyWords)
        defaults.removeObject(forKey: Key.lastViewedValues)
        // Totals are zero again, so every milestone can be celebrated afresh.
        defaults.set([Int](), forKey: Key.celebratedMilestones)
        defaults.set(Date().timeIntervalSince1970, forKey: Key.firstUseDate)
        notifyDidChange()
    }

    // MARK: - Per-day words

    /// Words dictated per local calendar day, keyed `yyyy-MM-dd`. Kept for a future heatmap.
    var dailyWords: [String: Int] {
        (defaults.dictionary(forKey: Key.dailyWords) as? [String: Int]) ?? [:]
    }

    func words(on date: Date) -> Int {
        dailyWords[Self.dayKey(for: date)] ?? 0
    }

    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func addDailyWords(_ count: Int, on date: Date) {
        guard count > 0 else { return }
        var days = dailyWords
        days[Self.dayKey(for: date), default: 0] += count
        if days.count > Self.dailyWordsRetention {
            // Keys are zero-padded ISO dates, so lexical order is chronological.
            for key in days.keys.sorted().prefix(days.count - Self.dailyWordsRetention) {
                days.removeValue(forKey: key)
            }
        }
        defaults.set(days, forKey: Key.dailyWords)
    }

    // MARK: - Milestones

    /// The milestone most recently passed, if any.
    var currentMilestone: UsageMilestone? { UsageMilestone.current(forWords: totalWords) }

    /// The next milestone to reach, if any are left.
    var nextMilestone: UsageMilestone? { UsageMilestone.next(forWords: totalWords) }

    /// Word thresholds of milestones that have already been celebrated on Home.
    var celebratedMilestoneWords: Set<Int> {
        Set((defaults.array(forKey: Key.celebratedMilestones) as? [Int]) ?? [])
    }

    /// The highest passed milestone that hasn't been celebrated yet. Users who already had
    /// words before milestones existed are seeded silently, so they never get a stale toast.
    var pendingCelebration: UsageMilestone? {
        seedCelebratedMilestonesIfNeeded()
        let celebrated = celebratedMilestoneWords
        return UsageMilestone.all
            .filter { $0.words <= totalWords && !celebrated.contains($0.words) }
            .last
    }

    /// Marks `milestone` and every milestone below it as celebrated, so crossing several at once
    /// produces a single toast.
    func markCelebrated(_ milestone: UsageMilestone) {
        var celebrated = celebratedMilestoneWords
        for m in UsageMilestone.all where m.words <= milestone.words {
            celebrated.insert(m.words)
        }
        defaults.set(celebrated.sorted(), forKey: Key.celebratedMilestones)
    }

    private func seedCelebratedMilestonesIfNeeded() {
        guard defaults.object(forKey: Key.celebratedMilestones) == nil else { return }
        let reached = UsageMilestone.all.filter { $0.words <= totalWords }.map(\.words)
        defaults.set(reached, forKey: Key.celebratedMilestones)
    }

    // MARK: - Last viewed (Usage page change flash)

    /// Metric values as they were the last time the Usage page was viewed. Empty if never viewed.
    var lastViewedValues: [String: Double] {
        (defaults.dictionary(forKey: Key.lastViewedValues) as? [String: Double]) ?? [:]
    }

    func setLastViewedValues(_ values: [String: Double]) {
        defaults.set(values, forKey: Key.lastViewedValues)
    }

    // MARK: - Formatting

    static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds > 0 else { return "0s" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return "\(h)h \(m)m"
        } else if m > 0 {
            return "\(m)m \(s)s"
        } else {
            return "\(s)s"
        }
    }

    // MARK: - Private

    private func ensureFirstUseDate() {
        if defaults.double(forKey: Key.firstUseDate) == 0 {
            defaults.set(Date().timeIntervalSince1970, forKey: Key.firstUseDate)
        }
    }

    private func notifyDidChange() {
        notificationCenter.post(name: .usageStatsDidChange, object: self)
    }

    init(defaults: UserDefaults = .standard, notificationCenter: NotificationCenter = .default) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
    }
}
