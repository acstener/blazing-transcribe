import XCTest
import FluidAudio
import HotkeyModule
@testable import App

final class ActivationTrackerTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var sent: [(String, [String: Any])] = []
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "ActivationTrackerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        sent = []
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeTracker() -> ActivationTracker {
        ActivationTracker(defaults: defaults, now: { [unowned self] in self.clock }) { [unowned self] name, params in
            self.sent.append((name, params))
        }
    }

    func testMilestonesFireOnceWithTimeBetween() {
        let tracker = makeTracker()
        XCTAssertTrue(tracker.record(.setupStarted))
        clock += 30
        XCTAssertTrue(tracker.record(.microphoneGranted))
        clock += 45
        XCTAssertTrue(tracker.record(.firstPracticeSuccess, parameters: ["wordCount": 5]))
        XCTAssertFalse(tracker.record(.firstPracticeSuccess), "Milestones fire once per install")

        XCTAssertEqual(sent.map(\.0), [
            "activationSetupStarted",
            "activationMicrophoneGranted",
            "activationFirstPracticeSuccess",
        ])
        XCTAssertNil(sent[0].1["secondsSinceSetupStarted"])
        XCTAssertEqual(sent[1].1["secondsSinceSetupStarted"] as? Double, 30)
        XCTAssertEqual(sent[2].1["secondsSinceSetupStarted"] as? Double, 75)
        XCTAssertEqual(sent[2].1["secondsSincePreviousMilestone"] as? Double, 45)
    }

    func testMilestonesPersistAcrossInstances() {
        makeTracker().record(.modelReady)
        XCTAssertFalse(makeTracker().record(.modelReady))
        XCTAssertEqual(sent.count, 1)
    }

    func testFirstExternalDeliverySetsPersistedFlag() {
        let tracker = makeTracker()
        XCTAssertFalse(tracker.hasCompletedFirstExternalDelivery)
        tracker.record(.firstExternalDelivery, parameters: ["wordCount": 3])
        XCTAssertTrue(makeTracker().hasCompletedFirstExternalDelivery)
    }

    func testExistingInstallActivationIsSilent() {
        let tracker = makeTracker()
        tracker.markExistingInstallActivated()
        XCTAssertTrue(tracker.hasCompletedFirstExternalDelivery)
        XCTAssertTrue(sent.isEmpty)
    }

    func testPayloadsNeverCarryText() {
        let tracker = makeTracker()
        tracker.record(.firstExternalDelivery, parameters: ["wordCount": 3])
        for (_, params) in sent {
            for value in params.values {
                XCTAssertFalse(value is String, "Activation payloads carry numbers/bools only here")
            }
        }
    }
}

final class FnKeyConflictTests: XCTestCase {
    func testRawValuesMapToActions() {
        XCTAssertEqual(FnKeySystemAction(rawUsageType: 0), .doNothing)
        XCTAssertEqual(FnKeySystemAction(rawUsageType: 1), .changeInputSource)
        XCTAssertEqual(FnKeySystemAction(rawUsageType: 2), .showEmojiAndSymbols)
        XCTAssertEqual(FnKeySystemAction(rawUsageType: 3), .startDictation)
        XCTAssertEqual(FnKeySystemAction(rawUsageType: nil), .systemDefault)
        XCTAssertEqual(FnKeySystemAction(rawUsageType: 9), .unknown(9))
    }

    func testConflicts() {
        XCTAssertFalse(FnKeySystemAction.doNothing.conflictsWithFnShortcut)
        XCTAssertTrue(FnKeySystemAction.showEmojiAndSymbols.conflictsWithFnShortcut)
        XCTAssertTrue(FnKeySystemAction.startDictation.conflictsWithFnShortcut)
        XCTAssertTrue(FnKeySystemAction.changeInputSource.conflictsWithFnShortcut)
        XCTAssertTrue(FnKeySystemAction.systemDefault.conflictsWithFnShortcut)
    }

    func testOnlyFnAloneShortcutConflicts() {
        XCTAssertTrue(FnKeyConflictDetector.isConflicting(action: .showEmojiAndSymbols, pttShortcut: .defaultPTT))
        XCTAssertFalse(FnKeyConflictDetector.isConflicting(action: .doNothing, pttShortcut: .defaultPTT))
        XCTAssertFalse(FnKeyConflictDetector.isConflicting(action: .showEmojiAndSymbols, pttShortcut: .defaultToggle))
    }
}

final class ModelLoadErrorCopyTests: XCTestCase {
    func testNetworkErrorsGetHumanCopyAndRetry() {
        let error = URLError(.notConnectedToInternet)
        XCTAssertEqual(ModelLoadErrorCopy.kind(of: error), .network)
        XCTAssertTrue(ModelLoadErrorCopy.isRetryable(error))
        let message = ModelLoadErrorCopy.message(for: error)
        XCTAssertFalse(message.contains("FluidAudio"))
        XCTAssertTrue(message.contains("internet connection"))
    }

    func testTimedOutIsNetwork() {
        XCTAssertEqual(ModelLoadErrorCopy.kind(of: URLError(.timedOut)), .network)
    }

    func testWrappedDownloadFailureIsNetwork() {
        let error = DownloadUtils.HuggingFaceDownloadError.downloadFailed(
            path: "Encoder.mlmodelc/weights/weight.bin",
            underlying: URLError(.networkConnectionLost)
        )
        XCTAssertEqual(ModelLoadErrorCopy.kind(of: error), .network)
        XCTAssertTrue(ModelLoadErrorCopy.isRetryable(error))
    }

    func testRateLimitIsServerBusy() {
        let error = DownloadUtils.HuggingFaceDownloadError.rateLimited(statusCode: 429, message: "slow down")
        XCTAssertEqual(ModelLoadErrorCopy.kind(of: error), .serverBusy)
        XCTAssertTrue(ModelLoadErrorCopy.isRetryable(error))
    }

    func testDiskFullIsNotRetried() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        XCTAssertEqual(ModelLoadErrorCopy.kind(of: error), .diskFull)
        XCTAssertFalse(ModelLoadErrorCopy.isRetryable(error))
    }

    func testCancellationIsNotRetried() {
        XCTAssertFalse(ModelLoadErrorCopy.isRetryable(URLError(.cancelled)))
        XCTAssertFalse(ModelLoadErrorCopy.isRetryable(CancellationError()))
    }

    func testLoadFailureCopyHasNoVendorName() {
        let error = AsrModelsError.loadingFailed("CoreML exploded")
        XCTAssertEqual(ModelLoadErrorCopy.kind(of: error), .load)
        XCTAssertFalse(ModelLoadErrorCopy.isRetryable(error))
        XCTAssertFalse(ModelLoadErrorCopy.message(for: error).contains("CoreML"))
    }
}

final class FocusedTextTargetTests: XCTestCase {
    func testNoFocusedElementIsNoTextField() {
        XCTAssertEqual(
            TextDeliveryPolicy.classifyFocusedElement(
                role: nil, subrole: nil, isValueSettable: false, hasSelectedTextRange: false,
                bundleIdentifier: "com.apple.Notes"
            ),
            .noTextField
        )
    }

    func testTextRolesAreEditable() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox"] {
            XCTAssertEqual(
                TextDeliveryPolicy.classifyFocusedElement(
                    role: role, subrole: nil, isValueSettable: false, hasSelectedTextRange: false,
                    bundleIdentifier: nil
                ),
                .editable
            )
        }
    }

    func testCustomViewWithSelectedRangeIsEditable() {
        XCTAssertEqual(
            TextDeliveryPolicy.classifyFocusedElement(
                role: "AXGroup", subrole: nil, isValueSettable: false, hasSelectedTextRange: true,
                bundleIdentifier: nil
            ),
            .editable
        )
    }

    func testDefiniteControlsAreNoTextField() {
        XCTAssertEqual(
            TextDeliveryPolicy.classifyFocusedElement(
                role: "AXButton", subrole: nil, isValueSettable: false, hasSelectedTextRange: false,
                bundleIdentifier: nil
            ),
            .noTextField
        )
    }

    func testAmbiguousContainersStayUnknown() {
        for role in ["AXGroup", "AXScrollArea", "AXWebArea", "AXUnknown"] {
            XCTAssertEqual(
                TextDeliveryPolicy.classifyFocusedElement(
                    role: role, subrole: nil, isValueSettable: false, hasSelectedTextRange: false,
                    bundleIdentifier: "com.example.app"
                ),
                .unknown
            )
        }
    }

    func testFinderDesktopContainersAreNoTextField() {
        XCTAssertEqual(
            TextDeliveryPolicy.classifyFocusedElement(
                role: "AXScrollArea", subrole: nil, isValueSettable: false, hasSelectedTextRange: false,
                bundleIdentifier: "com.apple.finder"
            ),
            .noTextField
        )
    }

    func testBrowsersTerminalsAndElectronAreNeverSecondGuessed() {
        XCTAssertFalse(TextDeliveryPolicy.canTrustNoTextFieldSignal(
            bundleIdentifier: "com.google.Chrome", appName: "Google Chrome", isElectronApp: false))
        XCTAssertFalse(TextDeliveryPolicy.canTrustNoTextFieldSignal(
            bundleIdentifier: "com.apple.Terminal", appName: "Terminal", isElectronApp: false))
        XCTAssertFalse(TextDeliveryPolicy.canTrustNoTextFieldSignal(
            bundleIdentifier: "com.tinyspeck.slackmacgap", appName: "Slack", isElectronApp: true))
        XCTAssertTrue(TextDeliveryPolicy.canTrustNoTextFieldSignal(
            bundleIdentifier: "com.apple.finder", appName: "Finder", isElectronApp: false))
    }
}
