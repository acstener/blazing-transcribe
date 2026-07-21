import AVFoundation
import AudioToolbox
import XCTest
@testable import AudioEngine

private struct StubCoreAudioQuery: CoreAudioQuerying {
    let devices: [AudioDeviceID]
    let streamConfigs: [AudioDeviceID: Data]
    let names: [AudioDeviceID: String]
    let formats: [AudioDeviceID: AVAudioFormat]
    let defaultInputDevice: AudioDeviceID?

    func deviceIDs() -> [AudioDeviceID] { devices }

    func inputStreamConfiguration(deviceID: AudioDeviceID) -> Data? {
        streamConfigs[deviceID]
    }

    func deviceName(deviceID: AudioDeviceID) -> String? {
        names[deviceID]
    }

    func inputStreamFormat(deviceID: AudioDeviceID) -> AVAudioFormat? {
        formats[deviceID]
    }

    func defaultInputDeviceID() -> AudioDeviceID? {
        defaultInputDevice
    }
}

private final class FakeAudioCaptureBackend: AudioCaptureBackend {
    var onFirstCallback: (() -> Void)?
    var onData: ((_ samples: UnsafeBufferPointer<Float>, _ rms: Float) -> Void)?

    let startInfo: AudioCaptureBackendStartInfo
    private(set) var startedDeviceID: AudioDeviceID?
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    init(startInfo: AudioCaptureBackendStartInfo) {
        self.startInfo = startInfo
    }

    func start(deviceID: AudioDeviceID?) throws -> AudioCaptureBackendStartInfo {
        startCallCount += 1
        startedDeviceID = deviceID
        return startInfo
    }

    func stop() {
        stopCallCount += 1
    }

    func emitFirstCallback() {
        onFirstCallback?()
    }

    func emit(samples: [Float], rms: Float? = nil) {
        samples.withUnsafeBufferPointer { buffer in
            onData?(buffer, rms ?? Self.rms(of: buffer))
        }
    }

    private static func rms(of samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSquares: Float = 0
        for sample in samples {
            sumSquares += sample * sample
        }
        return sqrtf(sumSquares / Float(samples.count))
    }
}

private final class DelegateSpy: AudioCaptureDelegate {
    var failures: [Error] = []

    func audioCaptureDidStart() {}
    func audioCaptureDidStop() {}
    func audioCaptureDidFail(error: Error) {
        failures.append(error)
    }
    func audioCaptureDidDetectSpeechEnd(segment: AudioSegment, timing: SpeechSegmentTiming) {}
    func audioCaptureInputDeviceStateDidChange(_ state: AudioInputDeviceState) {}
}

final class AudioCaptureServiceTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        AudioCaptureService.coreAudioQuery = SystemCoreAudioQuery()
        AudioCaptureService.captureBackendFactory = { query, targetSampleRate, targetChannels in
            HALAudioCaptureService(
                query: query,
                targetSampleRate: targetSampleRate,
                targetChannels: targetChannels
            )
        }
        AudioCaptureService.audioAuthorizationStatus = {
            AVCaptureDevice.authorizationStatus(for: .audio)
        }
        AudioCaptureService.requestAudioAccess = { completion in
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
        }
    }

    func testInputChannelCount_headerOnlyReturnsZero() {
        let data = makeStreamConfigData(declaredBufferCount: 1, buffers: [])
        XCTAssertEqual(AudioCaptureService.inputChannelCount(fromStreamConfigurationData: data), 0)
    }

    func testInputChannelCount_singleBuffer() {
        let data = makeStreamConfigData(
            declaredBufferCount: 1,
            buffers: [makeAudioBuffer(channels: 2)]
        )
        XCTAssertEqual(AudioCaptureService.inputChannelCount(fromStreamConfigurationData: data), 2)
    }

    func testInputChannelCount_multiBuffer() {
        let data = makeStreamConfigData(
            declaredBufferCount: 2,
            buffers: [
                makeAudioBuffer(channels: 1),
                makeAudioBuffer(channels: 3),
            ]
        )
        XCTAssertEqual(AudioCaptureService.inputChannelCount(fromStreamConfigurationData: data), 4)
    }

    func testInputChannelCount_clampsOversizedBufferCount() {
        let data = makeStreamConfigData(
            declaredBufferCount: 99,
            buffers: [makeAudioBuffer(channels: 1)]
        )
        XCTAssertEqual(AudioCaptureService.inputChannelCount(fromStreamConfigurationData: data), 1)
    }

    func testNormalizedTapFormat_convertsInterleavedFormatsToNonInterleavedFloat() {
        let rawFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        )!

        let normalized = AudioCaptureService.normalizedTapFormat(from: rawFormat)

        XCTAssertNotNil(normalized)
        XCTAssertEqual(normalized?.sampleRate, 48_000)
        XCTAssertEqual(normalized?.channelCount, 2)
        XCTAssertEqual(normalized?.commonFormat, .pcmFormatFloat32)
        XCTAssertEqual(normalized?.isInterleaved, false)
    }

    func testNormalizedTapFormat_preservesRateAndChannelsForNonInterleavedInput() {
        let rawFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        )!

        let normalized = AudioCaptureService.normalizedTapFormat(from: rawFormat)

        XCTAssertNotNil(normalized)
        XCTAssertEqual(normalized?.sampleRate, rawFormat.sampleRate)
        XCTAssertEqual(normalized?.channelCount, rawFormat.channelCount)
        XCTAssertEqual(normalized?.isInterleaved, false)
    }

    func testAvailableInputDevices_skipsMalformedOrNamelessDevices() {
        let validConfig = makeStreamConfigData(
            declaredBufferCount: 1,
            buffers: [makeAudioBuffer(channels: 1)]
        )
        let malformedConfig = makeStreamConfigData(declaredBufferCount: 2, buffers: [])
        let noInputConfig = makeStreamConfigData(
            declaredBufferCount: 1,
            buffers: [makeAudioBuffer(channels: 0)]
        )

        let query = StubCoreAudioQuery(
            devices: [1, 2, 3, 4],
            streamConfigs: [
                1: validConfig,
                2: malformedConfig,
                3: noInputConfig,
                4: validConfig,
            ],
            names: [
                1: "Working Mic",
                2: "Malformed",
                3: "NoInput",
                // Device 4 intentionally missing name
            ],
            formats: [:],
            defaultInputDevice: nil
        )

        let devices = AudioCaptureService.availableInputDevices(using: query)
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.id, 1)
        XCTAssertEqual(devices.first?.name, "Working Mic")
    }

    func testWindowAwareSilenceTimeoutTightensNearModelWindow() {
        // Below 11s of speech the profile timeout passes through untouched.
        XCTAssertEqual(
            AudioCaptureService.windowAwareSilenceTimeout(0.35, speechDuration: 8.0),
            0.35,
            accuracy: 0.0001
        )
        // Approaching the 15s ASR window the gate tightens so segments end at
        // a word gap before chunk-merging would kick in.
        XCTAssertEqual(
            AudioCaptureService.windowAwareSilenceTimeout(0.35, speechDuration: 11.5),
            0.10,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AudioCaptureService.windowAwareSilenceTimeout(0.35, speechDuration: 13.5),
            0.06,
            accuracy: 0.0001
        )
        // Never loosens a timeout that is already tighter.
        XCTAssertEqual(
            AudioCaptureService.windowAwareSilenceTimeout(0.05, speechDuration: 12.0),
            0.05,
            accuracy: 0.0001
        )
    }

    func testModelWindowSplitDurationStaysInsideEncoderWindow() {
        // Preroll adds ~0.5s on top of the split threshold; the emitted segment
        // must still fit Parakeet's 15s (240k-sample) encoder window.
        XCTAssertLessThanOrEqual(AudioCaptureService.modelWindowSplitDuration + 0.6, 15.0)
    }

    func testRealtimeParakeetDefaultTimeoutMatchesBalancedProfile() {
        XCTAssertEqual(
            AudioCaptureService.adaptiveSilenceTimeout(
                for: 0.8,
                profile: .realtimeParakeet,
                configuredSilenceTimeout: 0.5,
                turboSilenceGate: false
            ),
            0.08,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AudioCaptureService.adaptiveSilenceTimeout(
                for: 2.0,
                profile: .realtimeParakeet,
                configuredSilenceTimeout: 0.5,
                turboSilenceGate: false
            ),
            0.12,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AudioCaptureService.adaptiveSilenceTimeout(
                for: 5.0,
                profile: .realtimeParakeet,
                configuredSilenceTimeout: 0.5,
                turboSilenceGate: false
            ),
            0.18,
            accuracy: 0.0001
        )
    }

    func testStandardDefaultTimeoutMatchesBalancedProfile() {
        XCTAssertEqual(
            AudioCaptureService.adaptiveSilenceTimeout(
                for: 1.0,
                profile: .standard,
                configuredSilenceTimeout: 0.5,
                turboSilenceGate: false
            ),
            0.10,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AudioCaptureService.adaptiveSilenceTimeout(
                for: 2.0,
                profile: .standard,
                configuredSilenceTimeout: 0.5,
                turboSilenceGate: false
            ),
            0.20,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AudioCaptureService.adaptiveSilenceTimeout(
                for: 6.0,
                profile: .standard,
                configuredSilenceTimeout: 0.5,
                turboSilenceGate: false
            ),
            0.35,
            accuracy: 0.0001
        )
    }

    func testStandardLowerConfiguredTimeoutSpeedsUpSafely() {
        XCTAssertEqual(
            AudioCaptureService.adaptiveSilenceTimeout(
                for: 1.0,
                profile: .standard,
                configuredSilenceTimeout: 0.4,
                turboSilenceGate: false
            ),
            0.08,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AudioCaptureService.adaptiveSilenceTimeout(
                for: 2.0,
                profile: .standard,
                configuredSilenceTimeout: 0.4,
                turboSilenceGate: false
            ),
            0.16,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AudioCaptureService.adaptiveSilenceTimeout(
                for: 6.0,
                profile: .standard,
                configuredSilenceTimeout: 0.4,
                turboSilenceGate: false
            ),
            0.28,
            accuracy: 0.0001
        )
    }

    func testStableExtraQuickDefaultTimeoutMatchesFasterProfile() {
        XCTAssertEqual(
            AudioCaptureService.adaptiveSilenceTimeout(
                for: 1.0,
                profile: .stableExtraQuick,
                configuredSilenceTimeout: 0.5,
                turboSilenceGate: false
            ),
            0.06,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AudioCaptureService.adaptiveSilenceTimeout(
                for: 2.0,
                profile: .stableExtraQuick,
                configuredSilenceTimeout: 0.5,
                turboSilenceGate: false
            ),
            0.12,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AudioCaptureService.adaptiveSilenceTimeout(
                for: 6.0,
                profile: .stableExtraQuick,
                configuredSilenceTimeout: 0.5,
                turboSilenceGate: false
            ),
            0.22,
            accuracy: 0.0001
        )
    }

    func testStableExtraQuickLowerConfiguredTimeoutUsesFastFloor() {
        XCTAssertEqual(
            AudioCaptureService.adaptiveSilenceTimeout(
                for: 1.0,
                profile: .stableExtraQuick,
                configuredSilenceTimeout: 0.4,
                turboSilenceGate: false
            ),
            0.05,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AudioCaptureService.adaptiveSilenceTimeout(
                for: 2.0,
                profile: .stableExtraQuick,
                configuredSilenceTimeout: 0.4,
                turboSilenceGate: false
            ),
            0.10,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AudioCaptureService.adaptiveSilenceTimeout(
                for: 6.0,
                profile: .stableExtraQuick,
                configuredSilenceTimeout: 0.4,
                turboSilenceGate: false
            ),
            0.18,
            accuracy: 0.0001
        )
    }

    func testStableExtraQuickRecentRestartUsesLowerMinimumSpeechDuration() {
        let previousEndpoint = Date()
        let restartedAt = previousEndpoint.addingTimeInterval(0.45)

        XCTAssertEqual(
            AudioCaptureService.minimumSpeechDuration(
                for: .stableExtraQuick,
                speechStartDetectedAt: restartedAt,
                previousSegmentEndedAt: previousEndpoint
            ),
            0.65,
            accuracy: 0.0001
        )
    }

    func testStableExtraQuickFreshUtteranceKeepsDefaultMinimumSpeechDuration() {
        let previousEndpoint = Date()
        let restartedAt = previousEndpoint.addingTimeInterval(1.2)

        XCTAssertEqual(
            AudioCaptureService.minimumSpeechDuration(
                for: .stableExtraQuick,
                speechStartDetectedAt: restartedAt,
                previousSegmentEndedAt: previousEndpoint
            ),
            0.8,
            accuracy: 0.0001
        )
    }

    func testStandardMinimumSpeechDurationDoesNotChangeForRecentRestart() {
        let previousEndpoint = Date()
        let restartedAt = previousEndpoint.addingTimeInterval(0.2)

        XCTAssertEqual(
            AudioCaptureService.minimumSpeechDuration(
                for: .standard,
                speechStartDetectedAt: restartedAt,
                previousSegmentEndedAt: previousEndpoint
            ),
            0.8,
            accuracy: 0.0001
        )
    }

    func testStableExtraQuickMinimumSpeechCheckCountsPrerollForBatchProfile() {
        let previousEndpoint = Date()
        let restartedAt = previousEndpoint.addingTimeInterval(0.4)

        XCTAssertTrue(
            AudioCaptureService.meetsMinimumSpeechDuration(
                capturedDuration: 0.70,
                profile: .stableExtraQuick,
                speechStartDetectedAt: restartedAt,
                previousSegmentEndedAt: previousEndpoint
            )
        )
    }

    func testStableExtraQuickMinimumSpeechCheckAcceptsRealSpeechPastThreshold() {
        let previousEndpoint = Date()
        let restartedAt = previousEndpoint.addingTimeInterval(0.4)

        XCTAssertTrue(
            AudioCaptureService.meetsMinimumSpeechDuration(
                capturedDuration: 1.20,
                profile: .stableExtraQuick,
                speechStartDetectedAt: restartedAt,
                previousSegmentEndedAt: previousEndpoint
            )
        )
    }

    func testStandardMinimumSpeechCheckCountsPrerollForBatchProfile() {
        XCTAssertTrue(
            AudioCaptureService.meetsMinimumSpeechDuration(
                capturedDuration: 0.90,
                profile: .standard,
                speechStartDetectedAt: Date(),
                previousSegmentEndedAt: nil
            )
        )
    }

    func testRealtimeParakeetMinimumSpeechCheckStillUsesActualSpeechNotPreroll() {
        XCTAssertFalse(
            AudioCaptureService.meetsMinimumSpeechDuration(
                capturedDuration: 0.45,
                profile: .realtimeParakeet,
                speechStartDetectedAt: Date(),
                previousSegmentEndedAt: nil
            )
        )
    }

    func testRealtimeParakeetMinimumSpeechCheckAcceptsActualSpeechPastThreshold() {
        XCTAssertTrue(
            AudioCaptureService.meetsMinimumSpeechDuration(
                capturedDuration: 0.55,
                profile: .realtimeParakeet,
                speechStartDetectedAt: Date(),
                previousSegmentEndedAt: nil
            )
        )
    }

    func testStableExtraQuickRetainsShortCarryoverForRapidRestartWindow() {
        let previousEndpoint = Date()
        let discardedAt = previousEndpoint.addingTimeInterval(0.4)

        XCTAssertTrue(
            AudioCaptureService.shouldRetainShortSpeechCarryover(
                profile: .stableExtraQuick,
                previousAcceptedSpeechEndpointAt: previousEndpoint,
                currentEndpointDetectedAt: discardedAt,
                hasExistingCarryover: false
            )
        )
    }

    func testStableExtraQuickRetainsExistingCarryoverAcrossMultipleShortBlips() {
        XCTAssertTrue(
            AudioCaptureService.shouldRetainShortSpeechCarryover(
                profile: .stableExtraQuick,
                previousAcceptedSpeechEndpointAt: nil,
                currentEndpointDetectedAt: Date(),
                hasExistingCarryover: true
            )
        )
    }

    func testStableExtraQuickDoesNotRetainShortCarryoverOutsideRapidRestartWindow() {
        let previousEndpoint = Date()
        let discardedAt = previousEndpoint.addingTimeInterval(1.4)

        XCTAssertFalse(
            AudioCaptureService.shouldRetainShortSpeechCarryover(
                profile: .stableExtraQuick,
                previousAcceptedSpeechEndpointAt: previousEndpoint,
                currentEndpointDetectedAt: discardedAt,
                hasExistingCarryover: false
            )
        )
    }

    func testRealtimeParakeetRetainsShortCarryoverForImmediateRestartWindow() {
        let previousEndpoint = Date()
        let discardedAt = previousEndpoint.addingTimeInterval(0.25)

        XCTAssertTrue(
            AudioCaptureService.shouldRetainShortSpeechCarryover(
                profile: .realtimeParakeet,
                previousAcceptedSpeechEndpointAt: previousEndpoint,
                currentEndpointDetectedAt: discardedAt,
                hasExistingCarryover: false
            )
        )
    }

    func testRealtimeParakeetDoesNotRetainShortCarryoverOutsideBridgeWindow() {
        let previousEndpoint = Date()
        let discardedAt = previousEndpoint.addingTimeInterval(0.6)

        XCTAssertFalse(
            AudioCaptureService.shouldRetainShortSpeechCarryover(
                profile: .realtimeParakeet,
                previousAcceptedSpeechEndpointAt: previousEndpoint,
                currentEndpointDetectedAt: discardedAt,
                hasExistingCarryover: false
            )
        )
    }

    func testStandardDoesNotRetainShortCarryover() {
        XCTAssertFalse(
            AudioCaptureService.shouldRetainShortSpeechCarryover(
                profile: .standard,
                previousAcceptedSpeechEndpointAt: Date(),
                currentEndpointDetectedAt: Date(),
                hasExistingCarryover: true
            )
        )
    }

    func testEndpointingSpeechDurationSubtractsProfilePreroll() {
        XCTAssertEqual(
            AudioCaptureService.endpointingSpeechDuration(
                capturedDuration: 1.94,
                profile: .standard
            ),
            1.44,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AudioCaptureService.endpointingSpeechDuration(
                capturedDuration: 1.20,
                profile: .realtimeParakeet
            ),
            1.05,
            accuracy: 0.0001
        )
    }

    func testRealtimeParakeetLowerConfiguredTimeoutSpeedsUpButStaysAboveSafeFloor() {
        XCTAssertEqual(
            AudioCaptureService.adaptiveSilenceTimeout(
                for: 0.8,
                profile: .realtimeParakeet,
                configuredSilenceTimeout: 0.2,
                turboSilenceGate: false
            ),
            0.056,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AudioCaptureService.adaptiveSilenceTimeout(
                for: 2.0,
                profile: .realtimeParakeet,
                configuredSilenceTimeout: 0.2,
                turboSilenceGate: false
            ),
            0.085,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AudioCaptureService.adaptiveSilenceTimeout(
                for: 5.0,
                profile: .realtimeParakeet,
                configuredSilenceTimeout: 0.2,
                turboSilenceGate: false
            ),
            0.126,
            accuracy: 0.0001
        )
    }

    func testRealtimeParakeetHigherConfiguredTimeoutAddsPauseTolerance() {
        XCTAssertEqual(
            AudioCaptureService.adaptiveSilenceTimeout(
                for: 0.8,
                profile: .realtimeParakeet,
                configuredSilenceTimeout: 0.7,
                turboSilenceGate: false
            ),
            0.108,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AudioCaptureService.adaptiveSilenceTimeout(
                for: 2.0,
                profile: .realtimeParakeet,
                configuredSilenceTimeout: 0.7,
                turboSilenceGate: false
            ),
            0.162,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AudioCaptureService.adaptiveSilenceTimeout(
                for: 5.0,
                profile: .realtimeParakeet,
                configuredSilenceTimeout: 0.7,
                turboSilenceGate: false
            ),
            0.24,
            accuracy: 0.0001
        )
    }

    func testRealtimeParakeetTurboProfileStillUsesFasterFloor() {
        XCTAssertEqual(
            AudioCaptureService.adaptiveSilenceTimeout(
                for: 0.8,
                profile: .realtimeParakeet,
                configuredSilenceTimeout: 0.5,
                turboSilenceGate: true
            ),
            0.055,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AudioCaptureService.adaptiveSilenceTimeout(
                for: 2.0,
                profile: .realtimeParakeet,
                configuredSilenceTimeout: 0.5,
                turboSilenceGate: true
            ),
            0.085,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AudioCaptureService.adaptiveSilenceTimeout(
                for: 5.0,
                profile: .realtimeParakeet,
                configuredSilenceTimeout: 0.5,
                turboSilenceGate: true
            ),
            0.12,
            accuracy: 0.0001
        )
    }

    func testRealtimeParakeetStartRejectsWeakPeakOnlySpike() {
        let detection = SpeechDetectionResult(
            peakProbability: 0.47,
            trailingMaxProbability: 0.47,
            trailingAverageProbability: 0.01,
            frameCount: 8
        )

        XCTAssertFalse(
            AudioCaptureService.shouldStartSpeech(
                with: detection,
                profile: .realtimeParakeet,
                vadThreshold: 0.35
            )
        )
    }

    func testRealtimeParakeetStartAllowsSustainedSpeechOnset() {
        let detection = SpeechDetectionResult(
            peakProbability: 0.49,
            trailingMaxProbability: 0.49,
            trailingAverageProbability: 0.24,
            frameCount: 8
        )

        XCTAssertTrue(
            AudioCaptureService.shouldStartSpeech(
                with: detection,
                profile: .realtimeParakeet,
                vadThreshold: 0.35
            )
        )
    }

    func testStandardStartStillUsesPeakOnlyGate() {
        let detection = SpeechDetectionResult(
            peakProbability: 0.36,
            trailingMaxProbability: 0.36,
            trailingAverageProbability: 0.01,
            frameCount: 8
        )

        XCTAssertTrue(
            AudioCaptureService.shouldStartSpeech(
                with: detection,
                profile: .standard,
                vadThreshold: 0.35
            )
        )
    }

    func testStartCoordinator_retriesThenGivesUp() {
        var coordinator = StartCoordinator()
        let cycle = coordinator.beginCycle()

        guard case let .scheduleRetry(delay1, attempt1, force1) = coordinator.actionForFailure(
            inCycle: cycle,
            didPinPreferred: false,
            forceSystemDefault: false
        ) else {
            return XCTFail("Expected first retry")
        }
        XCTAssertEqual(delay1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(attempt1, 1)
        XCTAssertFalse(force1)

        guard case let .scheduleRetry(delay2, attempt2, force2) = coordinator.actionForFailure(
            inCycle: cycle,
            didPinPreferred: false,
            forceSystemDefault: false
        ) else {
            return XCTFail("Expected second retry")
        }
        XCTAssertEqual(delay2, 1.0, accuracy: 0.0001)
        XCTAssertEqual(attempt2, 2)
        XCTAssertFalse(force2)

        guard case let .scheduleRetry(delay3, attempt3, force3) = coordinator.actionForFailure(
            inCycle: cycle,
            didPinPreferred: false,
            forceSystemDefault: false
        ) else {
            return XCTFail("Expected third retry")
        }
        XCTAssertEqual(delay3, 2.0, accuracy: 0.0001)
        XCTAssertEqual(attempt3, 3)
        XCTAssertFalse(force3)

        XCTAssertEqual(
            coordinator.actionForFailure(
                inCycle: cycle,
                didPinPreferred: false,
                forceSystemDefault: false
            ),
            .giveUp
        )
    }

    func testStartCoordinator_ignoresStaleCycleFailures() {
        var coordinator = StartCoordinator()
        let staleCycle = coordinator.beginCycle()
        _ = coordinator.beginCycle()

        XCTAssertEqual(
            coordinator.actionForFailure(
                inCycle: staleCycle,
                didPinPreferred: true,
                forceSystemDefault: false
            ),
            .ignoreStale
        )
    }

    func testStartCoordinator_successResetsRetryBackoff() {
        var coordinator = StartCoordinator()
        let cycle = coordinator.beginCycle()

        _ = coordinator.actionForFailure(
            inCycle: cycle,
            didPinPreferred: false,
            forceSystemDefault: false
        )
        coordinator.markSuccess()

        guard case let .scheduleRetry(delay, attempt, forceSystemDefault) = coordinator.actionForFailure(
            inCycle: cycle,
            didPinPreferred: false,
            forceSystemDefault: false
        ) else {
            return XCTFail("Expected retry after success reset")
        }
        XCTAssertEqual(delay, 0.5, accuracy: 0.0001)
        XCTAssertEqual(attempt, 1)
        XCTAssertFalse(forceSystemDefault)
    }

    func testShouldPinPreferredDevice_returnsFalseWhenPreferredMatchesDefault() {
        XCTAssertFalse(
            AudioCaptureService.shouldPinPreferredDevice(
                preferredDeviceID: 52,
                defaultDeviceID: 52,
                forceSystemDefault: false
            )
        )
    }

    func testShouldPinPreferredDevice_returnsTrueWhenPreferredDiffersFromDefault() {
        XCTAssertTrue(
            AudioCaptureService.shouldPinPreferredDevice(
                preferredDeviceID: 52,
                defaultDeviceID: 7,
                forceSystemDefault: false
            )
        )
    }

    func testShouldPinPreferredDevice_returnsFalseWhenForcingSystemDefault() {
        XCTAssertFalse(
            AudioCaptureService.shouldPinPreferredDevice(
                preferredDeviceID: 52,
                defaultDeviceID: 7,
                forceSystemDefault: true
            )
        )
    }

    func testShouldAutoRecoverFromStartFailure_returnsFalseForDeviceSwitch() {
        XCTAssertFalse(
            AudioCaptureService.shouldAutoRecoverFromStartFailure(
                preferredDeviceName: nil,
                startReason: "device-switch"
            )
        )
    }

    func testShouldAutoRecoverFromStartFailure_returnsFalseForPreferredDevice() {
        XCTAssertFalse(
            AudioCaptureService.shouldAutoRecoverFromStartFailure(
                preferredDeviceName: "Scarlett Solo USB",
                startReason: "manual-start"
            )
        )
    }

    func testShouldAutoRecoverFromStartFailure_returnsTrueForGenericStartup() {
        XCTAssertTrue(
            AudioCaptureService.shouldAutoRecoverFromStartFailure(
                preferredDeviceName: nil,
                startReason: "manual-start"
            )
        )
    }

    func testInputDeviceStateTransitionsThroughAwaitingSignalAndReady() {
        let query = StubCoreAudioQuery(
            devices: [42],
            streamConfigs: [42: makeStreamConfigData(declaredBufferCount: 1, buffers: [makeAudioBuffer(channels: 1)])],
            names: [42: "USB Mic"],
            formats: [42: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!],
            defaultInputDevice: 42
        )
        let backend = FakeAudioCaptureBackend(
            startInfo: AudioCaptureBackendStartInfo(
                deviceID: 42,
                deviceName: "USB Mic",
                nativeFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
            )
        )

        AudioCaptureService.coreAudioQuery = query
        AudioCaptureService.captureBackendFactory = { _, _, _ in backend }
        AudioCaptureService.audioAuthorizationStatus = { .authorized }

        let service = AudioCaptureService(ringBuffer: RingBuffer(capacity: 32_000))
        service.preferredInputDeviceName = "USB Mic"

        var phases: [AudioInputDeviceStatePhase] = []
        service.onInputDeviceStateChange = { state in
            phases.append(state.phase)
        }

        service.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertTrue(phases.contains(.startedAwaitingCallbacks))

        backend.emitFirstCallback()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertTrue(phases.contains(.awaitingSignal))

        backend.emit(samples: Array(repeating: 0.1, count: 1600))
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(service.inputDeviceState.phase, .ready)
        XCTAssertGreaterThan(service.ringBuffer.availableSamples, 0)
    }

    func testNoCallbackTimeoutMarksSelectedDeviceFailed() {
        let query = StubCoreAudioQuery(
            devices: [7],
            streamConfigs: [7: makeStreamConfigData(declaredBufferCount: 1, buffers: [makeAudioBuffer(channels: 1)])],
            names: [7: "Scarlett"],
            formats: [7: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!],
            defaultInputDevice: 7
        )
        let backend = FakeAudioCaptureBackend(
            startInfo: AudioCaptureBackendStartInfo(
                deviceID: 7,
                deviceName: "Scarlett",
                nativeFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
            )
        )
        let delegate = DelegateSpy()

        AudioCaptureService.coreAudioQuery = query
        AudioCaptureService.captureBackendFactory = { _, _, _ in backend }
        AudioCaptureService.audioAuthorizationStatus = { .authorized }

        let service = AudioCaptureService(ringBuffer: RingBuffer(capacity: 32_000))
        service.delegate = delegate
        service.preferredInputDeviceName = "Scarlett"
        service.startupCallbackTimeout = 0.05

        service.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))

        XCTAssertEqual(service.inputDeviceState.phase, .failed)
        XCTAssertEqual(service.inputDeviceState.detail, "No callbacks from device")
        XCTAssertFalse(delegate.failures.isEmpty)
    }

    func testSetInputDeviceClearsRingBufferAndStartsNewBackend() {
        let query = StubCoreAudioQuery(
            devices: [1, 2],
            streamConfigs: [
                1: makeStreamConfigData(declaredBufferCount: 1, buffers: [makeAudioBuffer(channels: 1)]),
                2: makeStreamConfigData(declaredBufferCount: 1, buffers: [makeAudioBuffer(channels: 1)]),
            ],
            names: [
                1: "Built-in Mic",
                2: "USB Interface",
            ],
            formats: [
                1: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!,
                2: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!,
            ],
            defaultInputDevice: 1
        )
        let firstBackend = FakeAudioCaptureBackend(
            startInfo: AudioCaptureBackendStartInfo(
                deviceID: 1,
                deviceName: "Built-in Mic",
                nativeFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
            )
        )
        let secondBackend = FakeAudioCaptureBackend(
            startInfo: AudioCaptureBackendStartInfo(
                deviceID: 2,
                deviceName: "USB Interface",
                nativeFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
            )
        )
        var backendQueue = [firstBackend, secondBackend]

        AudioCaptureService.coreAudioQuery = query
        AudioCaptureService.captureBackendFactory = { _, _, _ in
            backendQueue.removeFirst()
        }
        AudioCaptureService.audioAuthorizationStatus = { .authorized }

        let service = AudioCaptureService(ringBuffer: RingBuffer(capacity: 32_000))
        service.preferredInputDeviceName = "Built-in Mic"
        service.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))

        firstBackend.emitFirstCallback()
        firstBackend.emit(samples: Array(repeating: 0.2, count: 1600))
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertGreaterThan(service.ringBuffer.availableSamples, 0)

        service.setInputDevice(2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(service.inputDeviceState.phase, .startedAwaitingCallbacks)
        XCTAssertEqual(service.ringBuffer.availableSamples, 0)
        XCTAssertEqual(firstBackend.stopCallCount, 1)

        secondBackend.emitFirstCallback()
        secondBackend.emit(samples: Array(repeating: 0.2, count: 1600))
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(service.inputDeviceState.phase, .ready)
        XCTAssertEqual(service.preferredInputDeviceName, "USB Interface")
        XCTAssertEqual(secondBackend.startedDeviceID, 2)
    }

    func testSetContinuousModeOnWarmCaptureDoesNotRestartBackend() {
        let query = StubCoreAudioQuery(
            devices: [9],
            streamConfigs: [9: makeStreamConfigData(declaredBufferCount: 1, buffers: [makeAudioBuffer(channels: 1)])],
            names: [9: "Desk Mic"],
            formats: [9: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!],
            defaultInputDevice: 9
        )
        let backend = FakeAudioCaptureBackend(
            startInfo: AudioCaptureBackendStartInfo(
                deviceID: 9,
                deviceName: "Desk Mic",
                nativeFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
            )
        )

        AudioCaptureService.coreAudioQuery = query
        AudioCaptureService.captureBackendFactory = { _, _, _ in backend }
        AudioCaptureService.audioAuthorizationStatus = { .authorized }

        let service = AudioCaptureService(ringBuffer: RingBuffer(capacity: 32_000))
        service.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))

        backend.emitFirstCallback()
        backend.emit(samples: Array(repeating: 0.15, count: 1600))
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))

        XCTAssertTrue(service.isRunning)
        XCTAssertFalse(service.continuousMode)
        XCTAssertEqual(backend.startCallCount, 1)
        XCTAssertEqual(backend.stopCallCount, 0)

        service.setContinuousMode(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))

        XCTAssertTrue(service.continuousMode)
        XCTAssertEqual(backend.startCallCount, 1)
        XCTAssertEqual(backend.stopCallCount, 0)

        service.setContinuousMode(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))

        XCTAssertFalse(service.continuousMode)
        XCTAssertEqual(backend.startCallCount, 1)
        XCTAssertEqual(backend.stopCallCount, 0)
    }

    func testExtractManualRecordingWaitsBrieflyForTrailingCallback() {
        let query = StubCoreAudioQuery(
            devices: [11],
            streamConfigs: [11: makeStreamConfigData(declaredBufferCount: 1, buffers: [makeAudioBuffer(channels: 1)])],
            names: [11: "Built-in Mic"],
            formats: [11: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!],
            defaultInputDevice: 11
        )
        let backend = FakeAudioCaptureBackend(
            startInfo: AudioCaptureBackendStartInfo(
                deviceID: 11,
                deviceName: "Built-in Mic",
                nativeFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
            )
        )

        AudioCaptureService.coreAudioQuery = query
        AudioCaptureService.captureBackendFactory = { _, _, _ in backend }
        AudioCaptureService.audioAuthorizationStatus = { .authorized }

        let service = AudioCaptureService(ringBuffer: RingBuffer(capacity: 32_000))
        service.manualStopTailFlushTimeout = 0.05
        service.start()

        let initialSamples = Array(repeating: Float(0.2), count: 2_400)
        let trailingSamples = Array(repeating: Float(0.25), count: 2_400)
        service.markRecordingStart()
        backend.emit(samples: initialSamples)

        let trailingCallbackDelivered = expectation(description: "Trailing callback delivered")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) {
            backend.emit(samples: trailingSamples)
            trailingCallbackDelivered.fulfill()
        }

        let recording = service.extractManualRecording(minDuration: 0.1)

        wait(for: [trailingCallbackDelivered], timeout: 0.2)
        guard let recording else {
            return XCTFail("Expected trailing callback samples to be included in manual extraction")
        }
        XCTAssertEqual(recording.samples.count, initialSamples.count + trailingSamples.count)
        XCTAssertEqual(
            recording.duration,
            Double(initialSamples.count + trailingSamples.count) / 16_000.0,
            accuracy: 0.0001
        )
    }

    func testExtractManualRecordingIncludesSecondTrailingCallbackWithinFollowupWindow() {
        let query = StubCoreAudioQuery(
            devices: [111],
            streamConfigs: [111: makeStreamConfigData(declaredBufferCount: 1, buffers: [makeAudioBuffer(channels: 1)])],
            names: [111: "Followup Mic"],
            formats: [111: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!],
            defaultInputDevice: 111
        )
        let backend = FakeAudioCaptureBackend(
            startInfo: AudioCaptureBackendStartInfo(
                deviceID: 111,
                deviceName: "Followup Mic",
                nativeFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
            )
        )

        AudioCaptureService.coreAudioQuery = query
        AudioCaptureService.captureBackendFactory = { _, _, _ in backend }
        AudioCaptureService.audioAuthorizationStatus = { .authorized }

        let service = AudioCaptureService(ringBuffer: RingBuffer(capacity: 32_000))
        service.manualStopTailFlushTimeout = 0.15
        service.manualStopTailFollowupTimeout = 0.09
        service.start()

        let initialSamples = Array(repeating: Float(0.2), count: 1_600)
        let firstTrailingSamples = Array(repeating: Float(0.25), count: 1_600)
        let secondTrailingSamples = Array(repeating: Float(0.3), count: 1_600)
        service.markRecordingStart()
        backend.emit(samples: initialSamples)

        let callbacksDelivered = expectation(description: "Trailing callbacks delivered")
        callbacksDelivered.expectedFulfillmentCount = 2
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) {
            backend.emit(samples: firstTrailingSamples)
            callbacksDelivered.fulfill()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.07) {
            backend.emit(samples: secondTrailingSamples)
            callbacksDelivered.fulfill()
        }

        let recording = service.extractManualRecording(minDuration: 0.1)

        wait(for: [callbacksDelivered], timeout: 0.3)
        guard let recording else {
            return XCTFail("Expected both late callbacks to be included in manual extraction")
        }
        XCTAssertEqual(
            recording.samples.count,
            initialSamples.count + firstTrailingSamples.count + secondTrailingSamples.count
        )
    }

    func testExtractToggleRecordingWaitsBrieflyForTrailingCallback() {
        let query = StubCoreAudioQuery(
            devices: [12],
            streamConfigs: [12: makeStreamConfigData(declaredBufferCount: 1, buffers: [makeAudioBuffer(channels: 1)])],
            names: [12: "USB Mic"],
            formats: [12: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!],
            defaultInputDevice: 12
        )
        let backend = FakeAudioCaptureBackend(
            startInfo: AudioCaptureBackendStartInfo(
                deviceID: 12,
                deviceName: "USB Mic",
                nativeFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
            )
        )

        AudioCaptureService.coreAudioQuery = query
        AudioCaptureService.captureBackendFactory = { _, _, _ in backend }
        AudioCaptureService.audioAuthorizationStatus = { .authorized }

        let service = AudioCaptureService(ringBuffer: RingBuffer(capacity: 32_000))
        service.manualStopTailFlushTimeout = 0.05
        service.start()

        let trailingSamples = Array(repeating: Float(0.4), count: 2_400)
        service.beginToggleRecording()

        let trailingCallbackDelivered = expectation(description: "Trailing toggle callback delivered")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) {
            backend.emit(samples: trailingSamples)
            trailingCallbackDelivered.fulfill()
        }

        let recording = service.extractToggleRecording(minDuration: 0.1)

        wait(for: [trailingCallbackDelivered], timeout: 0.2)
        guard let recording else {
            return XCTFail("Expected trailing callback samples to be included in toggle extraction")
        }
        XCTAssertEqual(recording.samples.count, trailingSamples.count)
        XCTAssertEqual(recording.duration, Double(trailingSamples.count) / 16_000.0, accuracy: 0.0001)
    }

    func testExtractToggleRecordingFallsBackToDiskWhenRingBufferNoLongerContainsFullRecording() {
        let query = StubCoreAudioQuery(
            devices: [121],
            streamConfigs: [121: makeStreamConfigData(declaredBufferCount: 1, buffers: [makeAudioBuffer(channels: 1)])],
            names: [121: "Long Toggle Mic"],
            formats: [121: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!],
            defaultInputDevice: 121
        )
        let backend = FakeAudioCaptureBackend(
            startInfo: AudioCaptureBackendStartInfo(
                deviceID: 121,
                deviceName: "Long Toggle Mic",
                nativeFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
            )
        )

        AudioCaptureService.coreAudioQuery = query
        AudioCaptureService.captureBackendFactory = { _, _, _ in backend }
        AudioCaptureService.audioAuthorizationStatus = { .authorized }

        let service = AudioCaptureService(ringBuffer: RingBuffer(capacity: 3_200))
        service.manualStopTailFlushTimeout = 0
        service.start()

        let firstChunk = Array(repeating: Float(0.15), count: 3_200)
        let secondChunk = Array(repeating: Float(0.35), count: 3_200)
        service.beginToggleRecording()
        backend.emit(samples: firstChunk)
        backend.emit(samples: secondChunk)

        guard let recording = service.extractToggleRecording(minDuration: 0.1) else {
            return XCTFail("Expected toggle recording to fall back to disk when ring buffer clipped the start")
        }

        XCTAssertEqual(recording.samples.count, firstChunk.count + secondChunk.count)
        XCTAssertEqual(recording.duration, Double(firstChunk.count + secondChunk.count) / 16_000.0, accuracy: 0.0001)
        XCTAssertEqual(recording.samples.first, firstChunk.first)
        XCTAssertEqual(recording.samples.last, secondChunk.last)
    }

    func testExtractToggleRecordingResultRetainsTempFileWhenRequested() {
        let query = StubCoreAudioQuery(
            devices: [122],
            streamConfigs: [122: makeStreamConfigData(declaredBufferCount: 1, buffers: [makeAudioBuffer(channels: 1)])],
            names: [122: "Retain Toggle Mic"],
            formats: [122: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!],
            defaultInputDevice: 122
        )
        let backend = FakeAudioCaptureBackend(
            startInfo: AudioCaptureBackendStartInfo(
                deviceID: 122,
                deviceName: "Retain Toggle Mic",
                nativeFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
            )
        )

        AudioCaptureService.coreAudioQuery = query
        AudioCaptureService.captureBackendFactory = { _, _, _ in backend }
        AudioCaptureService.audioAuthorizationStatus = { .authorized }

        let service = AudioCaptureService(ringBuffer: RingBuffer(capacity: 32_000))
        service.manualStopTailFlushTimeout = 0
        service.start()

        let samples = Array(repeating: Float(0.22), count: 4_800)
        service.beginToggleRecording()
        backend.emit(samples: samples)

        guard let recording = service.extractToggleRecordingResult(
            minDuration: 0.1,
            retainExtractedFile: true
        ) else {
            return XCTFail("Expected retained toggle extraction result")
        }

        XCTAssertEqual(recording.samples.count, samples.count)
        XCTAssertEqual(recording.duration, Double(samples.count) / 16_000.0, accuracy: 0.0001)

        guard let retainedURL = recording.retainedFileURL else {
            return XCTFail("Expected retained temp file URL")
        }
        defer { try? FileManager.default.removeItem(at: retainedURL) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedURL.path))
        XCTAssertEqual(ToggleRecordingBuffer.readSamples(from: retainedURL)?.count, samples.count)
    }

    func testExtractToggleRecordingResultDeletesTempFileWhenNotRetained() {
        let query = StubCoreAudioQuery(
            devices: [123],
            streamConfigs: [123: makeStreamConfigData(declaredBufferCount: 1, buffers: [makeAudioBuffer(channels: 1)])],
            names: [123: "Discard Toggle Mic"],
            formats: [123: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!],
            defaultInputDevice: 123
        )
        let backend = FakeAudioCaptureBackend(
            startInfo: AudioCaptureBackendStartInfo(
                deviceID: 123,
                deviceName: "Discard Toggle Mic",
                nativeFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
            )
        )

        AudioCaptureService.coreAudioQuery = query
        AudioCaptureService.captureBackendFactory = { _, _, _ in backend }
        AudioCaptureService.audioAuthorizationStatus = { .authorized }

        let service = AudioCaptureService(ringBuffer: RingBuffer(capacity: 32_000))
        service.manualStopTailFlushTimeout = 0
        service.start()

        let tempFilesBefore = toggleRecordingTempFiles()
        let samples = Array(repeating: Float(0.19), count: 4_800)
        service.beginToggleRecording()
        backend.emit(samples: samples)

        guard let recording = service.extractToggleRecordingResult(
            minDuration: 0.1,
            retainExtractedFile: false
        ) else {
            return XCTFail("Expected toggle extraction result")
        }

        XCTAssertEqual(recording.samples.count, samples.count)
        XCTAssertNil(recording.retainedFileURL)
        XCTAssertEqual(toggleRecordingTempFiles(), tempFilesBefore)
    }

    func testExtractManualRecordingFallsBackToDiskWhenRingBufferNoLongerContainsFullRecording() {
        let query = StubCoreAudioQuery(
            devices: [13],
            streamConfigs: [13: makeStreamConfigData(declaredBufferCount: 1, buffers: [makeAudioBuffer(channels: 1)])],
            names: [13: "Studio Mic"],
            formats: [13: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!],
            defaultInputDevice: 13
        )
        let backend = FakeAudioCaptureBackend(
            startInfo: AudioCaptureBackendStartInfo(
                deviceID: 13,
                deviceName: "Studio Mic",
                nativeFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
            )
        )

        AudioCaptureService.coreAudioQuery = query
        AudioCaptureService.captureBackendFactory = { _, _, _ in backend }
        AudioCaptureService.audioAuthorizationStatus = { .authorized }

        let service = AudioCaptureService(ringBuffer: RingBuffer(capacity: 32_000))
        service.manualStopTailFlushTimeout = 0
        service.start()

        let firstChunk = Array(repeating: Float(0.1), count: 24_000)
        let secondChunk = Array(repeating: Float(0.2), count: 24_000)

        service.markRecordingStart()
        backend.emit(samples: firstChunk)
        backend.emit(samples: secondChunk)

        guard let recording = service.extractManualRecording(minDuration: 0.1) else {
            return XCTFail("Expected manual recording to fall back to disk when ring buffer clipped the start")
        }

        XCTAssertEqual(recording.samples.count, firstChunk.count + secondChunk.count)
        XCTAssertEqual(recording.duration, Double(firstChunk.count + secondChunk.count) / 16_000.0, accuracy: 0.0001)
        XCTAssertEqual(Array(recording.samples.prefix(8)), Array(repeating: Float(0.1), count: 8))
        XCTAssertEqual(Array(recording.samples.suffix(8)), Array(repeating: Float(0.2), count: 8))
    }

    func testExtractManualRecordingDoesNotWaitPastTailFlushTimeout() {
        let query = StubCoreAudioQuery(
            devices: [14],
            streamConfigs: [14: makeStreamConfigData(declaredBufferCount: 1, buffers: [makeAudioBuffer(channels: 1)])],
            names: [14: "Conference Mic"],
            formats: [14: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!],
            defaultInputDevice: 14
        )
        let backend = FakeAudioCaptureBackend(
            startInfo: AudioCaptureBackendStartInfo(
                deviceID: 14,
                deviceName: "Conference Mic",
                nativeFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
            )
        )

        AudioCaptureService.coreAudioQuery = query
        AudioCaptureService.captureBackendFactory = { _, _, _ in backend }
        AudioCaptureService.audioAuthorizationStatus = { .authorized }

        let service = AudioCaptureService(ringBuffer: RingBuffer(capacity: 32_000))
        service.manualStopTailFlushTimeout = 0.05
        service.start()

        let initialSamples = Array(repeating: Float(0.15), count: 2_400)
        let trailingSamples = Array(repeating: Float(0.3), count: 2_400)
        service.markRecordingStart()
        backend.emit(samples: initialSamples)

        let trailingCallbackDelivered = expectation(description: "Slower trailing callback delivered")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) {
            backend.emit(samples: trailingSamples)
            trailingCallbackDelivered.fulfill()
        }

        let recording = service.extractManualRecording(minDuration: 0.1)

        wait(for: [trailingCallbackDelivered], timeout: 0.3)
        guard let recording else {
            return XCTFail("Expected manual recording samples available before timeout to be extracted")
        }
        XCTAssertEqual(recording.samples.count, initialSamples.count)
        XCTAssertEqual(recording.duration, Double(initialSamples.count) / 16_000.0, accuracy: 0.0001)
    }

    private func makeAudioBuffer(channels: UInt32) -> AudioBuffer {
        AudioBuffer(mNumberChannels: channels, mDataByteSize: 0, mData: nil)
    }

    private func makeStreamConfigData(declaredBufferCount: UInt32, buffers: [AudioBuffer]) -> Data {
        var data = Data()
        var header = declaredBufferCount
        let headerSize = MemoryLayout<UInt32>.size
        let firstBufferOffset = MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.size

        withUnsafeBytes(of: &header) { rawBuffer in
            data.append(contentsOf: rawBuffer)
        }

        if firstBufferOffset > headerSize {
            data.append(contentsOf: repeatElement(0, count: firstBufferOffset - headerSize))
        }

        for var buffer in buffers {
            withUnsafeBytes(of: &buffer) { rawBuffer in
                data.append(contentsOf: rawBuffer)
            }
        }

        return data
    }

    private func toggleRecordingTempFiles() -> Set<String> {
        let tempDirectory = FileManager.default.temporaryDirectory
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: tempDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        return Set(
            urls
                .map(\.lastPathComponent)
                .filter { $0.hasPrefix("toggle_recording_") && $0.hasSuffix(".pcm") }
        )
    }
}
