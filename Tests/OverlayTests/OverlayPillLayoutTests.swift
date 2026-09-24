import XCTest
@testable import Overlay

final class OverlayPillQuantizationTests: XCTestCase {
    func testWidthsRoundUpToEightPointSteps() {
        XCTAssertEqual(OverlayPillMetrics.quantize(121), 128)
        XCTAssertEqual(OverlayPillMetrics.quantize(128), 128)
        XCTAssertEqual(OverlayPillMetrics.quantize(128.5), 136)
    }

    func testWidthsClampToPillBounds() {
        XCTAssertEqual(OverlayPillMetrics.quantize(3), OverlayPillMetrics.minWidth)
        XCTAssertEqual(OverlayPillMetrics.quantize(10_000), OverlayPillMetrics.maxWidth)
    }

    func testStageFitsTheLargestPillWithShadowRoom() {
        let stage = OverlayPillMetrics.stageSize
        XCTAssertGreaterThanOrEqual(stage.width, OverlayPillMetrics.maxWidth + 2 * OverlayPillMetrics.stagePadding)
        XCTAssertGreaterThanOrEqual(stage.height, OverlayPillMetrics.twoLineHeight + 2 * OverlayPillMetrics.stagePadding)
    }
}

final class OverlayPillLayoutTests: XCTestCase {
    private func layout(
        _ status: OverlayPanel.Status,
        style: OverlayVisualStyle = .black,
        nativeGlass: Bool = false,
        textWidth: CGFloat = 60
    ) -> OverlayPillLayout {
        OverlayPillMetrics.layout(
            for: OverlayPillPresentation(status: status),
            visualStyle: style,
            nativeGlass: nativeGlass,
            measure: { _ in textWidth }
        )
    }

    func testEveryLayoutIsQuantised() {
        let statuses: [OverlayPanel.Status] = [
            .idle, .listening, .arming, .recording, .transcribing,
            .partial("hello there", confirmed: false), .result("a b c"), .error("Nope"),
        ]
        for status in statuses {
            for nativeGlass in [false, true] {
                let width = layout(status, nativeGlass: nativeGlass).width
                XCTAssertEqual(width.truncatingRemainder(dividingBy: OverlayPillMetrics.widthQuantum), 0)
            }
        }
    }

    func testLongStreamingTextStaysOneLineAtMaxWidth() {
        let result = layout(.partial("long", confirmed: false), textWidth: 2_000)
        XCTAssertEqual(result.width, OverlayPillMetrics.maxWidth)
        XCTAssertEqual(result.height, OverlayPillMetrics.singleLineHeight)
    }

    func testLongErrorWrapsToTwoLines() {
        let result = layout(.error("long"), textWidth: 2_000)
        XCTAssertEqual(result.width, OverlayPillMetrics.maxWidth)
        XCTAssertEqual(result.height, OverlayPillMetrics.twoLineHeight)
    }

    func testRecordingPillIsNarrowerThanTranscribingLabel() {
        XCTAssertLessThan(layout(.recording).width, layout(.transcribing, textWidth: 90).width)
    }

    func testNativeGlassAddsItsContentInsets() {
        XCTAssertGreaterThan(
            layout(.recording, style: .glass, nativeGlass: true).width,
            layout(.recording, style: .glass, nativeGlass: false).width
        )
    }
}

final class OverlayPillPresentationTests: XCTestCase {
    func testTranscribingUsesAnimatedWaveformSymbolNotBrain() {
        let presentation = OverlayPillPresentation(status: .transcribing)
        XCTAssertEqual(presentation.symbolName, "waveform")
        XCTAssertTrue(presentation.isBusy)
        XCTAssertEqual(presentation.label, "Transcribing…")
    }

    func testRecordingIsWaveformOnly() {
        let presentation = OverlayPillPresentation(status: .recording)
        XCTAssertEqual(presentation.kind, .waveform)
        XCTAssertNil(presentation.label)
    }

    func testArmingIsAPulsingEmberMic() {
        let presentation = OverlayPillPresentation(status: .arming)
        XCTAssertEqual(presentation.kind, .symbol)
        XCTAssertEqual(presentation.tone, .ember)
        XCTAssertTrue(presentation.pulsesOnce)
    }

    func testWarningAndErrorUseDistinctTones() {
        XCTAssertEqual(OverlayPillPresentation(status: .warning("w")).tone, .warning)
        XCTAssertEqual(OverlayPillPresentation(status: .error("e")).tone, .error)
    }

    func testResultShowsCheckmarkAndSummary() {
        let presentation = OverlayPillPresentation(status: .result("ignored", wordCount: 42, duration: 0.28))
        XCTAssertEqual(presentation.symbolName, "checkmark")
        XCTAssertEqual(presentation.tone, .success)
        XCTAssertEqual(presentation.label, "42 words · 0.28s")
    }

    func testStreamingTextDoesNotChangeContentAnimationKey() {
        let a = OverlayPillPresentation(status: .partial("hello", confirmed: false))
        let b = OverlayPillPresentation(status: .partial("hello world", confirmed: false))
        XCTAssertEqual(a.contentAnimationKey, b.contentAnimationKey)
        XCTAssertTrue(a.isStreaming)
        XCTAssertTrue(a.dimsTail)
        XCTAssertFalse(OverlayPillPresentation(status: .partial("x", confirmed: true)).dimsTail)
    }
}

final class OverlayResultSummaryTests: XCTestCase {
    func testWordCountAndDuration() {
        XCTAssertEqual(OverlayResultSummary.label(text: "", wordCount: 42, duration: 0.28), "42 words · 0.28s")
    }

    func testSingularWord() {
        XCTAssertEqual(OverlayResultSummary.label(text: "", wordCount: 1, duration: nil), "1 word")
    }

    func testZeroOrMissingDurationIsOmitted() {
        XCTAssertEqual(OverlayResultSummary.label(text: "", wordCount: 7, duration: 0), "7 words")
        XCTAssertEqual(OverlayResultSummary.label(text: "", wordCount: 7, duration: nil), "7 words")
    }

    func testWordCountFallsBackToText() {
        XCTAssertEqual(OverlayResultSummary.label(text: "one two  three\nfour", wordCount: nil, duration: nil), "4 words")
    }

    func testLongDurationsUseOneDecimal() {
        XCTAssertEqual(OverlayResultSummary.formatDuration(12.345), "12.3s")
        XCTAssertEqual(OverlayResultSummary.formatDuration(1.5), "1.50s")
    }
}

final class OverlayPillWidthGovernorTests: XCTestCase {
    func testNonStreamingWidthsApplyDirectly() {
        var governor = OverlayPillWidthGovernor()
        XCTAssertEqual(governor.resolve(target: 200, isStreaming: false, now: 0), .init(width: 200))
        XCTAssertEqual(governor.resolve(target: 120, isStreaming: false, now: 0.01), .init(width: 120))
    }

    func testFirstStreamingWidthApplies() {
        var governor = OverlayPillWidthGovernor()
        XCTAssertEqual(governor.resolve(target: 96, isStreaming: true, now: 0), .init(width: 96))
    }

    func testStreamingNeverShrinks() {
        var governor = OverlayPillWidthGovernor()
        _ = governor.resolve(target: 160, isStreaming: true, now: 0)
        XCTAssertEqual(governor.resolve(target: 120, isStreaming: true, now: 1), .init(width: 160))
    }

    func testStreamingGrowthIsThrottledToEightHertz() {
        var governor = OverlayPillWidthGovernor()
        _ = governor.resolve(target: 96, isStreaming: true, now: 0)

        let held = governor.resolve(target: 104, isStreaming: true, now: 0.05)
        XCTAssertEqual(held.width, 96)
        XCTAssertEqual(held.retryAfter ?? 0, 0.075, accuracy: 0.0001)

        XCTAssertEqual(governor.resolve(target: 112, isStreaming: true, now: 0.125), .init(width: 112))
    }

    func testLeavingStreamingEndsTheSessionAndAllowsTheShrink() {
        var governor = OverlayPillWidthGovernor()
        _ = governor.resolve(target: 240, isStreaming: true, now: 0)
        XCTAssertEqual(governor.resolve(target: 144, isStreaming: false, now: 0.01), .init(width: 144))
        XCTAssertNil(governor.streamingWidth)
        XCTAssertEqual(governor.resolve(target: 96, isStreaming: true, now: 0.02), .init(width: 96))
    }
}
