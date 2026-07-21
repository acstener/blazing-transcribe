import XCTest
@testable import Transcription

final class TextPostProcessingTests: XCTestCase {
    func testRegexFillerCleanupRemovesFillersAndPreservesCapitalization() {
        let input = "um hello. uh this is a test"

        let cleaned = applyRegexFillerCleanup(input)

        XCTAssertEqual(cleaned, "Hello. This is a test")
    }

    func testRegexFillerCleanupRemovesStutters() {
        let input = "I th- think we should ship it"

        let cleaned = applyRegexFillerCleanup(input)

        XCTAssertEqual(cleaned, "I think we should ship it")
    }

    func testRegexFillerCleanupAverageLatencyStaysSubMillisecond() {
        let samples = [
            "um this is a quick partial",
            "uh hello there how are you doing today",
            "I th- think this path should stay fast",
            "well this one is already clean and should mostly pass through",
        ]
        let iterations = 10_000
        var sink = 0

        let startedAt = CFAbsoluteTimeGetCurrent()
        for index in 0..<iterations {
            sink += applyRegexFillerCleanup(samples[index % samples.count]).count
        }
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
        let averageUs = (elapsedMs * 1000) / Double(iterations)

        XCTAssertGreaterThan(sink, 0)
        XCTAssertLessThan(averageUs, 1_000)
    }
}
