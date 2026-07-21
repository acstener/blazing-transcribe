import XCTest
@testable import App

final class ProvisionalTextMutationPlanTests: XCTestCase {
    func testBuildReplacesOnlyChangedSuffix() {
        let plan = ProvisionalTextMutationPlan.build(from: "hello wor", to: "hello world")

        XCTAssertEqual(plan.commonPrefixUTF16Count, 9)
        XCTAssertEqual(plan.replacedUTF16Count, 0)
        XCTAssertEqual(plan.replacementSuffix, "ld")
    }

    func testBuildHandlesShrinkingSuffix() {
        let plan = ProvisionalTextMutationPlan.build(from: "deployments", to: "deploy")

        XCTAssertEqual(plan.commonPrefixUTF16Count, 6)
        XCTAssertEqual(plan.replacedUTF16Count, 5)
        XCTAssertEqual(plan.replacementSuffix, "")
    }

    func testBuildCountsEmojiInUtf16() {
        let plan = ProvisionalTextMutationPlan.build(from: "ship 🚀 now", to: "ship 🚀 later")

        XCTAssertEqual(plan.commonPrefixUTF16Count, "ship 🚀 ".utf16.count)
        XCTAssertEqual(plan.replacedUTF16Count, "now".utf16.count)
        XCTAssertEqual(plan.replacementSuffix, "later")
    }

    func testBuildHandlesFinalCommitSpaceWithoutReplacingWholePhrase() {
        let plan = ProvisionalTextMutationPlan.build(from: "hello boss", to: "hello boss ")

        XCTAssertEqual(plan.commonPrefixUTF16Count, "hello boss".utf16.count)
        XCTAssertEqual(plan.replacedUTF16Count, 0)
        XCTAssertEqual(plan.replacementSuffix, " ")
    }

    func testBuildHandlesFinalCorrectionNearTheEnd() {
        let plan = ProvisionalTextMutationPlan.build(from: "this is very sick", to: "this is very slick ")

        XCTAssertEqual(plan.commonPrefixUTF16Count, "this is very s".utf16.count)
        XCTAssertEqual(plan.replacedUTF16Count, "ick".utf16.count)
        XCTAssertEqual(plan.replacementSuffix, "lick ")
    }
}
