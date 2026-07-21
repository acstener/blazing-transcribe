import Foundation

/// Runs the fine-tuned LLM cleanup in the background during realtime streaming.
///
/// Key design: only cleans a "stable prefix" — drops the last few words which are
/// still being spoken and may change. This prevents the LLM from hallucinating
/// completions on partial sentences.
final class RealtimeLLMShadowRunner {

    /// Called on main thread with (cleanedText, rawTextSentToLLM) when LLM returns.
    var onCleanedText: ((String, String) -> Void)?

    private var lastInputText = ""
    private var lastCleanedText = ""
    private var lastCleanupInputText = ""
    private var cleanupInFlight = false
    private var cooldownTimer: DispatchWorkItem?
    private let cooldownInterval: TimeInterval = 0.4
    private let minWordCount = 5            // Need enough words before first cleanup
    private let trailingWordsToSkip = 3     // Don't clean the last 3 words (still being spoken)
    private(set) var runCount = 0

    /// Update with the latest streamed text. Schedules LLM cleanup on the
    /// stable prefix (everything except the last few words).
    func update(streamedText: String) {
        let trimmed = streamedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != lastInputText else { return }
        lastInputText = trimmed

        let words = trimmed.split(separator: " ")
        guard words.count >= minWordCount else { return }
        guard !cleanupInFlight else { return }

        // Extract stable prefix — drop trailing words that are still being spoken
        let stableWords = Array(words.dropLast(trailingWordsToSkip))
        guard !stableWords.isEmpty else { return }
        let stablePrefix = stableWords.joined(separator: " ")

        guard stablePrefix != lastCleanupInputText else { return }

        cooldownTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.runCleanup(stablePrefix)
        }
        cooldownTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + cooldownInterval, execute: work)
    }

    /// Run a final cleanup pass on the COMPLETE text (called at EOU — no trailing words to skip).
    func finalCleanup(_ text: String, completion: @escaping (String) -> Void) {
        cooldownTimer?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(text)
            return
        }
        print("[LLMShadow] Final cleanup: \"\(trimmed.prefix(60))\"")
        Task {
            let start = Date()
            let cleaned = await LLMCleanupService.shared.cleanup(trimmed)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            print("[LLMShadow] Final done (\(ms)ms): \"\(cleaned.prefix(60))\"")
            await MainActor.run {
                completion(cleaned)
            }
        }
    }

    /// Reset state for a new utterance.
    func reset() {
        cooldownTimer?.cancel()
        if runCount > 0 {
            print("[LLMShadow] Session reset (\(runCount) shadow cleanups)")
        }
        lastInputText = ""
        lastCleanedText = ""
        lastCleanupInputText = ""
        cleanupInFlight = false
        runCount = 0
    }

    private func runCleanup(_ stablePrefix: String) {
        guard !cleanupInFlight else { return }
        cleanupInFlight = true
        lastCleanupInputText = stablePrefix
        runCount += 1
        let runID = runCount
        print("[LLMShadow] Run #\(runID): \"\(stablePrefix.prefix(50))\" (\(stablePrefix.split(separator: " ").count) words)")

        Task {
            let start = Date()
            let cleaned = await LLMCleanupService.shared.cleanup(stablePrefix)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.cleanupInFlight = false

                // Guard: reject if LLM output has more words than input (added content).
                // Allow same count or fewer (filler removal, contraction merging).
                // Spelling corrections (speeching→speaking) are fine — same word count.
                let inCount = stablePrefix.split(separator: " ").count
                let outCount = cleaned.split(separator: " ").count
                guard outCount <= inCount else {
                    print("[LLMShadow] Run #\(runID) rejected (\(ms)ms): output has more words (\(outCount) vs \(inCount))")
                    self.retriggerIfNeeded(afterProcessing: stablePrefix)
                    return
                }

                if cleaned != self.lastCleanedText {
                    print("[LLMShadow] Run #\(runID) done (\(ms)ms): \"\(cleaned.prefix(50))\"")
                    self.lastCleanedText = cleaned
                    self.onCleanedText?(cleaned, stablePrefix)
                } else {
                    print("[LLMShadow] Run #\(runID) no-op (\(ms)ms)")
                }

                self.retriggerIfNeeded(afterProcessing: stablePrefix)
            }
        }
    }

    private func retriggerIfNeeded(afterProcessing processedText: String) {
        let current = lastInputText
        let words = current.split(separator: " ")
        guard words.count >= minWordCount else { return }

        let stableWords = Array(words.dropLast(trailingWordsToSkip))
        guard !stableWords.isEmpty else { return }
        let stablePrefix = stableWords.joined(separator: " ")

        guard stablePrefix != processedText, stablePrefix != lastCleanupInputText else { return }

        print("[LLMShadow] Re-triggering: stable prefix grew")
        runCleanup(stablePrefix)
    }
}
