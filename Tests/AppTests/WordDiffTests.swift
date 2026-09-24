import XCTest
@testable import App

final class WordDiffTests: XCTestCase {
    private typealias Segment = WordDiff.Segment

    func testFillersRemoved() {
        let diff = WordDiff(from: "um so I think like we should ship it", to: "so I think we should ship it")
        XCTAssertEqual(diff.segments, [
            Segment(kind: .removed, words: ["um"]),
            Segment(kind: .unchanged, words: ["so", "I", "think"]),
            Segment(kind: .removed, words: ["like"]),
            Segment(kind: .unchanged, words: ["we", "should", "ship", "it"]),
        ])
        XCTAssertEqual(diff.fixCount, 2)
        XCTAssertTrue(diff.hasChanges)
    }

    func testPunctuationStaysAttachedAndCapitalisationIsAChange() {
        let diff = WordDiff(from: "um, so we ship it", to: "So we ship it.")
        XCTAssertEqual(diff.segments, [
            Segment(kind: .removed, words: ["um,", "so"]),
            Segment(kind: .inserted, words: ["So"]),
            Segment(kind: .unchanged, words: ["we", "ship"]),
            Segment(kind: .removed, words: ["it"]),
            Segment(kind: .inserted, words: ["it."]),
        ])
        XCTAssertEqual(diff.fixCount, 2)
    }

    func testReplacementRunCountsAsOneFix() {
        let diff = WordDiff(from: "we are gonna win", to: "we are going to win")
        XCTAssertEqual(diff.segments, [
            Segment(kind: .unchanged, words: ["we", "are"]),
            Segment(kind: .removed, words: ["gonna"]),
            Segment(kind: .inserted, words: ["going", "to"]),
            Segment(kind: .unchanged, words: ["win"]),
        ])
        XCTAssertEqual(diff.fixCount, 1)
    }

    func testIdenticalTextHasNoChanges() {
        let diff = WordDiff(from: "Hello there, world.", to: "Hello there, world.")
        XCTAssertEqual(diff.segments, [Segment(kind: .unchanged, words: ["Hello", "there,", "world."])])
        XCTAssertEqual(diff.fixCount, 0)
        XCTAssertFalse(diff.hasChanges)
    }

    func testWhitespaceOnlyDifferencesAreNotChanges() {
        let diff = WordDiff(from: "hello   world\n", to: " hello world")
        XCTAssertFalse(diff.hasChanges)
    }

    func testEmptyStrings() {
        let bothEmpty = WordDiff(from: "", to: "")
        XCTAssertEqual(bothEmpty.segments, [])
        XCTAssertEqual(bothEmpty.fixCount, 0)

        let allRemoved = WordDiff(from: "um uh", to: "")
        XCTAssertEqual(allRemoved.segments, [Segment(kind: .removed, words: ["um", "uh"])])
        XCTAssertEqual(allRemoved.fixCount, 1)

        let allInserted = WordDiff(from: "  ", to: "Hello.")
        XCTAssertEqual(allInserted.segments, [Segment(kind: .inserted, words: ["Hello."])])
        XCTAssertEqual(allInserted.fixCount, 1)
    }

    func testSegmentTextJoinsWordsWithSpaces() {
        XCTAssertEqual(Segment(kind: .unchanged, words: ["a", "b,", "c"]).text, "a b, c")
    }

    func testLongTextPerformanceSanity() {
        let words = (0..<1_500).map { "word\($0 % 97)" }
        var raw: [String] = []
        for (index, word) in words.enumerated() {
            raw.append(word)
            if index % 10 == 0 { raw.append("um") }
        }
        let start = Date()
        let diff = WordDiff(from: raw.joined(separator: " "), to: words.joined(separator: " "))
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(diff.fixCount, 150)
        XCTAssertTrue(diff.segments.filter { $0.kind == .inserted }.isEmpty)
        XCTAssertLessThan(elapsed, 2.0)
    }

    func testOversizedMiddleFallsBackToCoarseReplace() {
        let count = Int(Double(WordDiff.maxLCSCells).squareRoot()) + 10
        let old = (0..<count).map { "a\($0)" }.joined(separator: " ")
        let new = (0..<count).map { "b\($0)" }.joined(separator: " ")
        let diff = WordDiff(from: "start " + old + " end", to: "start " + new + " end")
        XCTAssertEqual(diff.segments.map(\.kind), [.unchanged, .removed, .inserted, .unchanged])
        XCTAssertEqual(diff.fixCount, 1)
    }
}
