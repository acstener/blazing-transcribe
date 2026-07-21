import Foundation

/// Detects sentence boundaries in streaming text and runs LLM cleanup on
/// each completed sentence, replacing it in-place while new text continues.
final class RealtimeSentenceChunker {

    /// Called on main thread with (fullCleanedText, fullRawText) after a sentence is cleaned.
    var onSentenceCleaned: ((String, String) -> Void)?

    private var cleanedPrefix = ""
    private var cleanupInFlight = false
    private var sentencesProcessed = 0
    private let sentenceEndPattern = try! NSRegularExpression(pattern: "[.!?]\\s", options: [])

    /// Update with the latest streamed text. If a new sentence boundary is found
    /// after the already-cleaned prefix, runs LLM on that sentence.
    func update(streamedText: String) {
        let trimmed = streamedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > cleanedPrefix.count else { return }
        guard !cleanupInFlight else { return }

        let pendingStart = cleanedPrefix.count
        let pending = String(trimmed.dropFirst(pendingStart))
        let range = NSRange(pending.startIndex..., in: pending)
        guard let match = sentenceEndPattern.firstMatch(in: pending, range: range) else { return }

        let boundaryEnd = match.range.location + match.range.length
        let sentenceToClean = String(pending.prefix(boundaryEnd)).trimmingCharacters(in: .whitespaces)
        guard !sentenceToClean.isEmpty else { return }

        cleanupInFlight = true
        sentencesProcessed += 1
        let sentenceID = sentencesProcessed
        let prefixBeforeSentence = cleanedPrefix
        print("[SentenceChunker] Sentence #\(sentenceID) detected: \"\(sentenceToClean.prefix(50))\"")

        Task {
            let start = Date()
            let cleaned = await LLMCleanupService.shared.cleanup(sentenceToClean)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.cleanupInFlight = false

                let newCleanedPrefix = prefixBeforeSentence.isEmpty
                    ? cleaned
                    : prefixBeforeSentence + " " + cleaned
                self.cleanedPrefix = newCleanedPrefix

                // Merge: cleaned prefix + whatever new raw text arrived since
                let currentStreamed = self.lastKnownStreamedText
                let remainingRaw: String
                if currentStreamed.count > pendingStart + boundaryEnd {
                    remainingRaw = String(currentStreamed.dropFirst(pendingStart + boundaryEnd))
                } else {
                    remainingRaw = ""
                }
                let fullText = (newCleanedPrefix + remainingRaw).trimmingCharacters(in: .whitespaces)
                let changed = cleaned != sentenceToClean
                print("[SentenceChunker] Sentence #\(sentenceID) done (\(ms)ms) changed=\(changed): \"\(cleaned.prefix(50))\"")
                self.onSentenceCleaned?(fullText, currentStreamed)
            }
        }
    }

    private var lastKnownStreamedText = ""

    func trackStreamedText(_ text: String) {
        lastKnownStreamedText = text
    }

    /// Run a final cleanup pass on any remaining uncleaned text.
    func finalCleanup(_ text: String, completion: @escaping (String) -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(text)
            return
        }

        if !cleanedPrefix.isEmpty, trimmed.hasPrefix(cleanedPrefix) {
            let remaining = String(trimmed.dropFirst(cleanedPrefix.count)).trimmingCharacters(in: .whitespaces)
            if remaining.isEmpty {
                print("[SentenceChunker] Final: all sentences already cleaned")
                completion(cleanedPrefix)
                return
            }
            print("[SentenceChunker] Final: cleaning remaining \"\(remaining.prefix(40))...\"")
            Task {
                let cleaned = await LLMCleanupService.shared.cleanup(remaining)
                let full = self.cleanedPrefix + " " + cleaned
                await MainActor.run { completion(full) }
            }
        } else {
            print("[SentenceChunker] Final: cleaning full text \"\(trimmed.prefix(40))...\"")
            Task {
                let cleaned = await LLMCleanupService.shared.cleanup(trimmed)
                await MainActor.run { completion(cleaned) }
            }
        }
    }

    func reset() {
        if sentencesProcessed > 0 {
            print("[SentenceChunker] Session reset (\(sentencesProcessed) sentences processed)")
        }
        cleanedPrefix = ""
        cleanupInFlight = false
        lastKnownStreamedText = ""
        sentencesProcessed = 0
    }
}
