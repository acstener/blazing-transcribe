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
}
