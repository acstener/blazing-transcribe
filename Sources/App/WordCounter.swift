import Foundation

enum WordCounter {
    static func countWords(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }

        var count = 0
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords, .localized]
        ) { _, _, _, _ in
            count += 1
        }
        return count
    }

    /// False for transcripts with nothing a person said — e.g. the ASR hearing a murmur
    /// as "Mm." and filler cleanup reducing it to "." (seen as ~5% of cleaned dictations).
    static func hasSpokenContent(_ text: String) -> Bool {
        text.rangeOfCharacter(from: .alphanumerics) != nil
    }
}
