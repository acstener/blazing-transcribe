import XCTest
@testable import App

final class SetupChecklistTests: XCTestCase {
    // MARK: Microphone

    func testMicrophoneAsksBeforeRequest() {
        let row = SetupChecklist.microphone(authorization: .notDetermined, hasRequested: false, hasPermissionError: false)
        XCTAssertEqual(row.status, .needsAction("Allow"))
    }

    func testMicrophoneWaitsWhileSystemPromptIsUp() {
        let row = SetupChecklist.microphone(authorization: .notDetermined, hasRequested: true, hasPermissionError: false)
        XCTAssertEqual(row.status, .waiting(nil))
    }

    func testDeniedMicrophoneOffersSettings() {
        let row = SetupChecklist.microphone(authorization: .denied, hasRequested: true, hasPermissionError: false)
        XCTAssertEqual(row.status, .needsAction("Open Settings"))
    }

    func testMicrophoneErrorOffersTryAgain() {
        let row = SetupChecklist.microphone(authorization: .denied, hasRequested: false, hasPermissionError: true)
        XCTAssertEqual(row.status, .failed("Try again"))
    }

    func testStaleMicrophoneErrorClearsOnceGranted() {
        let row = SetupChecklist.microphone(authorization: .granted, hasRequested: true, hasPermissionError: true)
        XCTAssertEqual(row.status, .done)
    }

    // MARK: Accessibility

    func testAccessibilityStates() {
        XCTAssertEqual(SetupChecklist.accessibility(granted: false, hasRequested: false).status, .needsAction("Allow"))
        XCTAssertEqual(SetupChecklist.accessibility(granted: false, hasRequested: true).status, .waiting("Open Settings"))
        XCTAssertEqual(SetupChecklist.accessibility(granted: true, hasRequested: true).status, .done)
    }

    // MARK: Speech model

    private func model(
        ready: Bool = false, loading: Bool = false, pending: Bool = false,
        fraction: Double? = nil, error: String? = nil, retry: Bool = false
    ) -> SetupChecklist.Row {
        SetupChecklist.speechModel(
            isReady: ready, isLoading: loading, isDownloadPending: pending,
            downloadFraction: fraction, completedBytes: 0, totalBytes: 0,
            errorMessage: error, isRetryScheduled: retry
        )
    }

    func testModelIsIndeterminateUntilFractionKnown() {
        XCTAssertEqual(model(loading: true, pending: true).status, .working(fraction: nil))
    }

    func testModelBecomesDeterminateWithFraction() {
        XCTAssertEqual(model(loading: true, pending: true, fraction: 0.4).status, .working(fraction: 0.4))
        XCTAssertEqual(model(loading: true, pending: true, fraction: 1.4).status, .working(fraction: 1))
    }

    func testModelPreparingAfterDownloadIsIndeterminate() {
        let row = model(loading: true)
        XCTAssertEqual(row.status, .working(fraction: nil))
        XCTAssertTrue(row.caption.contains("Optimising"))
    }

    func testModelErrorShowsHumanCopyAndRetry() {
        let message = ModelLoadErrorCopy.message(for: .network)
        let row = model(error: message)
        XCTAssertEqual(row.status, .failed("Retry"))
        XCTAssertEqual(row.caption, message)
    }

    func testModelAutoRetryShowsProgressNotFailure() {
        let row = model(error: ModelLoadErrorCopy.retryingMessage, retry: true)
        XCTAssertEqual(row.status, .working(fraction: nil))
    }

    func testModelReady() {
        XCTAssertEqual(model(ready: true).status, .done)
        XCTAssertNotEqual(model(ready: true, loading: true).status, .done)
    }

    func testIdleModelOffersDownload() {
        XCTAssertEqual(model().status, .needsAction("Download"))
    }

    // MARK: Continue

    func testContinueNeedsBothPermissionsButNotTheModel() {
        let mic = SetupChecklist.microphone(authorization: .granted, hasRequested: false, hasPermissionError: false)
        let ax = SetupChecklist.accessibility(granted: true, hasRequested: false)
        let downloading = model(loading: true, pending: true, fraction: 0.2)
        XCTAssertTrue(SetupChecklist.canContinue(microphone: mic, accessibility: ax))
        XCTAssertEqual(
            SetupChecklist.continueHint(microphone: mic, accessibility: ax, speechModel: downloading),
            "The model keeps downloading in the background."
        )
        XCTAssertEqual(SetupChecklist.completedCount([mic, ax, downloading]), 2)
    }

    func testContinueBlockedWithoutAccessibility() {
        let mic = SetupChecklist.microphone(authorization: .granted, hasRequested: false, hasPermissionError: false)
        let ax = SetupChecklist.accessibility(granted: false, hasRequested: true)
        XCTAssertFalse(SetupChecklist.canContinue(microphone: mic, accessibility: ax))
        XCTAssertEqual(
            SetupChecklist.continueHint(microphone: mic, accessibility: ax, speechModel: model(ready: true)),
            "Allow Accessibility to continue."
        )
    }

    // MARK: Word reveal

    func testWordRevealSplitsOnWhitespace() {
        XCTAssertEqual(WordReveal.words(in: " A little  less\ntyping. "), ["A", "little", "less", "typing."])
    }

    func testWordRevealStaggerIsBounded() {
        XCTAssertEqual(WordReveal.stagger(forWordCount: 1), 0)
        XCTAssertEqual(WordReveal.stagger(forWordCount: 8), 0.04, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(WordReveal.totalDuration(forWordCount: 500),
                                 WordReveal.maxTotalStagger + WordReveal.wordDuration + 0.0001)
        XCTAssertEqual(WordReveal.totalDuration(forWordCount: 0), 0)
    }

    // MARK: Launch at login

    func testLaunchAtLoginDefaultsOnForFirstDecision() {
        XCTAssertTrue(LaunchAtLoginChoice.initialToggleValue(isCurrentlyEnabled: false, hasPriorDecision: false))
    }

    func testLaunchAtLoginReflectsExistingState() {
        XCTAssertFalse(LaunchAtLoginChoice.initialToggleValue(isCurrentlyEnabled: false, hasPriorDecision: true))
        XCTAssertTrue(LaunchAtLoginChoice.initialToggleValue(isCurrentlyEnabled: true, hasPriorDecision: true))
    }

    func testLaunchAtLoginChangeOnlyWhenDifferent() {
        XCTAssertEqual(LaunchAtLoginChoice.change(desired: true, isCurrentlyEnabled: false), .register)
        XCTAssertEqual(LaunchAtLoginChoice.change(desired: false, isCurrentlyEnabled: true), .unregister)
        XCTAssertEqual(LaunchAtLoginChoice.change(desired: true, isCurrentlyEnabled: true), .none)
        XCTAssertEqual(LaunchAtLoginChoice.change(desired: false, isCurrentlyEnabled: false), .none)
    }
}
