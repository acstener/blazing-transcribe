import Foundation

struct RealtimeFreezeWindowStabilizer {
    let freezeTailWords: Int

    init(freezeTailWords: Int = 5) {
        self.freezeTailWords = max(0, freezeTailWords)
    }

    func stabilize(baseline: String, candidate: String) -> String {
        guard freezeTailWords > 0 else { return candidate }

        let baselineWords = words(in: baseline)
        let candidateWords = words(in: candidate)
        guard baselineWords.count > freezeTailWords else { return candidate }
        guard !candidateWords.isEmpty else { return candidate }

        let frozenCount = baselineWords.count - freezeTailWords
        let frozenPrefix = Array(baselineWords.prefix(frozenCount))

        // Ignore obvious decoder resets that would wipe a long in-progress sentence.
        if candidateWords.count <= 2, frozenCount >= 3 {
            return baseline
        }

        if candidateWords.starts(with: frozenPrefix) {
            return candidate
        }

        let editableTail: [String]
        if candidateWords.count > frozenCount {
            editableTail = Array(candidateWords.dropFirst(frozenCount))
        } else {
            editableTail = Array(candidateWords.suffix(freezeTailWords))
        }

        guard !editableTail.isEmpty else { return baseline }
        let merged = mergeFrozenPrefix(frozenPrefix, editableTail: editableTail)
        return merged.joined(separator: " ")
    }

    private func words(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private func mergeFrozenPrefix(_ frozenPrefix: [String], editableTail: [String]) -> [String] {
        let maxOverlap = min(frozenPrefix.count, editableTail.count)
        if maxOverlap == 0 {
            return frozenPrefix + editableTail
        }

        for overlap in stride(from: maxOverlap, through: 1, by: -1) {
            if Array(frozenPrefix.suffix(overlap)) == Array(editableTail.prefix(overlap)) {
                return frozenPrefix + editableTail.dropFirst(overlap)
            }
        }

        return frozenPrefix + editableTail
    }
}
