import Foundation

extension Notification.Name {
    static let usageStatsDidChange = Notification.Name("UsageStatsDidChange")
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
    }

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

    func record(wordCount: Int, characterCount: Int, transcriptionDuration: Double, speechDuration: Double) {
        ensureFirstUseDate()
        defaults.set(totalWords + wordCount, forKey: Key.totalWords)
        defaults.set(totalCharacters + characterCount, forKey: Key.totalCharacters)
        defaults.set(totalUtterances + 1, forKey: Key.totalUtterances)
        defaults.set(totalTranscriptionSeconds + transcriptionDuration, forKey: Key.totalTranscriptionSeconds)
        defaults.set(totalSpeechSeconds + speechDuration, forKey: Key.totalSpeechSeconds)
        notifyDidChange()
    }

    func recordStreaming(wordCount: Int, characterCount: Int) {
        ensureFirstUseDate()
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
        defaults.set(Date().timeIntervalSince1970, forKey: Key.firstUseDate)
        notifyDidChange()
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
