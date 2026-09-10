import XCTest
@testable import App

final class MenuBarStatusIconTests: XCTestCase {
    func testListeningUsesWaveformAndOrangeTint() {
        let icon = MenuBarStatusIcon.resolve(
            isEngineLoading: false,
            isDownloading: false,
            isRecording: false,
            isListening: true,
            isMicMuted: false,
            isManualMode: false,
            isMicCaptureActive: true
        )

        XCTAssertEqual(icon, .listening)
        XCTAssertEqual(icon.symbolName, "waveform")
        XCTAssertTrue(icon.usesOrangeMicTint)
    }

    func testRecordingUsesRecordCircleAndOrangeTint() {
        let icon = MenuBarStatusIcon.resolve(
            isEngineLoading: false,
            isDownloading: false,
            isRecording: true,
            isListening: false,
            isMicMuted: false,
            isManualMode: true,
            isMicCaptureActive: true
        )

        XCTAssertEqual(icon, .recording)
        XCTAssertEqual(icon.symbolName, "record.circle")
        XCTAssertTrue(icon.usesOrangeMicTint)
    }

    func testWarmMicStandbyUsesOrangeMicIcon() {
        let icon = MenuBarStatusIcon.resolve(
            isEngineLoading: false,
            isDownloading: false,
            isRecording: false,
            isListening: false,
            isMicMuted: false,
            isManualMode: true,
            isMicCaptureActive: true
        )

        XCTAssertEqual(icon, .micActive)
        XCTAssertEqual(icon.symbolName, "mic.fill")
        XCTAssertTrue(icon.usesOrangeMicTint)
    }

    func testManualIdleWithoutCaptureHasNoOrangeTint() {
        let icon = MenuBarStatusIcon.resolve(
            isEngineLoading: false,
            isDownloading: false,
            isRecording: false,
            isListening: false,
            isMicMuted: false,
            isManualMode: true,
            isMicCaptureActive: false
        )

        XCTAssertEqual(icon, .idleManual)
        XCTAssertEqual(icon.symbolName, "mic.fill")
        XCTAssertFalse(icon.usesOrangeMicTint)
    }

    func testMutedTakesPrecedenceOverCapture() {
        let icon = MenuBarStatusIcon.resolve(
            isEngineLoading: false,
            isDownloading: false,
            isRecording: false,
            isListening: false,
            isMicMuted: true,
            isManualMode: false,
            isMicCaptureActive: false
        )

        XCTAssertEqual(icon, .muted)
        XCTAssertEqual(icon.symbolName, "mic.slash")
        XCTAssertFalse(icon.usesOrangeMicTint)
    }

    func testEngineDownloadTakesPrecedence() {
        let icon = MenuBarStatusIcon.resolve(
            isEngineLoading: true,
            isDownloading: true,
            isRecording: true,
            isListening: true,
            isMicMuted: false,
            isManualMode: false,
            isMicCaptureActive: true
        )

        XCTAssertEqual(icon, .downloading)
        XCTAssertEqual(icon.symbolName, "arrow.down.circle")
        XCTAssertFalse(icon.usesOrangeMicTint)
    }
}
