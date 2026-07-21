import XCTest
@testable import App
import AudioEngine
import Transcription

final class AlwaysOnBatchRescueTests: XCTestCase {
    func testRescueShortAlwaysOnBatchSamplesPadsBorderlineSegment() {
        let samples = Array(repeating: Float(0.25), count: 14_400)

        let rescued = AppDelegate.rescueShortAlwaysOnBatchSamples(
            samples,
            minimumASRSamples: 16_000
        )

        XCTAssertNotNil(rescued)
        XCTAssertEqual(rescued?.count, 16_000)
        XCTAssertEqual(rescued?.prefix(samples.count), samples[0..<samples.count])
        XCTAssertEqual(rescued?.suffix(1_600), Array(repeating: Float(0), count: 1_600))
    }

    func testRescueShortAlwaysOnBatchSamplesSkipsVeryShortSegment() {
        let samples = Array(repeating: Float(0.25), count: 8_000)

        let rescued = AppDelegate.rescueShortAlwaysOnBatchSamples(
            samples,
            minimumASRSamples: 16_000
        )

        XCTAssertNil(rescued)
    }

    func testRescueShortAlwaysOnBatchSamplesSkipsAlreadyLongEnoughSegment() {
        let samples = Array(repeating: Float(0.25), count: 16_000)

        let rescued = AppDelegate.rescueShortAlwaysOnBatchSamples(
            samples,
            minimumASRSamples: 16_000
        )

        XCTAssertNil(rescued)
    }

    func testShouldRetainAlwaysOnBatchCarryoverForStableExtraQuickEmptyResult() {
        XCTAssertTrue(
            AppDelegate.shouldRetainAlwaysOnBatchCarryover(
                source: "always-on",
                profile: .stableExtraQuick,
                error: .noSpeechDetected
            )
        )
    }

    func testShouldRetainAlwaysOnBatchCarryoverForStableExtraQuickShortAudio() {
        XCTAssertTrue(
            AppDelegate.shouldRetainAlwaysOnBatchCarryover(
                source: "always-on",
                profile: .stableExtraQuick,
                error: .audioTooShort
            )
        )
    }

    func testShouldNotRetainAlwaysOnBatchCarryoverForStandardProfile() {
        XCTAssertFalse(
            AppDelegate.shouldRetainAlwaysOnBatchCarryover(
                source: "always-on",
                profile: .standard,
                error: .noSpeechDetected
            )
        )
    }

    func testShouldNotRetainAlwaysOnBatchCarryoverForManualSource() {
        XCTAssertFalse(
            AppDelegate.shouldRetainAlwaysOnBatchCarryover(
                source: "toggle",
                profile: .stableExtraQuick,
                error: .noSpeechDetected
            )
        )
    }

    func testShouldRescueShortBatchSamplesForManualPTT() {
        XCTAssertTrue(
            AppDelegate.shouldRescueShortBatchSamples(
                source: "ptt",
                profile: nil
            )
        )
    }

    func testShouldRescueShortBatchSamplesForToggle() {
        XCTAssertTrue(
            AppDelegate.shouldRescueShortBatchSamples(
                source: "toggle",
                profile: nil
            )
        )
    }

    func testShouldRescueShortBatchSamplesForAlwaysOnStableProfiles() {
        XCTAssertTrue(
            AppDelegate.shouldRescueShortBatchSamples(
                source: "always-on",
                profile: .standard
            )
        )
        XCTAssertTrue(
            AppDelegate.shouldRescueShortBatchSamples(
                source: "always-on",
                profile: .stableExtraQuick
            )
        )
    }

    func testShouldNotRescueShortBatchSamplesForUnsupportedSourceOrProfile() {
        XCTAssertFalse(
            AppDelegate.shouldRescueShortBatchSamples(
                source: "always-on",
                profile: .aggressiveParakeet
            )
        )
        XCTAssertFalse(
            AppDelegate.shouldRescueShortBatchSamples(
                source: "unknown",
                profile: nil
            )
        )
    }

    func testShouldPadManualStopDecoderTailForManualSources() {
        XCTAssertTrue(AppDelegate.shouldPadManualStopDecoderTail(source: "ptt"))
        XCTAssertTrue(AppDelegate.shouldPadManualStopDecoderTail(source: "toggle"))
        XCTAssertTrue(AppDelegate.shouldPadManualStopDecoderTail(source: "retry"))
    }

    func testShouldNotPadManualStopDecoderTailForAlwaysOn() {
        XCTAssertFalse(AppDelegate.shouldPadManualStopDecoderTail(source: "always-on"))
        XCTAssertFalse(AppDelegate.shouldPadManualStopDecoderTail(source: "unknown"))
    }

    func testManualStopDecoderTailPadIsHalfASecond() {
        XCTAssertEqual(AppDelegate.manualStopDecoderTailPadSamples, 8_000)
    }

    func testMergeAlwaysOnBatchSamplesAppendsCarryoverAheadOfNextChunk() {
        let carryover: [Float] = [0.1, 0.2, 0.3]
        let next: [Float] = [0.4, 0.5]

        let merged = AppDelegate.mergeAlwaysOnBatchSamples(
            carryover: carryover,
            next: next
        )

        XCTAssertEqual(merged, [0.1, 0.2, 0.3, 0.4, 0.5])
    }
}
