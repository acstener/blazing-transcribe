import Foundation

/// Word-level diff between the raw ASR text and the cleaned text of a dictation.
///
/// - Tokens are whitespace-separated words. Punctuation stays attached to its word, so
///   `"um,"` and `"So"` are single tokens.
/// - Comparison is exact: a capitalisation or punctuation change (`"so"` → `"So,"`) shows up
///   as the old token removed and the new token inserted.
/// - Differences in whitespace alone are not changes.
/// - Alignment is a longest-common-subsequence over tokens, after trimming the common
///   prefix and suffix. If the remaining middle is too large for an LCS table
///   (see `maxLCSCells`), the whole middle is reported as one removal plus one insertion.
///
/// `fixCount` is the number of **change runs**: maximal stretches of consecutive removed
/// and/or inserted tokens between two unchanged tokens. Dropping "um" is one fix; replacing
/// "gonna" with "going to" is one fix; dropping "um" at the start and "like" in the middle
/// is two fixes.
struct WordDiff: Equatable {
    enum Kind: Equatable {
        case unchanged
        case removed
        case inserted
    }

    struct Segment: Equatable {
        let kind: Kind
        /// The segment's words, in order.
        let words: [String]

        var text: String { words.joined(separator: " ") }
    }

    /// Ordered segments. Consecutive tokens of the same kind are merged; within a change run,
    /// removals come before insertions.
    let segments: [Segment]

    /// Number of change runs (see type docs).
    let fixCount: Int

    var hasChanges: Bool { fixCount > 0 }

    /// Upper bound on LCS table cells (old middle × new middle) before falling back to a
    /// coarse replace. 4M cells of `Int32` is 16 MB, well beyond any realistic dictation.
    static let maxLCSCells = 4_000_000

    init(from old: String, to new: String) {
        let oldTokens = Self.tokenize(old)
        let newTokens = Self.tokenize(new)
        let ops = Self.operations(old: oldTokens, new: newTokens)
        let segments = Self.segments(from: ops)
        self.segments = segments
        self.fixCount = Self.countChangeRuns(segments)
    }

    // MARK: - Tokenising

    static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
    }

    // MARK: - Alignment

    private static func operations(old: [String], new: [String]) -> [(Kind, String)] {
        // Trim common prefix and suffix; dictation cleanup usually touches a few spots.
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < old.count - prefix,
              suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }

        let oldMid = Array(old[prefix..<(old.count - suffix)])
        let newMid = Array(new[prefix..<(new.count - suffix)])

        var ops: [(Kind, String)] = []
        ops.reserveCapacity(old.count + new.count)
        ops.append(contentsOf: old[0..<prefix].map { (.unchanged, $0) })
        ops.append(contentsOf: middleOperations(old: oldMid, new: newMid))
        ops.append(contentsOf: old[(old.count - suffix)...].map { (.unchanged, $0) })
        return ops
    }

    private static func middleOperations(old: [String], new: [String]) -> [(Kind, String)] {
        let n = old.count
        let m = new.count
        if n == 0 { return new.map { (.inserted, $0) } }
        if m == 0 { return old.map { (.removed, $0) } }
        if n * m > maxLCSCells {
            return old.map { (.removed, $0) } + new.map { (.inserted, $0) }
        }

        // lengths[i][j] = LCS length of old[i...] and new[j...], stored flat.
        let width = m + 1
        var lengths = [Int32](repeating: 0, count: (n + 1) * width)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if old[i] == new[j] {
                    lengths[i * width + j] = lengths[(i + 1) * width + j + 1] + 1
                } else {
                    lengths[i * width + j] = max(lengths[(i + 1) * width + j], lengths[i * width + j + 1])
                }
            }
        }

        var ops: [(Kind, String)] = []
        var i = 0
        var j = 0
        while i < n && j < m {
            if old[i] == new[j] {
                ops.append((.unchanged, old[i]))
                i += 1
                j += 1
            } else if lengths[(i + 1) * width + j] >= lengths[i * width + j + 1] {
                ops.append((.removed, old[i]))
                i += 1
            } else {
                ops.append((.inserted, new[j]))
                j += 1
            }
        }
        while i < n { ops.append((.removed, old[i])); i += 1 }
        while j < m { ops.append((.inserted, new[j])); j += 1 }
        return ops
    }

    // MARK: - Grouping

    private static func segments(from ops: [(Kind, String)]) -> [Segment] {
        var result: [Segment] = []
        var index = 0
        while index < ops.count {
            if ops[index].0 == .unchanged {
                var words: [String] = []
                while index < ops.count, ops[index].0 == .unchanged {
                    words.append(ops[index].1)
                    index += 1
                }
                result.append(Segment(kind: .unchanged, words: words))
            } else {
                // A change run: collect removals and insertions, emit removals first.
                var removed: [String] = []
                var inserted: [String] = []
                while index < ops.count, ops[index].0 != .unchanged {
                    if ops[index].0 == .removed {
                        removed.append(ops[index].1)
                    } else {
                        inserted.append(ops[index].1)
                    }
                    index += 1
                }
                if !removed.isEmpty { result.append(Segment(kind: .removed, words: removed)) }
                if !inserted.isEmpty { result.append(Segment(kind: .inserted, words: inserted)) }
            }
        }
        return result
    }

    private static func countChangeRuns(_ segments: [Segment]) -> Int {
        var count = 0
        var inRun = false
        for segment in segments {
            if segment.kind == .unchanged {
                inRun = false
            } else if !inRun {
                count += 1
                inRun = true
            }
        }
        return count
    }
}
