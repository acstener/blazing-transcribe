import XCTest
@testable import App

final class MicrophonePresentationTests: XCTestCase {
    func testStoppedCaptureNeverClaimsToBeListeningEvenIfAppStateIsStale() {
        XCTAssertEqual(resolve(.listening, capture: false, mode: .alwaysOn), .off)
    }

    func testWarmManualCaptureIsDisclosedEvenWhileIdle() {
        XCTAssertEqual(resolve(.idle, capture: true, mode: .manual), .standby)
    }

    func testHandsFreeRequiresActualCapture() {
        XCTAssertEqual(resolve(.idle, capture: true, mode: .alwaysOn), .handsFree)
    }

    func testTranscriptionRemainsVisibleAfterMicStops() {
        XCTAssertEqual(resolve(.transcribing, capture: false, mode: .manual), .transcribing)
    }

    func testErrorTakesPrecedenceOverEngineLoading() {
        XCTAssertEqual(MicrophonePresentation.resolve(state: .error("Device lost"), captureRunning: false,
            engineReady: false, loading: true, permissionsGranted: true, mode: .manual), .needsAttention)
    }

    func testUnreadyEngineDoesNotAppearReadyWhenLoadingEnds() {
        XCTAssertEqual(MicrophonePresentation.resolve(state: .idle, captureRunning: false,
            engineReady: false, loading: false, permissionsGranted: true, mode: .manual), .preparing)
    }

    private func resolve(_ state: AppState.State, capture: Bool, mode: RecordingMode) -> MicrophonePresentation {
        .resolve(state: state, captureRunning: capture, engineReady: true,
                 loading: false, permissionsGranted: true, mode: mode)
    }
}
