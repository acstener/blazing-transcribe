import XCTest
@testable import App

final class RealtimeFreezeWindowStabilizerTests: XCTestCase {
    func testStabilize_returnsCandidateWhenBaselineShorterThanWindow() {
        let stabilizer = RealtimeFreezeWindowStabilizer(freezeTailWords: 5)
        let baseline = "hello world"
        let candidate = "hello world again"

        let result = stabilizer.stabilize(baseline: baseline, candidate: candidate)

        XCTAssertEqual(result, candidate)
    }

    func testStabilize_freezesPrefixWhenEarlyWordsChange() {
        let stabilizer = RealtimeFreezeWindowStabilizer(freezeTailWords: 3)
        let baseline = "I think we should ship this version first"
        let candidate = "I think we must ship this version first"

        let result = stabilizer.stabilize(baseline: baseline, candidate: candidate)

        XCTAssertEqual(result, "I think we should ship this version first")
        XCTAssertFalse(result.contains("must"))
    }

    func testStabilize_preservesGrowthWhileKeepingFrozenPrefix() {
        let stabilizer = RealtimeFreezeWindowStabilizer(freezeTailWords: 3)
        let baseline = "I think we should ship this version"
        let candidate = "I think we must ship this version right now"

        let result = stabilizer.stabilize(baseline: baseline, candidate: candidate)

        XCTAssertEqual(result, "I think we should ship this version right now")
    }

    func testStabilize_ignoresTinyResetWhenSentenceAlreadyLong() {
        let stabilizer = RealtimeFreezeWindowStabilizer(freezeTailWords: 3)
        let baseline = "I think we should ship this version right now"
        let candidate = "hello there"

        let result = stabilizer.stabilize(baseline: baseline, candidate: candidate)

        XCTAssertEqual(result, baseline)
    }

    func testStabilize_allowsTailUpdatesWhenFrozenPrefixStillMatches() {
        let stabilizer = RealtimeFreezeWindowStabilizer(freezeTailWords: 3)
        let baseline = "I think we should ship this version"
        let candidate = "I think we should ship that version now"

        let result = stabilizer.stabilize(baseline: baseline, candidate: candidate)

        XCTAssertEqual(result, candidate)
    }
}
