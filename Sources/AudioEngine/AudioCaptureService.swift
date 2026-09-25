import AudioToolbox
import AVFoundation
import Foundation

public protocol AudioCaptureDelegate: AnyObject {
    func audioCaptureDidStart()
    func audioCaptureDidStop()
    func audioCaptureDidFail(error: Error)
    func audioCaptureDidDetectSpeechStart(timing: SpeechStartTiming)
    func audioCaptureDidDetectSpeechEnd(segment: AudioSegment, timing: SpeechSegmentTiming)
    func audioCaptureDidDiscardSpeechSegment(timing: SpeechSegmentTiming)
    func audioCaptureInputDeviceStateDidChange(_ state: AudioInputDeviceState)
}

public extension AudioCaptureDelegate {
    func audioCaptureDidDetectSpeechStart(timing _: SpeechStartTiming) {}
    func audioCaptureDidDiscardSpeechSegment(timing _: SpeechSegmentTiming) {}
    func audioCaptureInputDeviceStateDidChange(_ state: AudioInputDeviceState) {}
}

public enum AudioInputDeviceStatePhase: Equatable {
    case idle
    case switching
    case startedAwaitingCallbacks
    case awaitingSignal
    case ready
    case failed
}

public struct AudioInputDeviceState: Equatable {
    public let token: Int
    public let deviceName: String
    public let phase: AudioInputDeviceStatePhase
    public let detail: String?
    public let userInitiated: Bool

    public init(
        token: Int,
        deviceName: String,
        phase: AudioInputDeviceStatePhase,
        detail: String? = nil,
        userInitiated: Bool = false
    ) {
        self.token = token
        self.deviceName = deviceName
        self.phase = phase
        self.detail = detail
        self.userInitiated = userInitiated
    }
}

public enum AudioCaptureError: Error, LocalizedError {
    case microphonePermissionDenied
    case engineStartFailed(Error)
    case noInputDevice

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission denied"
        case .engineStartFailed(let error):
            return "Audio engine failed to start: \(error.localizedDescription)"
        case .noInputDevice:
            return "No audio input device available"
        }
    }
}

public struct ToggleRecordingExtraction {
    public let samples: [Float]
    public let duration: Double
    public let retainedFileURL: URL?

    public init(samples: [Float], duration: Double, retainedFileURL: URL?) {
        self.samples = samples
        self.duration = duration
        self.retainedFileURL = retainedFileURL
    }
}

public final class AudioCaptureService {
    private struct ShortSpeechCarryover {
        let startSample: Int
        let detectedAt: Date?
        let expiresAt: Date
    }

    public let ringBuffer: RingBuffer

    public weak var delegate: AudioCaptureDelegate?
    public var continuousMode: Bool = false

    public var energyThreshold: Float = 0.006
    public var silenceTimeout: TimeInterval = 0.5
    public var speechDetector: SpeechDetector?
    public var vadThreshold: Float = 0.35
    public var turboSilenceGate: Bool = false
    public var endpointingProfile: EndpointingProfile = .standard

    public var preferredInputDeviceName: String?
    public var onAudioLevel: ((Float) -> Void)?
    public var onProcessedAudio: (([Float]) -> Void)?
    public var onInputDeviceStateChange: ((AudioInputDeviceState) -> Void)?

    private let targetSampleRate: Double = 16000
    private let targetChannels: AVAudioChannelCount = 1

    private var backend: (any AudioCaptureBackend)?
    public private(set) var isRunning = false
    private var isStartInFlight = false
    private var startCoordinator = StartCoordinator()

    private var vadTimer: Timer?
    private var retryWorkItem: DispatchWorkItem?
    private var startupWatchdogWorkItem: DispatchWorkItem?
    private var callbackStallTimer: Timer?

    private var isSpeaking = false
    /// True while VAD is inside an active speech segment (always-on mode).
    public var isSpeechActive: Bool { isSpeaking }
    private var speechStartSample: Int = 0
    // True while the current speech segment is the continuation of an
    // utterance that was split at the ASR model window. Continuations bypass
    // the minimum-speech-duration gate (they're real speech, not noise blips)
    // and short tails get zero-padded up to the ASR minimum instead of dropped.
    private var speechContinuesAfterWindowSplit = false
    private var speechStartDetectedAt: Date?
    private var lastAcceptedSpeechEndpointAt: Date?
    private var shortSpeechCarryover: ShortSpeechCarryover?
    private var lastSpeechTime: Date = .distantPast
    private var lastDetectionResult: SpeechDetectionResult?
    private var lastHeartbeatSample: Int = 0
    private var lastCallbackAt: Date?

    private var captureEventGeneration: Int = 0
    private var inputDeviceStateToken: Int = 0
    private var activeInputDeviceStateToken: Int = 0
    private var activeInputDeviceName: String = "System Default"
    private var activeInputStateUserInitiated = false
    private var lastBufferObservedCycleID: Int?
    private var lastSignalObservedCycleID: Int?

    private var manualRecordingStartSample: Int?
    private let manualRecordingBuffer = ToggleRecordingBuffer()
    private let toggleRecordingBuffer = ToggleRecordingBuffer()
    private let processedAudioCondition = NSCondition()
    private var processedAudioGeneration: UInt64 = 0

    private(set) public var currentLevel: Float = 0
    private(set) public var inputDeviceState = AudioInputDeviceState(
        token: 0,
        deviceName: "System Default",
        phase: .idle
    )

    internal static var coreAudioQuery: any CoreAudioQuerying = SystemCoreAudioQuery()
    internal static var captureBackendFactory: (_ query: any CoreAudioQuerying, _ targetSampleRate: Double, _ targetChannels: AVAudioChannelCount) -> any AudioCaptureBackend = {
        query,
        targetSampleRate,
        targetChannels in
        HALAudioCaptureService(
            query: query,
            targetSampleRate: targetSampleRate,
            targetChannels: targetChannels
        )
    }
    internal static var audioAuthorizationStatus: () -> AVAuthorizationStatus = {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }
    internal static var requestAudioAccess: (@escaping (Bool) -> Void) -> Void = { completion in
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    }

    internal var startupCallbackTimeout: TimeInterval = 1.5
    internal var callbackStallTimeout: TimeInterval = 2.0
    /// How long audio must flow after a start before retries are considered recovered.
    internal var sustainedAudioResetInterval: TimeInterval = 10.0
    private var captureStartedAt: Date?
    // Adaptive tail flush budget. The flush returns early once trailing audio
    // RMS falls below the silence threshold, so clean releases don't pay the
    // full wait — only mid-syllable releases do. The followup budget must cover
    // anticipatory key release (users let go of fn ~200-500ms before the last
    // word ends) plus Bluetooth mic input latency (AirPods ~150-230ms).
    internal var manualStopTailFlushTimeout: TimeInterval = 0.15
    internal var manualStopTailFollowupTimeout: TimeInterval = 0.55
    // Sentence-final syllables trail off quietly; -42dBFS keeps them counted as
    // speech while staying above typical room/mic noise floors.
    internal var manualStopTailSilenceRMSThreshold: Float = 0.008
    internal var manualStopTailSilenceWindow: TimeInterval = 0.10
    // Tighter budget for the always-on VAD speech-end path so transcript
    // turnaround stays snappy. Adaptive logic still exits on silence.
    internal var vadStopTailInitialWait: TimeInterval = 0.08
    internal var vadStopTailFollowupBudget: TimeInterval = 0.12
    public init(ringBuffer: RingBuffer? = nil) {
        self.ringBuffer = ringBuffer ?? RingBuffer(capacity: 480_000)
    }

    deinit {
        retryWorkItem?.cancel()
        startupWatchdogWorkItem?.cancel()
        callbackStallTimer?.invalidate()
        vadTimer?.invalidate()
        backend?.stop()
    }

    public func start() {
        runOnMain { [weak self] in
            self?.startOnMain(reason: "manual-start")
        }
    }

    public func restart(continuousMode newMode: Bool) {
        runOnMain { [weak self] in
            guard let self else { return }
            self.stopOnMain(invalidateStartCycle: true)
            self.continuousMode = newMode
            self.startOnMain(reason: "mode-restart")
        }
    }

    /// Switch between always-on VAD and warm-manual capture without restarting HAL.
    /// This keeps the menu/app mode toggle responsive when the mic is already active.
    public func setContinuousMode(_ newMode: Bool) {
        runOnMain { [weak self] in
            self?.setContinuousModeOnMain(newMode)
        }
    }

    public func stop() {
        runOnMain { [weak self] in
            self?.stopOnMain(invalidateStartCycle: true)
        }
    }

    public func lastSeconds(_ seconds: Double) -> [Float] {
        ringBuffer.readLast(seconds: seconds)
    }

    public static var availableInputDevices: [(id: AudioDeviceID, name: String)] {
        availableInputDevices(using: coreAudioQuery)
    }

    internal static func availableInputDevices(using query: any CoreAudioQuerying) -> [(id: AudioDeviceID, name: String)] {
        var result: [(id: AudioDeviceID, name: String)] = []
        for device in query.deviceIDs() {
            guard let configData = query.inputStreamConfiguration(deviceID: device) else { continue }
            let channelCount = inputChannelCount(fromStreamConfigurationData: configData)
            guard channelCount > 0 else { continue }
            guard let name = query.deviceName(deviceID: device), !name.isEmpty else { continue }
            result.append((id: device, name: name))
        }
        return result
    }

    internal static func inputChannelCount(fromStreamConfigurationData data: Data) -> Int {
        let headerSize = MemoryLayout<UInt32>.size
        let firstBufferOffset = MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.size
        guard data.count >= firstBufferOffset else { return 0 }

        var declaredBuffers: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &declaredBuffers) { rawBuffer in
            data.copyBytes(to: rawBuffer, from: 0..<headerSize)
        }
        guard declaredBuffers > 0 else { return 0 }

        let audioBufferSize = MemoryLayout<AudioBuffer>.size
        let availableBytes = data.count - firstBufferOffset
        let availableBufferCount = availableBytes / audioBufferSize
        guard availableBufferCount > 0 else { return 0 }

        let bufferCount = min(Int(declaredBuffers), availableBufferCount)
        var channelCount = 0
        for index in 0..<bufferCount {
            let start = firstBufferOffset + (index * audioBufferSize)
            let end = start + audioBufferSize
            guard end <= data.count else { break }
            var audioBuffer = AudioBuffer()
            _ = withUnsafeMutableBytes(of: &audioBuffer) { rawBuffer in
                data.copyBytes(to: rawBuffer, from: start..<end)
            }
            channelCount += Int(audioBuffer.mNumberChannels)
        }
        return channelCount
    }

    internal static func normalizedTapFormat(from format: AVAudioFormat) -> AVAudioFormat? {
        guard format.sampleRate > 0, format.channelCount > 0 else { return nil }
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: format.channelCount,
            interleaved: false
        )
    }

    internal static func shouldPinPreferredDevice(
        preferredDeviceID: AudioDeviceID,
        defaultDeviceID: AudioDeviceID?,
        forceSystemDefault: Bool
    ) -> Bool {
        guard !forceSystemDefault else { return false }
        guard let defaultDeviceID else { return true }
        return preferredDeviceID != defaultDeviceID
    }

    internal static func shouldAutoRecoverFromStartFailure(
        preferredDeviceName: String?,
        startReason: String
    ) -> Bool {
        guard preferredDeviceName == nil else { return false }
        return startReason != "device-switch"
    }

    public func setInputDevice(_ deviceID: AudioDeviceID) {
        runOnMain { [weak self] in
            self?.setInputDeviceOnMain(deviceID)
        }
    }

    public func markRecordingStart() {
        manualRecordingBuffer.begin()
        manualRecordingStartSample = ringBuffer.totalSamplesWritten
        #if DEBUG
        print("[Audio] Manual recording started at sample \(manualRecordingStartSample!)")
        #endif
    }

    public func extractManualRecording(minDuration: Double = 0.1) -> (samples: [Float], duration: Double)? {
        guard let result = extractManualRecordingResult(minDuration: minDuration) else {
            return nil
        }
        return (samples: result.samples, duration: result.duration)
    }

    public func extractManualRecordingResult(minDuration: Double = 0.1) -> ToggleRecordingExtraction? {
        guard let startSample = manualRecordingStartSample else {
            #if DEBUG
            print("[Audio] extractManualRecording — no start sample set")
            #endif
            return nil
        }
        manualRecordingStartSample = nil

        flushPendingManualTailIfNeeded()

        let diskResult = manualRecordingBuffer.finish()

        if let ringResult = extractCompleteRecordingFromRingBuffer(
            startSample: startSample,
            label: "Manual recording",
            minDuration: minDuration
        ) {
            if let diskResult,
               diskResult.sampleCount == ringResult.samples.count {
                cleanupExtractedRecordingFile(diskResult.url)
                return ToggleRecordingExtraction(
                    samples: ringResult.samples,
                    duration: ringResult.duration,
                    retainedFileURL: nil
                )
            }

            if diskResult == nil {
                return ToggleRecordingExtraction(
                    samples: ringResult.samples,
                    duration: ringResult.duration,
                    retainedFileURL: nil
                )
            }
        }

        return finishManualRecordingBuffer(
            diskResult: diskResult,
            fallbackStartSample: startSample,
            label: "Manual recording",
            missingDebugMessage: "[Audio] extractManualRecording — no start sample set",
            minDuration: minDuration,
            shouldFlushTail: false,
            retainExtractedFile: false
        )
    }

    public func cancelManualRecording() {
        manualRecordingBuffer.cancel()
        manualRecordingStartSample = nil
        #if DEBUG
        print("[Audio] Manual recording cancelled")
        #endif
    }

    // MARK: - Toggle Recording (spill-to-disk)

    /// Start streaming audio to a temp file for toggle recordings.
    public func beginToggleRecording() {
        toggleRecordingBuffer.begin()
        // Also mark ring buffer position for realtime engine streaming
        manualRecordingStartSample = ringBuffer.totalSamplesWritten
        #if DEBUG
        print("[Audio] Toggle recording started (disk-backed)")
        #endif
    }

    /// Extract the full toggle recording from disk.
    public func extractToggleRecording(minDuration: Double = 0.1) -> (samples: [Float], duration: Double)? {
        guard let result = extractToggleRecordingResult(minDuration: minDuration) else {
            return nil
        }
        return (samples: result.samples, duration: result.duration)
    }

    /// Extract the full toggle recording and optionally keep the temp PCM for retry/download.
    public func extractToggleRecordingResult(
        minDuration: Double = 0.1,
        retainExtractedFile: Bool = false
    ) -> ToggleRecordingExtraction? {
        let startSample = manualRecordingStartSample
        manualRecordingStartSample = nil

        flushPendingManualTailIfNeeded()

        let diskResult = toggleRecordingBuffer.finish()

        if let startSample,
           let ringResult = extractCompleteRecordingFromRingBuffer(
               startSample: startSample,
               label: "Toggle recording",
               minDuration: minDuration
           ) {
            if let diskResult,
               diskResult.sampleCount == ringResult.samples.count {
                let retainedFileURL = retainExtractedFile ? diskResult.url : nil
                if !retainExtractedFile {
                    cleanupExtractedRecordingFile(diskResult.url)
                }
                return ToggleRecordingExtraction(
                    samples: ringResult.samples,
                    duration: ringResult.duration,
                    retainedFileURL: retainedFileURL
                )
            }

            if diskResult == nil {
                return ToggleRecordingExtraction(
                    samples: ringResult.samples,
                    duration: ringResult.duration,
                    retainedFileURL: nil
                )
            }
        }

        return finishManualRecordingBuffer(
            diskResult: diskResult,
            fallbackStartSample: startSample,
            label: "Toggle recording",
            missingDebugMessage: "[Audio] extractToggleRecording — no active recording or empty",
            minDuration: minDuration,
            shouldFlushTail: false,
            retainExtractedFile: retainExtractedFile
        )
    }

    /// Cancel toggle recording and delete temp file.
    public func cancelToggleRecording() {
        toggleRecordingBuffer.cancel()
        manualRecordingStartSample = nil
        #if DEBUG
        print("[Audio] Toggle recording cancelled")
        #endif
    }

    /// Whether a toggle recording is currently active.
    public var isToggleRecordingActive: Bool {
        toggleRecordingBuffer.isActive
    }

    /// Current duration of active toggle recording.
    public var toggleRecordingDuration: Double {
        toggleRecordingBuffer.duration
    }

    private func runOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    private func flushPendingManualTailIfNeeded(
        initialWait: TimeInterval? = nil,
        followupBudget: TimeInterval? = nil,
        silenceConfirmations: Int = 2
    ) {
        let firstWait = initialWait ?? manualStopTailFlushTimeout
        let followup = followupBudget ?? manualStopTailFollowupTimeout
        guard isRunning, firstWait > 0 else { return }

        let totalBudget = firstWait + followup
        let deadline = Date().addingTimeInterval(totalBudget)
        let flushStartedAt = Date()
        let samplesAtFlushStart = ringBuffer.totalSamplesWritten
        var flushExitReason = "no-first-slice"
        defer {
            #if DEBUG
            let waitedMs = Int(Date().timeIntervalSince(flushStartedAt) * 1000)
            let gainedSamples = ringBuffer.totalSamplesWritten - samplesAtFlushStart
            let gainedMs = Int(Double(gainedSamples) / targetSampleRate * 1000)
            let tailRMS = trailingTailRMS().map { String(format: "%.4f", $0) } ?? "n/a"
            print(
                "[Audio] Tail flush — \(flushExitReason), waited \(waitedMs)ms, " +
                "+\(gainedSamples) samples (\(gainedMs)ms), tail rms \(tailRMS)"
            )
            #endif
        }

        // Always wait for at least one more slice to land so any AUHAL audio
        // that was in flight when the user released the key (or VAD declared
        // silence) gets into the ring buffer before we decide whether the
        // tail is silent.
        var observedGeneration = currentProcessedAudioGeneration()
        let firstWaitTimeout = min(firstWait, max(0, deadline.timeIntervalSinceNow))
        guard firstWaitTimeout > 0,
              waitForNextProcessedAudioCallback(
                  after: observedGeneration,
                  timeout: firstWaitTimeout
              ) else {
            return
        }

        // Keep waiting for more slices while the trailing audio still looks
        // like speech. Exit once the tail has read as silent for
        // `silenceConfirmations` consecutive slices — a single silent window
        // is not enough on the PTT path because stop-consonant closures
        // ("stop", "that") contain 30-100ms of true silence before the release
        // burst; exiting inside the closure clips the final consonant. The
        // confirmation costs one extra HAL slice (~10-100ms) on clean releases.
        var consecutiveSilentSlices = 0
        while true {
            if isTrailingAudioSilent() {
                consecutiveSilentSlices += 1
                if consecutiveSilentSlices >= silenceConfirmations {
                    flushExitReason = "silence-confirmed"
                    return
                }
            } else {
                consecutiveSilentSlices = 0
            }

            observedGeneration = currentProcessedAudioGeneration()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                flushExitReason = "budget-exhausted"
                return
            }

            let iterationTimeout = min(remaining, followup)
            guard iterationTimeout > 0,
                  waitForNextProcessedAudioCallback(
                      after: observedGeneration,
                      timeout: iterationTimeout
                  ) else {
                flushExitReason = "no-followup-slice"
                return
            }
        }
    }

    private func trailingTailRMS() -> Float? {
        let windowSamples = Int(targetSampleRate * manualStopTailSilenceWindow)
        guard windowSamples > 0 else { return nil }
        let tail = ringBuffer.readLast(sampleCount: windowSamples)
        guard !tail.isEmpty else { return nil }
        var sumSquares: Float = 0
        for sample in tail {
            sumSquares += sample * sample
        }
        return (sumSquares / Float(tail.count)).squareRoot()
    }

    private func isTrailingAudioSilent() -> Bool {
        guard let rms = trailingTailRMS() else { return true }
        return rms < manualStopTailSilenceRMSThreshold
    }

    private func currentProcessedAudioGeneration() -> UInt64 {
        processedAudioCondition.lock()
        defer { processedAudioCondition.unlock() }
        return processedAudioGeneration
    }

    private func noteProcessedAudioCallback() {
        processedAudioCondition.lock()
        processedAudioGeneration &+= 1
        processedAudioCondition.broadcast()
        processedAudioCondition.unlock()
    }

    @discardableResult
    private func waitForNextProcessedAudioCallback(after generation: UInt64, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        processedAudioCondition.lock()
        defer { processedAudioCondition.unlock() }

        while processedAudioGeneration == generation {
            if !processedAudioCondition.wait(until: deadline) {
                return false
            }
        }
        return true
    }

    private func extractCompleteRecordingFromRingBuffer(
        startSample: Int,
        label: String,
        minDuration: Double
    ) -> (samples: [Float], duration: Double)? {
        let currentTotal = ringBuffer.totalSamplesWritten
        let requestedSampleCount = currentTotal - startSample
        let duration = Double(requestedSampleCount) / targetSampleRate

        guard duration >= minDuration else { return nil }

        let samples = ringBuffer.read(from: startSample, count: requestedSampleCount)
        guard samples.count == requestedSampleCount else { return nil }

        #if DEBUG
        print("[Audio] \(label) extracted (ring fast path) — \(String(format: "%.1f", duration))s, \(samples.count) samples")
        #endif

        return (samples: samples, duration: duration)
    }

    private func finishManualRecordingBuffer(
        diskResult: (url: URL, sampleCount: Int)?,
        fallbackStartSample: Int?,
        label: String,
        missingDebugMessage: String,
        minDuration: Double,
        shouldFlushTail: Bool = true,
        retainExtractedFile: Bool = false
    ) -> ToggleRecordingExtraction? {
        if shouldFlushTail {
            flushPendingManualTailIfNeeded()
        }

        if let diskResult {
            let duration = Double(diskResult.sampleCount) / targetSampleRate
            guard duration >= minDuration else {
                #if DEBUG
                print("[Audio] \(label) too short (\(String(format: "%.2f", duration))s), skipping")
                #endif
                cleanupExtractedRecordingFile(diskResult.url)
                return nil
            }

            if let samples = ToggleRecordingBuffer.readSamples(from: diskResult.url) {
                let retainedFileURL = retainExtractedFile ? diskResult.url : nil
                if !retainExtractedFile {
                    cleanupExtractedRecordingFile(diskResult.url)
                }
                #if DEBUG
                print("[Audio] \(label) extracted — \(String(format: "%.1f", duration))s, \(samples.count) samples")
                #endif
                return ToggleRecordingExtraction(
                    samples: samples,
                    duration: duration,
                    retainedFileURL: retainedFileURL
                )
            }

            #if DEBUG
            print("[Audio] Failed to read \(label.lowercased()) samples from disk — falling back to ring buffer")
            #endif
            cleanupExtractedRecordingFile(diskResult.url)
        }

        guard let fallbackStartSample else {
            #if DEBUG
            print(missingDebugMessage)
            #endif
            return nil
        }

        let currentTotal = ringBuffer.totalSamplesWritten
        let requestedSampleCount = currentTotal - fallbackStartSample
        let samples = ringBuffer.read(from: fallbackStartSample, count: requestedSampleCount)
        let duration = Double(samples.count) / targetSampleRate

        guard duration >= minDuration else {
            #if DEBUG
            print("[Audio] \(label) too short (\(String(format: "%.2f", duration))s), skipping")
            #endif
            return nil
        }

        #if DEBUG
        if samples.count != requestedSampleCount {
            print(
                "[Audio] \(label) ring fallback clipped — " +
                "requested \(requestedSampleCount) samples, extracted \(samples.count)"
            )
        }
        print("[Audio] \(label) extracted (ring fallback) — \(String(format: "%.1f", duration))s, \(samples.count) samples")
        #endif

        return ToggleRecordingExtraction(
            samples: samples,
            duration: duration,
            retainedFileURL: nil
        )
    }

    private func cleanupExtractedRecordingFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func currentSelectedDeviceName(for deviceID: AudioDeviceID? = nil) -> String {
        if let deviceID,
           let match = Self.availableInputDevices.first(where: { $0.id == deviceID }) {
            return match.name
        }
        return preferredInputDeviceName ?? "System Default"
    }

    private func emitInputDeviceState(
        phase: AudioInputDeviceStatePhase,
        detail: String? = nil,
        token: Int? = nil,
        deviceName: String? = nil,
        userInitiated: Bool? = nil
    ) {
        let nextState = AudioInputDeviceState(
            token: token ?? activeInputDeviceStateToken,
            deviceName: deviceName ?? activeInputDeviceName,
            phase: phase,
            detail: detail,
            userInitiated: userInitiated ?? activeInputStateUserInitiated
        )
        inputDeviceState = nextState
        onInputDeviceStateChange?(nextState)
        delegate?.audioCaptureInputDeviceStateDidChange(nextState)
    }

    private func beginInputDeviceStateTransaction(deviceName: String, userInitiated: Bool) -> Int {
        inputDeviceStateToken += 1
        activeInputDeviceStateToken = inputDeviceStateToken
        activeInputDeviceName = deviceName
        activeInputStateUserInitiated = userInitiated
        emitInputDeviceState(
            phase: userInitiated ? .switching : .idle,
            token: activeInputDeviceStateToken,
            deviceName: deviceName,
            userInitiated: userInitiated
        )
        return activeInputDeviceStateToken
    }

    private func resetSpeechDetectionState() {
        isSpeaking = false
        speechStartSample = 0
        speechStartDetectedAt = nil
        lastAcceptedSpeechEndpointAt = nil
        shortSpeechCarryover = nil
        lastSpeechTime = .distantPast
        lastDetectionResult = nil
        speechContinuesAfterWindowSplit = false
    }

    private func resolveSpeechStart(
        at detectedAt: Date,
        defaultStartSample: Int
    ) -> (sample: Int, detectedAt: Date, reusedCarryover: Bool) {
        guard Self.shortSpeechCarryoverWindow(for: endpointingProfile) != nil,
              let carryover = shortSpeechCarryover else {
            return (defaultStartSample, detectedAt, false)
        }

        guard carryover.expiresAt >= detectedAt else {
            shortSpeechCarryover = nil
            return (defaultStartSample, detectedAt, false)
        }

        shortSpeechCarryover = nil
        return (min(defaultStartSample, carryover.startSample), carryover.detectedAt ?? detectedAt, true)
    }

    internal static func shouldRetainShortSpeechCarryover(
        profile: EndpointingProfile,
        previousAcceptedSpeechEndpointAt: Date?,
        currentEndpointDetectedAt: Date,
        hasExistingCarryover: Bool
    ) -> Bool {
        guard let carryoverWindow = shortSpeechCarryoverWindow(for: profile) else { return false }
        if hasExistingCarryover { return true }
        guard let previousAcceptedSpeechEndpointAt else { return false }
        return currentEndpointDetectedAt.timeIntervalSince(previousAcceptedSpeechEndpointAt) <= carryoverWindow
    }

    internal static func shortSpeechCarryoverWindow(
        for profile: EndpointingProfile
    ) -> TimeInterval? {
        switch profile {
        case .stableExtraQuick:
            return 1.2
        case .realtimeParakeet:
            // Realtime turbo can briefly blip between adjacent utterances while the
            // previous session is finalizing. Keep only a short bridge window so
            // we recover clipped restarts without merging unrelated speech.
            return 0.45
        case .standard, .aggressiveParakeet:
            return nil
        }
    }

    private func retainShortSpeechCarryover(endpointDetectedAt: Date) {
        guard let carryoverWindow = Self.shortSpeechCarryoverWindow(for: endpointingProfile) else {
            return
        }
        guard Self.shouldRetainShortSpeechCarryover(
            profile: endpointingProfile,
            previousAcceptedSpeechEndpointAt: lastAcceptedSpeechEndpointAt,
            currentEndpointDetectedAt: endpointDetectedAt,
            hasExistingCarryover: shortSpeechCarryover != nil
        ) else {
            return
        }

        let updatedCarryover = ShortSpeechCarryover(
            startSample: min(shortSpeechCarryover?.startSample ?? speechStartSample, speechStartSample),
            detectedAt: shortSpeechCarryover?.detectedAt ?? speechStartDetectedAt,
            expiresAt: endpointDetectedAt.addingTimeInterval(carryoverWindow)
        )
        shortSpeechCarryover = updatedCarryover
    }

    private func resetCaptureState(clearRingBuffer: Bool) {
        captureEventGeneration += 1
        resetSpeechDetectionState()
        lastHeartbeatSample = 0
        lastBufferObservedCycleID = nil
        lastSignalObservedCycleID = nil
        lastCallbackAt = nil
        manualRecordingStartSample = nil
        if clearRingBuffer {
            ringBuffer.clear()
        }
        currentLevel = 0
        onAudioLevel?(0)
    }

    private func setInputDeviceOnMain(_ deviceID: AudioDeviceID) {
        precondition(Thread.isMainThread, "AudioCaptureService must be used on the main thread")

        let selectedDeviceName = currentSelectedDeviceName(for: deviceID == 0 ? nil : deviceID)

        if let match = Self.availableInputDevices.first(where: { $0.id == deviceID }) {
            preferredInputDeviceName = match.name
        } else if deviceID == 0 {
            preferredInputDeviceName = nil
        }

        _ = beginInputDeviceStateTransaction(deviceName: selectedDeviceName, userInitiated: true)
        _ = startCoordinator.invalidateCycle()
        retryWorkItem?.cancel()
        retryWorkItem = nil
        startupWatchdogWorkItem?.cancel()
        startupWatchdogWorkItem = nil
        callbackStallTimer?.invalidate()
        callbackStallTimer = nil
        resetCaptureState(clearRingBuffer: true)

        if isRunning {
            stopOnMain(invalidateStartCycle: true)
            startOnMain(reason: "device-switch")
        } else {
            emitInputDeviceState(phase: .ready, detail: "Selected — will be used on next start")
        }
    }

    private func setContinuousModeOnMain(_ newMode: Bool) {
        precondition(Thread.isMainThread, "AudioCaptureService must be used on the main thread")
        guard continuousMode != newMode else { return }

        continuousMode = newMode
        resetSpeechDetectionState()

        if newMode, isRunning {
            startVADTimer()
        } else if !newMode {
            vadTimer?.invalidate()
            vadTimer = nil
        }
    }

    private func startOnMain(reason: String) {
        precondition(Thread.isMainThread, "AudioCaptureService must be used on the main thread")
        guard !isRunning else { return }
        guard !isStartInFlight else { return }

        switch Self.audioAuthorizationStatus() {
        case .authorized:
            let startCycleID = startCoordinator.beginCycle()
            if reason != "device-switch" {
                _ = beginInputDeviceStateTransaction(
                    deviceName: currentSelectedDeviceName(),
                    userInitiated: false
                )
            }
            retryWorkItem?.cancel()
            retryWorkItem = nil
            startupWatchdogWorkItem?.cancel()
            startupWatchdogWorkItem = nil
            startCapture(startCycleID: startCycleID, forceSystemDefault: false, startReason: reason)
        case .notDetermined:
            Self.requestAudioAccess { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.startOnMain(reason: reason)
                    } else {
                        self.delegate?.audioCaptureDidFail(error: AudioCaptureError.microphonePermissionDenied)
                    }
                }
            }
        case .denied, .restricted:
            delegate?.audioCaptureDidFail(error: AudioCaptureError.microphonePermissionDenied)
        @unknown default:
            delegate?.audioCaptureDidFail(error: AudioCaptureError.microphonePermissionDenied)
        }
    }

    private func startCapture(startCycleID: Int, forceSystemDefault: Bool, startReason: String) {
        precondition(Thread.isMainThread, "AudioCaptureService must be used on the main thread")
        guard !isRunning else { return }
        guard !isStartInFlight else { return }
        guard startCoordinator.cycleID == startCycleID else { return }

        isStartInFlight = true
        defer { isStartInFlight = false }

        let availableDevices = Self.availableInputDevices(using: Self.coreAudioQuery)
        guard !availableDevices.isEmpty else {
            handleStartFailure(
                startCycleID: startCycleID,
                startReason: startReason,
                forceSystemDefault: forceSystemDefault,
                didPinPreferredDevice: false,
                failureContext: "no input devices",
                delegateError: AudioCaptureError.noInputDevice
            )
            return
        }

        let selectedDeviceID: AudioDeviceID?
        if !forceSystemDefault, let preferred = preferredInputDeviceName {
            if let match = availableDevices.first(where: { $0.name == preferred }) {
                selectedDeviceID = match.id
            } else {
                print("[Audio] Preferred device \"\(preferred)\" not found \u{2014} falling back to system default")
                selectedDeviceID = nil
            }
        } else {
            selectedDeviceID = nil
        }

        let captureBackend = Self.captureBackendFactory(Self.coreAudioQuery, targetSampleRate, targetChannels)
        captureBackend.onFirstCallback = { [weak self] in
            self?.handleFirstCallback(startCycleID: startCycleID)
        }
        captureBackend.onData = { [weak self] samples, rms in
            self?.handleProcessedAudio(samples: samples, rms: rms, startCycleID: startCycleID)
        }

        do {
            let info = try captureBackend.start(deviceID: selectedDeviceID)
            backend = captureBackend
            isRunning = true
            // Don't reset the retry budget just because start() returned: a device can
            // start and then never (or only briefly) deliver audio. The budget resets once
            // audio has flowed steadily — see `noteSustainedAudioIfNeeded`.
            captureStartedAt = Date()
            lastBufferObservedCycleID = nil
            lastSignalObservedCycleID = nil
            lastCallbackAt = nil

            if preferredInputDeviceName == nil {
                activeInputDeviceName = "System Default"
            } else {
                activeInputDeviceName = info.deviceName
            }

            if preferredInputDeviceName != nil || startReason == "device-switch" {
                emitInputDeviceState(phase: .startedAwaitingCallbacks, detail: "Starting…")
            }

            scheduleStartupWatchdog(startCycleID: startCycleID, startReason: startReason, didPinPreferredDevice: selectedDeviceID != nil)
            startCallbackStallMonitor(startCycleID: startCycleID, startReason: startReason, didPinPreferredDevice: selectedDeviceID != nil)

            #if DEBUG
            print("[Audio] HAL capture started (cycle \(startCycleID), device: \(info.deviceName), native: \(Int(info.nativeFormat.sampleRate))Hz/\(info.nativeFormat.channelCount)ch, reason: \(startReason), continuous: \(continuousMode), vad: \(speechDetector != nil ? "silero" : "energy"))")
            #endif

            if continuousMode {
                startVADTimer()
            }
            delegate?.audioCaptureDidStart()
        } catch {
            backend = nil
            handleStartFailure(
                startCycleID: startCycleID,
                startReason: startReason,
                forceSystemDefault: forceSystemDefault,
                didPinPreferredDevice: selectedDeviceID != nil,
                failureContext: "hal start failed",
                delegateError: error
            )
        }
    }

    private func stopOnMain(invalidateStartCycle: Bool) {
        precondition(Thread.isMainThread, "AudioCaptureService must be used on the main thread")

        if invalidateStartCycle {
            _ = startCoordinator.invalidateCycle()
            isStartInFlight = false
            retryWorkItem?.cancel()
            retryWorkItem = nil
            startupWatchdogWorkItem?.cancel()
            startupWatchdogWorkItem = nil
        }

        callbackStallTimer?.invalidate()
        callbackStallTimer = nil
        vadTimer?.invalidate()
        vadTimer = nil

        let wasSpeaking = isSpeaking
        resetCaptureState(clearRingBuffer: false)

        guard isRunning else {
            backend?.stop()
            backend = nil
            return
        }

        isRunning = false
        if wasSpeaking {
            print("[Audio] Stopping while speech in progress — speech will be dropped")
        }

        backend?.stop()
        backend = nil
        delegate?.audioCaptureDidStop()
    }

    /// Resets the start-retry budget only after audio has flowed for a while, so a
    /// start → stall → retry loop runs out of retries instead of looping forever.
    private func noteSustainedAudioIfNeeded() {
        guard let startedAt = captureStartedAt,
              Date().timeIntervalSince(startedAt) >= sustainedAudioResetInterval else { return }
        captureStartedAt = nil
        startCoordinator.markSuccess()
    }

    private func handleFirstCallback(startCycleID: Int) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handleFirstCallback(startCycleID: startCycleID)
            }
            return
        }
        guard startCoordinator.cycleID == startCycleID else { return }
        lastBufferObservedCycleID = startCycleID
        lastCallbackAt = Date()
        if inputDeviceState.phase == .startedAwaitingCallbacks {
            emitInputDeviceState(
                phase: .awaitingSignal,
                detail: "No input detected — speak to test"
            )
        }
    }

    private func handleProcessedAudio(samples: UnsafeBufferPointer<Float>, rms: Float, startCycleID: Int) {
        ringBuffer.write(samples)
        if manualRecordingBuffer.isActive {
            manualRecordingBuffer.append(samples)
        }
        if toggleRecordingBuffer.isActive {
            toggleRecordingBuffer.append(samples)
        }
        noteProcessedAudioCallback()
        if let onProcessedAudio {
            onProcessedAudio(Array(samples))
        }
        updateEnergyVAD(samples: samples, rms: rms)
        updateHeartbeat(rms: rms)

        let normalizedLevel = min(1.0, max(0.0, (log10f(max(rms, 1e-7)) + 3.0) / 3.0))

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.startCoordinator.cycleID == startCycleID else { return }

            self.lastCallbackAt = Date()
            self.noteSustainedAudioIfNeeded()
            self.currentLevel = normalizedLevel
            self.onAudioLevel?(normalizedLevel)

            if rms > 1e-4, self.lastSignalObservedCycleID != startCycleID {
                self.lastSignalObservedCycleID = startCycleID
                if self.inputDeviceState.phase != .failed {
                    self.emitInputDeviceState(phase: .ready, detail: "Ready")
                }
            }
        }
    }

    private func updateEnergyVAD(samples: UnsafeBufferPointer<Float>, rms: Float) {
        guard continuousMode, speechDetector == nil else { return }
        if rms > energyThreshold {
            let now = Date()
            if !isSpeaking {
                isSpeaking = true
                let resolvedStart = resolveSpeechStart(
                    at: now,
                    defaultStartSample: ringBuffer.totalSamplesWritten - samples.count
                )
                speechStartSample = resolvedStart.sample
                speechStartDetectedAt = resolvedStart.detectedAt
                lastDetectionResult = nil
                lastSpeechTime = now
                #if DEBUG
                if resolvedStart.reusedCarryover {
                    print("[VAD] Reusing short carryover for restarted speech")
                }
                print("[VAD] Speech started (energy)")
                #endif
                delegate?.audioCaptureDidDetectSpeechStart(
                    timing: SpeechStartTiming(
                        detectedAt: speechStartDetectedAt ?? now,
                        detector: "energy",
                        profile: endpointingProfile,
                        peakProbability: nil,
                        trailingAverageProbability: nil
                    )
                )
            }
            lastSpeechTime = now
        }
    }

    private func updateHeartbeat(rms: Float) {
        let totalWritten = ringBuffer.totalSamplesWritten
        if totalWritten - lastHeartbeatSample >= Int(targetSampleRate * 10) {
            lastHeartbeatSample = totalWritten
            #if DEBUG
            print("[Audio] Heartbeat — \(totalWritten) samples written, rms: \(String(format: "%.4f", rms)), level: \(String(format: "%.2f", currentLevel))")
            #endif
        }
    }

    private func scheduleStartupWatchdog(startCycleID: Int, startReason: String, didPinPreferredDevice: Bool) {
        startupWatchdogWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.startCoordinator.cycleID == startCycleID else { return }
            guard self.isRunning else { return }
            guard self.lastBufferObservedCycleID != startCycleID else { return }

            self.stopOnMain(invalidateStartCycle: false)
            self.handleStartFailure(
                startCycleID: startCycleID,
                startReason: startReason,
                forceSystemDefault: false,
                didPinPreferredDevice: didPinPreferredDevice,
                failureContext: "no audio callbacks after start",
                delegateError: AudioCaptureError.noInputDevice
            )
        }
        startupWatchdogWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + startupCallbackTimeout, execute: workItem)
    }

    private func startCallbackStallMonitor(startCycleID: Int, startReason: String, didPinPreferredDevice: Bool) {
        callbackStallTimer?.invalidate()
        callbackStallTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            guard self.startCoordinator.cycleID == startCycleID else {
                timer.invalidate()
                return
            }
            guard self.isRunning else {
                timer.invalidate()
                return
            }
            guard let lastCallbackAt = self.lastCallbackAt else { return }
            guard Date().timeIntervalSince(lastCallbackAt) >= self.callbackStallTimeout else { return }

            timer.invalidate()
            self.callbackStallTimer = nil
            self.stopOnMain(invalidateStartCycle: false)
            self.handleStartFailure(
                startCycleID: startCycleID,
                startReason: startReason,
                forceSystemDefault: false,
                didPinPreferredDevice: didPinPreferredDevice,
                failureContext: "audio callbacks stopped",
                delegateError: AudioCaptureError.noInputDevice
            )
        }
    }

    private func handleStartFailure(
        startCycleID: Int,
        startReason: String,
        forceSystemDefault: Bool,
        didPinPreferredDevice: Bool,
        failureContext: String,
        delegateError: Error
    ) {
        let failureMessage: String
        if failureContext == "no audio callbacks after start" || failureContext == "audio callbacks stopped" {
            failureMessage = "No callbacks from device"
        } else {
            failureMessage = delegateError.localizedDescription
        }
        emitInputDeviceState(phase: .failed, detail: failureMessage)

        guard Self.shouldAutoRecoverFromStartFailure(
            preferredDeviceName: preferredInputDeviceName,
            startReason: startReason
        ) else {
            delegate?.audioCaptureDidFail(error: delegateError)
            print("[Audio] Start failed for selected route — \(failureContext)")
            return
        }

        let action = startCoordinator.actionForFailure(
            inCycle: startCycleID,
            didPinPreferred: didPinPreferredDevice,
            forceSystemDefault: forceSystemDefault
        )

        switch action {
        case .ignoreStale:
            return
        case .scheduleRetry(let delay, let attempt, let retryForceSystemDefault):
            delegate?.audioCaptureDidFail(error: delegateError)
            scheduleRetry(
                startCycleID: startCycleID,
                delay: delay,
                attempt: attempt,
                forceSystemDefault: retryForceSystemDefault
            )
        case .giveUp:
            delegate?.audioCaptureDidFail(error: delegateError)
            print("[Audio] Max retries reached for cycle \(startCycleID) — giving up")
        }
    }

    private func scheduleRetry(
        startCycleID: Int,
        delay: TimeInterval,
        attempt: Int,
        forceSystemDefault: Bool
    ) {
        retryWorkItem?.cancel()
        let routeLabel = forceSystemDefault ? "system-default" : "preferred"
        print("[Audio] Scheduling retry \(attempt)/3 in \(String(format: "%.1f", delay))s (cycle \(startCycleID), route: \(routeLabel))")

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.startCoordinator.cycleID == startCycleID else { return }
            guard !self.isRunning else { return }
            self.startCapture(startCycleID: startCycleID, forceSystemDefault: forceSystemDefault, startReason: "retry-\(attempt)")
        }
        retryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func startVADTimer() {
        vadTimer?.invalidate()

        let interval: TimeInterval
        if speechDetector != nil {
            switch endpointingProfile {
            case .standard:
                interval = 0.03
            case .stableExtraQuick, .aggressiveParakeet, .realtimeParakeet:
                interval = 0.02
            }
        } else {
            interval = 0.06
        }
        vadTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkVADState()
        }
    }

    private func checkVADState() {
        guard continuousMode else { return }

        if let detector = speechDetector {
            let vadSamples = ringBuffer.readLast(sampleCount: vadLookbackSampleCount)
            guard vadSamples.count >= 512 else { return }

            let detectionResult = detector.analyzeSpeech(samples: vadSamples)
            let now = Date()
            lastDetectionResult = detectionResult

            if Self.shouldStartSpeech(
                with: detectionResult,
                profile: endpointingProfile,
                vadThreshold: vadThreshold
            ) {
                if !isSpeaking {
                    isSpeaking = true
                    speechContinuesAfterWindowSplit = false
                    let resolvedStart = resolveSpeechStart(
                        at: now,
                        defaultStartSample: ringBuffer.totalSamplesWritten - speechStartPrerollSamples
                    )
                    speechStartSample = resolvedStart.sample
                    speechStartDetectedAt = resolvedStart.detectedAt
                    lastSpeechTime = now
                    #if DEBUG
                    if resolvedStart.reusedCarryover {
                        print("[VAD] Reusing short carryover for restarted speech")
                    }
                    print("[VAD] Speech started (silero peak: \(String(format: "%.2f", detectionResult.peakProbability)), trailingAvg: \(String(format: "%.2f", detectionResult.trailingAverageProbability)))")
                    #endif
                    delegate?.audioCaptureDidDetectSpeechStart(
                        timing: SpeechStartTiming(
                            detectedAt: speechStartDetectedAt ?? now,
                            detector: "silero",
                            profile: endpointingProfile,
                            peakProbability: detectionResult.peakProbability,
                            trailingAverageProbability: detectionResult.trailingAverageProbability
                        )
                    )
                }
            }

            if shouldKeepSpeechAlive(with: detectionResult) {
                lastSpeechTime = now
            }
        }

        guard isSpeaking else { return }

        let currentTotal = ringBuffer.totalSamplesWritten
        let speechSamples = currentTotal - speechStartSample
        let capturedSpeechDuration = Double(speechSamples) / targetSampleRate
        let endpointingSpeechDuration = Self.endpointingSpeechDuration(
            capturedDuration: capturedSpeechDuration,
            profile: endpointingProfile
        )
        let endpointDetectedAt = Date()
        let silenceDuration = endpointDetectedAt.timeIntervalSince(lastSpeechTime)
        let adaptiveTimeout = Self.windowAwareSilenceTimeout(
            adaptiveSilenceTimeout(for: endpointingSpeechDuration),
            speechDuration: endpointingSpeechDuration
        )

        let silenceDetected = silenceDuration >= adaptiveTimeout

        // Still mid-speech but about to outgrow the ASR model window — split
        // seamlessly instead of letting the segment grow into chunk-merge
        // territory where seam heuristics can drop words.
        if !silenceDetected, capturedSpeechDuration >= Self.modelWindowSplitDuration {
            splitSpeechSegmentAtModelWindow(
                currentTotal: currentTotal,
                speechSampleCount: speechSamples,
                speechDuration: endpointingSpeechDuration,
                silenceTimeoutUsed: adaptiveTimeout,
                endpointDetectedAt: endpointDetectedAt
            )
            return
        }

        if silenceDetected {
            isSpeaking = false

            let timing = SpeechSegmentTiming(
                speechDetectedAt: speechStartDetectedAt,
                lastVoiceActivityAt: lastSpeechTime,
                endpointDetectedAt: endpointDetectedAt,
                endpointLatency: endpointDetectedAt.timeIntervalSince(lastSpeechTime),
                silenceTimeoutUsed: adaptiveTimeout,
                speechDuration: endpointingSpeechDuration,
                detector: speechDetector != nil ? "silero" : "energy",
                profile: endpointingProfile,
                peakProbability: lastDetectionResult?.peakProbability,
                trailingMaxProbability: lastDetectionResult?.trailingMaxProbability,
                trailingAverageProbability: lastDetectionResult?.trailingAverageProbability
            )

            // Continuation segments after a model-window split bypass the
            // minimum-duration gate: they are by definition real speech, and
            // discarding one would drop the tail of a long utterance.
            guard speechContinuesAfterWindowSplit || Self.meetsMinimumSpeechDuration(
                capturedDuration: capturedSpeechDuration,
                profile: endpointingProfile,
                speechStartDetectedAt: speechStartDetectedAt,
                previousSegmentEndedAt: lastAcceptedSpeechEndpointAt
            ) else {
                retainShortSpeechCarryover(endpointDetectedAt: endpointDetectedAt)
                #if DEBUG
                print("[VAD] Speech too short (\(String(format: "%.2f", endpointingSpeechDuration))s speech), skipping")
                #endif
                let eventGeneration = captureEventGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard self.captureEventGeneration == eventGeneration else { return }
                    self.delegate?.audioCaptureDidDiscardSpeechSegment(timing: timing)
                }
                speechStartDetectedAt = nil
                lastDetectionResult = nil
                return
            }

            // Catch any AUHAL slice still in flight when silence tripped —
            // otherwise the final word can be clipped (~12% rate observed in
            // the wild). Tighter budget than PTT since always-on users
            // expect snappy turnaround. Returns immediately on silence.
            // Single silence confirmation here: VAD's own hangover already
            // guarantees the utterance ended in real silence, so the PTT-path
            // plosive-closure guard isn't needed and would cost turnaround.
            flushPendingManualTailIfNeeded(
                initialWait: vadStopTailInitialWait,
                followupBudget: vadStopTailFollowupBudget,
                silenceConfirmations: 1
            )

            // Anchor the read window explicitly — readLast(sampleCount:) computes
            // its window at read time, so an audio slice landing between the size
            // computation and the read would shift the window forward and clip
            // the start of the segment.
            let postFlushTotal = ringBuffer.totalSamplesWritten
            let postFlushSpeechSamples = postFlushTotal - speechStartSample
            let samplesToRead = min(postFlushSpeechSamples, Int(30.0 * targetSampleRate))
            var samples = ringBuffer.read(from: postFlushTotal - samplesToRead, count: samplesToRead)
            if speechContinuesAfterWindowSplit, samples.count < 16_000 {
                // A tail shorter than the ASR's 1s minimum would be dropped
                // downstream — pad with silence so the last words of a split
                // utterance always transcribe.
                samples.append(contentsOf: [Float](repeating: 0, count: 16_000 - samples.count))
            }
            speechContinuesAfterWindowSplit = false
            let segment = AudioSegment(samples: samples, sampleRate: Int(targetSampleRate), timestamp: endpointDetectedAt)
            speechStartDetectedAt = nil
            lastAcceptedSpeechEndpointAt = endpointDetectedAt
            lastDetectionResult = nil

            #if DEBUG
            print(
                "[VAD] Speech ended — \(String(format: "%.1f", endpointingSpeechDuration))s speech, " +
                "captured \(String(format: "%.1f", capturedSpeechDuration))s, sending \(samples.count) samples"
            )
            #endif

            let eventGeneration = captureEventGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.captureEventGeneration == eventGeneration else { return }
                self.delegate?.audioCaptureDidDetectSpeechEnd(segment: segment, timing: timing)
            }
        }
    }

    // FluidAudio's Parakeet encoder window is 15s (240k samples). Segments
    // longer than one window get chunk-merged with overlap heuristics that can
    // drop words at the seam (observed in the wild: a 16.5s always-on segment
    // lost everything past ~15s). Always-on endpointing therefore keeps every
    // segment inside a single window: the silence gate tightens as an utterance
    // approaches the window, and at the split threshold the segment is emitted
    // mid-speech with capture continuing from the exact boundary sample.
    internal static let modelWindowSplitDuration: TimeInterval = 14.0

    internal static func windowAwareSilenceTimeout(
        _ timeout: TimeInterval,
        speechDuration: TimeInterval
    ) -> TimeInterval {
        if speechDuration >= 13.0 { return min(timeout, 0.06) }
        if speechDuration >= 11.0 { return min(timeout, 0.10) }
        return timeout
    }

    /// Emit the current speech segment and keep capturing without a gap.
    ///
    /// The next segment starts at the exact sample where this one ends — no
    /// preroll (which would duplicate the boundary words) and no dropped
    /// audio. Downstream the two transcriptions concatenate with a space, so
    /// the split is invisible to the user.
    private func splitSpeechSegmentAtModelWindow(
        currentTotal: Int,
        speechSampleCount: Int,
        speechDuration: TimeInterval,
        silenceTimeoutUsed: TimeInterval,
        endpointDetectedAt: Date
    ) {
        let samples = ringBuffer.read(from: speechStartSample, count: speechSampleCount)
        guard !samples.isEmpty else { return }

        let timing = SpeechSegmentTiming(
            speechDetectedAt: speechStartDetectedAt,
            lastVoiceActivityAt: lastSpeechTime,
            endpointDetectedAt: endpointDetectedAt,
            endpointLatency: 0,
            silenceTimeoutUsed: silenceTimeoutUsed,
            speechDuration: speechDuration,
            detector: speechDetector != nil ? "silero" : "energy",
            profile: endpointingProfile,
            peakProbability: lastDetectionResult?.peakProbability,
            trailingMaxProbability: lastDetectionResult?.trailingMaxProbability,
            trailingAverageProbability: lastDetectionResult?.trailingAverageProbability
        )

        let segment = AudioSegment(samples: samples, sampleRate: Int(targetSampleRate), timestamp: endpointDetectedAt)

        // Continue the utterance as a fresh segment from the boundary.
        speechStartSample = currentTotal
        speechStartDetectedAt = endpointDetectedAt
        lastAcceptedSpeechEndpointAt = endpointDetectedAt
        speechContinuesAfterWindowSplit = true

        #if DEBUG
        print(
            "[VAD] Split at model window — \(String(format: "%.1f", speechDuration))s speech, " +
            "sending \(samples.count) samples, capture continues"
        )
        #endif

        let eventGeneration = captureEventGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.captureEventGeneration == eventGeneration else { return }
            self.delegate?.audioCaptureDidDetectSpeechEnd(segment: segment, timing: timing)
        }
    }

    internal static func minimumSpeechDuration(
        for profile: EndpointingProfile,
        speechStartDetectedAt: Date?,
        previousSegmentEndedAt: Date?
    ) -> TimeInterval {
        switch profile {
        case .standard:
            return 0.8
        case .stableExtraQuick:
            if let speechStartDetectedAt,
               let previousSegmentEndedAt,
               speechStartDetectedAt.timeIntervalSince(previousSegmentEndedAt) <= 0.9 {
                // If we just endpointed and speech restarts quickly, treat the
                // new chunk as a continuation so a fast cutoff doesn't discard it.
                return 0.65
            }
            return 0.8
        case .aggressiveParakeet:
            return 0.18
        case .realtimeParakeet:
            // Filter out breath/click false triggers (0.2-0.3s) that create
            // sessions producing no transcript and delay real speech pickup.
            return 0.35
        }
    }

    internal static func meetsMinimumSpeechDuration(
        capturedDuration: TimeInterval,
        profile: EndpointingProfile,
        speechStartDetectedAt: Date?,
        previousSegmentEndedAt: Date?
    ) -> Bool {
        let minimumDuration = minimumSpeechDuration(
            for: profile,
            speechStartDetectedAt: speechStartDetectedAt,
            previousSegmentEndedAt: previousSegmentEndedAt
        )
        let measuredDuration: TimeInterval
        switch profile {
        case .standard, .stableExtraQuick:
            // Batch always-on profiles historically counted preroll toward the
            // minimum duration. Keeping that behavior preserves short phrases
            // like "hello" that otherwise get discarded by the tighter gate.
            measuredDuration = capturedDuration
        case .aggressiveParakeet, .realtimeParakeet:
            measuredDuration = endpointingSpeechDuration(
                capturedDuration: capturedDuration,
                profile: profile
            )
        }
        return measuredDuration >= minimumDuration
    }

    internal static func shouldStartSpeech(
        with detectionResult: SpeechDetectionResult,
        profile: EndpointingProfile,
        vadThreshold: Float
    ) -> Bool {
        switch profile {
        case .realtimeParakeet:
            let trailingAverageThreshold = max(0.08, vadThreshold * 0.38)
            return detectionResult.peakProbability > vadThreshold &&
                detectionResult.trailingAverageProbability > trailingAverageThreshold
        case .standard, .stableExtraQuick, .aggressiveParakeet:
            return detectionResult.peakProbability > vadThreshold
        }
    }

    private func shouldKeepSpeechAlive(with detectionResult: SpeechDetectionResult) -> Bool {
        switch endpointingProfile {
        case .standard:
            return detectionResult.peakProbability > vadThreshold
        case .stableExtraQuick:
            let trailingMaxThreshold = max(0.20, vadThreshold * 0.72)
            let trailingAverageThreshold = max(0.10, vadThreshold * 0.42)
            return detectionResult.trailingMaxProbability > trailingMaxThreshold ||
                detectionResult.trailingAverageProbability > trailingAverageThreshold
        case .aggressiveParakeet, .realtimeParakeet:
            let trailingMaxThreshold = max(0.18, vadThreshold * 0.68)
            let trailingAverageThreshold = max(0.08, vadThreshold * 0.38)
            return detectionResult.trailingMaxProbability > trailingMaxThreshold ||
                detectionResult.trailingAverageProbability > trailingAverageThreshold
        }
    }

    internal static func adaptiveSilenceTimeout(
        for speechDuration: TimeInterval,
        profile: EndpointingProfile,
        configuredSilenceTimeout: TimeInterval,
        turboSilenceGate: Bool
    ) -> TimeInterval {
        switch profile {
        case .standard:
            let scale = min(max(configuredSilenceTimeout / 0.5, 0.80), 1.25)
            let baseTimeout: TimeInterval
            let lowerBound: TimeInterval
            let upperBound: TimeInterval

            if speechDuration < 1.5 {
                baseTimeout = 0.10
                lowerBound = 0.08
                upperBound = 0.14
            } else if speechDuration < 5.0 {
                baseTimeout = 0.20
                lowerBound = 0.16
                upperBound = 0.26
            } else {
                baseTimeout = 0.35
                lowerBound = 0.28
                upperBound = 0.45
            }

            return min(max(baseTimeout * scale, lowerBound), upperBound)
        case .stableExtraQuick:
            let scale = min(max(configuredSilenceTimeout / 0.5, 0.75), 1.20)
            let baseTimeout: TimeInterval
            let lowerBound: TimeInterval
            let upperBound: TimeInterval

            if speechDuration < 1.5 {
                baseTimeout = 0.06
                lowerBound = 0.05
                upperBound = 0.10
            } else if speechDuration < 5.0 {
                baseTimeout = 0.12
                lowerBound = 0.10
                upperBound = 0.18
            } else {
                baseTimeout = 0.22
                lowerBound = 0.18
                upperBound = 0.32
            }

            return min(max(baseTimeout * scale, lowerBound), upperBound)
        case .aggressiveParakeet:
            let scale = min(max(configuredSilenceTimeout / 0.5, 0.45), 1.6)
            let baseTimeout: TimeInterval
            let lowerBound: TimeInterval
            let upperBound: TimeInterval

            if speechDuration < 1.0 {
                baseTimeout = 0.05
                lowerBound = 0.04
                upperBound = 0.18
            } else if speechDuration < 3.0 {
                baseTimeout = 0.08
                lowerBound = 0.05
                upperBound = 0.25
            } else {
                baseTimeout = 0.12
                lowerBound = 0.07
                upperBound = 0.35
            }

            return min(max(baseTimeout * scale, lowerBound), upperBound)
        case .realtimeParakeet:
            // Keep the 20ms poll loop stable: allow user tuning, but never
            // dip below the proven fast floor or above the pause-tolerant cap.
            let scale = min(max(configuredSilenceTimeout / 0.5, 0.70), 1.35)
            let baseTimeout: TimeInterval
            let lowerBound: TimeInterval
            let upperBound: TimeInterval

            if turboSilenceGate {
                if speechDuration < 1.0 {
                    baseTimeout = 0.055
                    lowerBound = 0.050
                    upperBound = 0.110
                } else if speechDuration < 3.0 {
                    baseTimeout = 0.085
                    lowerBound = 0.070
                    upperBound = 0.150
                } else {
                    baseTimeout = 0.120
                    lowerBound = 0.100
                    upperBound = 0.200
                }
            } else {
                if speechDuration < 1.0 {
                    baseTimeout = 0.080
                    lowerBound = 0.055
                    upperBound = 0.120
                } else if speechDuration < 3.0 {
                    baseTimeout = 0.120
                    lowerBound = 0.085
                    upperBound = 0.180
                } else {
                    baseTimeout = 0.180
                    lowerBound = 0.120
                    upperBound = 0.240
                }
            }

            return min(max(baseTimeout * scale, lowerBound), upperBound)
        }
    }

    internal static func endpointingSpeechDuration(
        capturedDuration: TimeInterval,
        profile: EndpointingProfile
    ) -> TimeInterval {
        let prerollDuration = Double(speechStartPrerollSamples(for: profile)) / 16_000.0
        return max(0, capturedDuration - prerollDuration)
    }

    private func adaptiveSilenceTimeout(for speechDuration: TimeInterval) -> TimeInterval {
        Self.adaptiveSilenceTimeout(
            for: speechDuration,
            profile: endpointingProfile,
            configuredSilenceTimeout: silenceTimeout,
            turboSilenceGate: turboSilenceGate
        )
    }

    private var vadLookbackSampleCount: Int {
        switch endpointingProfile {
        case .standard, .stableExtraQuick:
            return 8_000
        case .aggressiveParakeet, .realtimeParakeet:
            return 6_400
        }
    }

    private var speechStartPrerollSamples: Int {
        Self.speechStartPrerollSamples(for: endpointingProfile)
    }

    internal static func speechStartPrerollSamples(for profile: EndpointingProfile) -> Int {
        switch profile {
        case .standard, .stableExtraQuick:
            return 8_000
        case .aggressiveParakeet, .realtimeParakeet:
            return 2_400
        }
    }
}
