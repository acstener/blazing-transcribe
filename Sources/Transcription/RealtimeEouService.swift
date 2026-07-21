import AVFoundation
import Foundation
import FluidAudio

private struct ShadowCleanupJob {
    let sessionID: Int
    let revision: Int
    let snapshot: [Float]
    let context: FluidAudioContext
    let startedAt: Date
}

private struct RealtimeEouDiagnostics {
    var sessionStartedAt: Date?
    var rawPartialCallbacks = 0
    var emittedLivePartials = 0
    var droppedEmptyPartials = 0
    var droppedDuplicatePartials = 0
    var shadowScheduled = 0
    var shadowEmitted = 0
    var shadowDroppedEmpty = 0
    var shadowDroppedDuplicate = 0
    var shadowSkippedInFlight = 0
    var shadowSkippedTooShort = 0
    var shadowSkippedStep = 0
    var shadowSkippedNoContext = 0
    var lastShadowLatencyMs = -1
}

private final class CleanupContextBox: @unchecked Sendable {
    let context: FluidAudioContext

    init(_ context: FluidAudioContext) {
        self.context = context
    }
}

public struct RealtimeEouUtteranceResult: Sendable {
    public let text: String
    public let sessionID: Int
    public let timestamp: Date
    public let speechDuration: TimeInterval
    public let usedModelEndpoint: Bool
    public let streamText: String
    public let usedCleanup: Bool
    public let finalizationMode: RealtimeFinalizationMode

    public init(
        text: String,
        sessionID: Int,
        timestamp: Date = Date(),
        speechDuration: TimeInterval,
        usedModelEndpoint: Bool,
        streamText: String,
        usedCleanup: Bool,
        finalizationMode: RealtimeFinalizationMode
    ) {
        self.text = text
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.speechDuration = speechDuration
        self.usedModelEndpoint = usedModelEndpoint
        self.streamText = streamText
        self.usedCleanup = usedCleanup
        self.finalizationMode = finalizationMode
    }
}

public protocol RealtimeEouServiceDelegate: AnyObject {
    func realtimeEouService(_ service: RealtimeEouService, didStartUtterance sessionID: Int)
    func realtimeEouService(_ service: RealtimeEouService, didUpdatePartial update: RealtimePartialUpdate)
    func realtimeEouService(_ service: RealtimeEouService, didFinishUtterance result: RealtimeEouUtteranceResult)
    func realtimeEouService(_ service: RealtimeEouService, didFail error: Error, sessionID: Int?)
}

public final class RealtimeEouService: @unchecked Sendable {
    public weak var delegate: RealtimeEouServiceDelegate?
    public let finalizationMode: RealtimeFinalizationMode
    public let shadowCleanupMode: RealtimeShadowCleanupMode

    private let manager: StreamingEouAsrManager
    private let stateLock = NSLock()
    private let cleanupQueue = DispatchQueue(label: "com.blazing.realtime-eou.cleanup", qos: .utility)

    private var sessionGate = RealtimeSessionGate()
    private var lastPartialText = ""
    private var totalSamplesInSession = 0
    private var usedModelEndpointForCurrentSession = false
    private var cleanupContext: FluidAudioContext?
    private var cleanupWarmupTask: Task<Void, Never>?
    private var shadowSampleBuffer: [Float] = []
    private var shadowCleanupInFlight = false
    private var shadowCleanupRevision = 0
    private var shadowLastScheduledSampleCount = 0
    private var shadowLastEmittedText = ""
    private var diagnostics = RealtimeEouDiagnostics()

    private var shadowCleanupMinSamples: Int {
        // Overlay mode should update less frequently to avoid visual churn/jank.
        shadowCleanupMode == .overlay ? 24_000 : 12_800
    }
    private var shadowCleanupStepSamples: Int {
        // Keep cadence conservative for overlay to reduce competing rewrites.
        shadowCleanupMode == .overlay ? 16_000 : 12_800
    }
    private let maxUtteranceSamples = 16_000 * 30
    private let shadowCleanupWindowSamples = 16_000 * 15
    private let batchRescueMinSamples = 8_000

    private init(
        manager: StreamingEouAsrManager,
        finalizationMode: RealtimeFinalizationMode,
        shadowCleanupMode: RealtimeShadowCleanupMode
    ) {
        self.manager = manager
        self.finalizationMode = finalizationMode
        self.shadowCleanupMode = shadowCleanupMode
    }

    public static func create(
        chunkSize: StreamingChunkSize = .ms160,
        eouDebounceMs: Int = 240,
        finalizationMode: RealtimeFinalizationMode = .pureSpeed,
        shadowCleanupMode: RealtimeShadowCleanupMode = .off
    ) async throws -> RealtimeEouService {
        let manager = StreamingEouAsrManager(chunkSize: chunkSize, eouDebounceMs: eouDebounceMs)
        var modelDir = try await FluidAudioModelStore.ensureRealtimeEou160ModelsAvailable()

        do {
            try await manager.loadModels(modelDir: modelDir)
        } catch {
            #if DEBUG
            print("[RealtimeEOU] Cached Parakeet EOU load failed: \(error.localizedDescription). Re-downloading...")
            #endif
            modelDir = try await FluidAudioModelStore.ensureRealtimeEou160ModelsAvailable(forceRedownload: true)
            try await manager.loadModels(modelDir: modelDir)
        }

        let service = RealtimeEouService(
            manager: manager,
            finalizationMode: finalizationMode,
            shadowCleanupMode: shadowCleanupMode
        )
        await manager.setPartialCallback { [weak service] partialText in
            service?.handlePartialText(partialText)
        }
        await manager.setEouCallback { [weak service] _ in
            guard let service else { return }
            Task {
                if service.finalizationMode == .pureSpeed {
                    await service.finishUtterance(
                        endpointSegment: [],
                        speechDuration: nil,
                        triggeredByModelEndpoint: true
                    )
                } else {
                    service.noteModelEndpointDetected()
                }
            }
        }

        service.startCleanupWarmupIfNeeded()
        return service
    }

    public func setEouDebounceMs(_ value: Int) {
        let mgr = manager
        Task {
            await mgr.updateEouDebounceMs(value)
        }
        debugLog("eou-debounce-updated ms=\(value)")
    }

    public func startUtterance(prerollSamples: [Float]) async throws -> Int {
        let sessionID = try withStateLock {
            let sessionID = try sessionGate.startSession()
            lastPartialText = ""
            totalSamplesInSession = 0
            usedModelEndpointForCurrentSession = false
            shadowSampleBuffer.removeAll(keepingCapacity: true)
            shadowCleanupInFlight = false
            shadowCleanupRevision = 0
            shadowLastScheduledSampleCount = 0
            shadowLastEmittedText = ""
            diagnostics = RealtimeEouDiagnostics()
            diagnostics.sessionStartedAt = Date()
            return sessionID
        }

        debugLog(
            "session-start id=\(sessionID) mode=\(finalizationMode.rawValue) shadow=\(shadowCleanupMode.rawValue) " +
            "preroll_ms=\(Int(Double(prerollSamples.count) / 16.0))"
        )
        notifyStart(sessionID: sessionID)

        if !prerollSamples.isEmpty {
            await appendAudio(samples: prerollSamples)
        }

        return sessionID
    }

    public func appendAudio(samples: [Float]) async {
        let sessionID = withStateLock { sessionGate.activeStreamingSessionID }
        guard let sessionID else { return }
        guard !samples.isEmpty else { return }
        guard let buffer = makeAudioBuffer(samples: samples) else { return }

        withStateLock {
            totalSamplesInSession += samples.count
            shadowSampleBuffer.append(contentsOf: samples)
            if shadowSampleBuffer.count > maxUtteranceSamples {
                shadowSampleBuffer.removeFirst(shadowSampleBuffer.count - maxUtteranceSamples)
            }
        }

        do {
            _ = try await manager.process(audioBuffer: buffer)
            scheduleShadowCleanupIfNeeded(sessionID: sessionID)
        } catch {
            publishFailure(error, sessionID: sessionID)
        }
    }

    public func finishUtterance(
        endpointSegment: [Float],
        speechDuration: TimeInterval?,
        triggeredByModelEndpoint: Bool = false
    ) async {
        let sessionID: Int
        do {
            sessionID = try withStateLock {
                if triggeredByModelEndpoint {
                    usedModelEndpointForCurrentSession = true
                }
                return try sessionGate.beginFinishing()
            }
        } catch RealtimeParakeetServiceError.noActiveUtterance {
            return
        } catch {
            publishFailure(error, sessionID: nil)
            return
        }

        do {
            let rawText = try await manager.finish()
            let streamText = applyRegexFillerCleanup(applyDevTermCorrections(
                rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            ))

            var finalText = streamText
            var usedCleanup = false
            let shadowFallbackText = withStateLock { shadowLastEmittedText }
            let hasShadowCleanupInFlight = withStateLock { shadowCleanupInFlight }
            let lastLivePartialText = withStateLock { lastPartialText }
            let utteranceSnapshot = withStateLock { shadowSampleBuffer }

            if finalizationMode == .speedPlusCleanup {
                if hasShadowCleanupInFlight, !shadowFallbackText.isEmpty {
                    usedCleanup = shadowFallbackText != streamText
                    finalText = shadowFallbackText
                } else if let cleanupContext = withStateLock({ self.cleanupContext }) {
                    var cleanupCandidates: [[Float]] = []
                    if !endpointSegment.isEmpty {
                        cleanupCandidates.append(endpointSegment)
                    }
                    if !utteranceSnapshot.isEmpty {
                        cleanupCandidates.append(utteranceSnapshot)
                    }

                    for candidate in cleanupCandidates where candidate.count >= 12_800 {
                        let cleanupResult = await transcribeCleanup(context: cleanupContext, samples: candidate)
                        let cleanupText = applyRegexFillerCleanup(applyDevTermCorrections(
                            cleanupResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        ))
                        if !cleanupText.isEmpty {
                            usedCleanup = cleanupText != streamText
                            finalText = cleanupText
                            break
                        }
                    }
                }

                if finalText.isEmpty, !shadowFallbackText.isEmpty {
                    usedCleanup = shadowFallbackText != streamText
                    finalText = shadowFallbackText
                }
            }

            if finalText.isEmpty, !lastLivePartialText.isEmpty {
                finalText = lastLivePartialText
                debugLog("final-fallback session=\(sessionID) source=last-live-partial chars=\(lastLivePartialText.count)")
            }

            if finalText.isEmpty,
               let rescuedText = await rescueFinalTranscript(
                endpointSegment: endpointSegment,
                utteranceSnapshot: utteranceSnapshot,
                sessionID: sessionID
               ) {
                usedCleanup = true
                finalText = rescuedText
            }

            guard !finalText.isEmpty else {
                throw RealtimeParakeetServiceError.emptyFinalTranscript
            }

            let result = RealtimeEouUtteranceResult(
                text: finalText,
                sessionID: sessionID,
                speechDuration: speechDuration ?? currentSpeechDurationEstimate(),
                usedModelEndpoint: withStateLock { usedModelEndpointForCurrentSession },
                streamText: streamText,
                usedCleanup: usedCleanup,
                finalizationMode: finalizationMode
            )
            notifyFinish(result)
            debugLog(
                diagnosticsSummaryLine(
                    outcome: "finish",
                    sessionID: sessionID,
                    finalChars: finalText.count,
                    usedCleanup: usedCleanup
                )
            )
        } catch {
            debugLog(
                diagnosticsSummaryLine(
                    outcome: "error",
                    sessionID: sessionID,
                    finalChars: 0,
                    usedCleanup: false,
                    error: error.localizedDescription
                )
            )
            publishFailure(error, sessionID: sessionID)
        }

        await manager.reset()
        withStateLock {
            sessionGate.complete(sessionID: sessionID)
            lastPartialText = ""
            totalSamplesInSession = 0
            usedModelEndpointForCurrentSession = false
            shadowSampleBuffer.removeAll(keepingCapacity: false)
            shadowCleanupInFlight = false
            shadowCleanupRevision = 0
            shadowLastScheduledSampleCount = 0
            shadowLastEmittedText = ""
            diagnostics = RealtimeEouDiagnostics()
        }
    }

    public func cancelUtterance() async {
        withStateLock {
            lastPartialText = ""
            totalSamplesInSession = 0
            usedModelEndpointForCurrentSession = false
            _ = sessionGate.cancelCurrent()
            shadowSampleBuffer.removeAll(keepingCapacity: false)
            shadowCleanupInFlight = false
            shadowCleanupRevision = 0
            shadowLastScheduledSampleCount = 0
            shadowLastEmittedText = ""
            diagnostics = RealtimeEouDiagnostics()
        }
        await manager.reset()
    }

    public func shutdown() async {
        cleanupWarmupTask?.cancel()
        cleanupWarmupTask = nil
        await manager.reset()
    }

    private func noteModelEndpointDetected() {
        withStateLock {
            usedModelEndpointForCurrentSession = true
        }
    }

    private func startCleanupWarmupIfNeeded() {
        guard finalizationMode == .speedPlusCleanup else { return }
        guard withStateLock({ cleanupContext == nil && cleanupWarmupTask == nil }) else { return }

        cleanupWarmupTask = Task { [weak self] in
            guard let self else { return }
            debugLog("cleanup-warmup-start")
            do {
                let context = try await FluidAudioContext.create(version: .v3)
                self.withStateLock {
                    self.cleanupContext = context
                    self.cleanupWarmupTask = nil
                }
                self.debugLog("cleanup-warmup-ready")
            } catch {
                self.withStateLock {
                    self.cleanupWarmupTask = nil
                }
                self.debugLog("cleanup-warmup-failed error=\(error.localizedDescription)")
            }
        }
    }

    private func rescueFinalTranscript(
        endpointSegment: [Float],
        utteranceSnapshot: [Float],
        sessionID: Int
    ) async -> String? {
        var candidates: [[Float]] = []
        if endpointSegment.count >= batchRescueMinSamples {
            candidates.append(endpointSegment)
        }
        if utteranceSnapshot.count >= batchRescueMinSamples {
            candidates.append(utteranceSnapshot)
        }
        guard !candidates.isEmpty else { return nil }

        guard let cleanupContext = await loadCleanupContextIfNeeded(allowLazyLoadInPureSpeed: true) else { return nil }

        for candidate in candidates {
            let rescueResult = await transcribeCleanup(context: cleanupContext, samples: candidate)
            let rescueText = applyRegexFillerCleanup(applyDevTermCorrections(
                rescueResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
            if !rescueText.isEmpty {
                debugLog("final-fallback session=\(sessionID) source=batch-rescue chars=\(rescueText.count)")
                return rescueText
            }
        }

        return nil
    }

    private func loadCleanupContextIfNeeded(allowLazyLoadInPureSpeed: Bool = false) async -> FluidAudioContext? {
        if let existing = withStateLock({ cleanupContext }) {
            return existing
        }

        if let warmupTask = withStateLock({ cleanupWarmupTask }) {
            await warmupTask.value
            return withStateLock({ cleanupContext })
        }

        // In pure-speed mode, don't block the session with a lazy model load.
        // The cleanup context wasn't warmed up, so just skip the rescue.
        guard finalizationMode != .pureSpeed || allowLazyLoadInPureSpeed else {
            debugLog("cleanup-context-skipped source=pure-speed-no-lazy-load")
            return nil
        }

        do {
            let context = try await FluidAudioContext.create(version: .v3)
            withStateLock {
                cleanupContext = context
            }
            let source = finalizationMode == .pureSpeed ? "lazy-rescue-empty-final" : "lazy-rescue"
            debugLog("cleanup-context-ready source=\(source)")
            return context
        } catch {
            let source = finalizationMode == .pureSpeed ? "lazy-rescue-empty-final" : "lazy-rescue"
            debugLog("cleanup-context-failed source=\(source) error=\(error.localizedDescription)")
            return nil
        }
    }

    private func handlePartialText(_ text: String) {
        let payload = withStateLock { () -> RealtimePartialUpdate? in
            guard let sessionID = sessionGate.currentSessionID else { return nil }
            diagnostics.rawPartialCallbacks += 1
            let cleanedText = applyRegexFillerCleanup(applyDevTermCorrections(text.trimmingCharacters(in: .whitespacesAndNewlines)))
            guard !cleanedText.isEmpty else {
                diagnostics.droppedEmptyPartials += 1
                return nil
            }
            guard cleanedText != lastPartialText else {
                diagnostics.droppedDuplicatePartials += 1
                return nil
            }
            lastPartialText = cleanedText
            diagnostics.emittedLivePartials += 1
            return RealtimePartialUpdate(
                text: cleanedText,
                isConfirmed: false,
                confidence: 1.0,
                timestamp: Date(),
                sessionID: sessionID,
                source: .eouLive
            )
        }

        guard let payload else { return }
        notifyPartial(payload)
    }

    private func currentSpeechDurationEstimate() -> TimeInterval {
        withStateLock { Double(totalSamplesInSession) / 16000.0 }
    }

    private func diagnosticsSummaryLine(
        outcome: String,
        sessionID: Int,
        finalChars: Int,
        usedCleanup: Bool,
        error: String? = nil
    ) -> String {
        let snapshot = withStateLock {
            (
                startedAt: diagnostics.sessionStartedAt,
                rawPartials: diagnostics.rawPartialCallbacks,
                emittedLivePartials: diagnostics.emittedLivePartials,
                droppedEmptyPartials: diagnostics.droppedEmptyPartials,
                droppedDuplicatePartials: diagnostics.droppedDuplicatePartials,
                shadowScheduled: diagnostics.shadowScheduled,
                shadowEmitted: diagnostics.shadowEmitted,
                shadowDroppedEmpty: diagnostics.shadowDroppedEmpty,
                shadowDroppedDuplicate: diagnostics.shadowDroppedDuplicate,
                shadowSkippedInFlight: diagnostics.shadowSkippedInFlight,
                shadowSkippedTooShort: diagnostics.shadowSkippedTooShort,
                shadowSkippedStep: diagnostics.shadowSkippedStep,
                shadowSkippedNoContext: diagnostics.shadowSkippedNoContext,
                lastShadowLatencyMs: diagnostics.lastShadowLatencyMs,
                totalSamples: totalSamplesInSession,
                usedModelEndpoint: usedModelEndpointForCurrentSession
            )
        }

        let sessionMs: Int
        if let startedAt = snapshot.startedAt {
            sessionMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        } else {
            sessionMs = -1
        }

        var fields = [
            "session-summary",
            "outcome=\(outcome)",
            "id=\(sessionID)",
            "mode=\(finalizationMode.rawValue)",
            "shadow=\(shadowCleanupMode.rawValue)",
            "session_ms=\(sessionMs)",
            "raw_partials=\(snapshot.rawPartials)",
            "live_emitted=\(snapshot.emittedLivePartials)",
            "live_drop_empty=\(snapshot.droppedEmptyPartials)",
            "live_drop_duplicate=\(snapshot.droppedDuplicatePartials)",
            "shadow_scheduled=\(snapshot.shadowScheduled)",
            "shadow_emitted=\(snapshot.shadowEmitted)",
            "shadow_drop_empty=\(snapshot.shadowDroppedEmpty)",
            "shadow_drop_duplicate=\(snapshot.shadowDroppedDuplicate)",
            "shadow_skip_inflight=\(snapshot.shadowSkippedInFlight)",
            "shadow_skip_too_short=\(snapshot.shadowSkippedTooShort)",
            "shadow_skip_step=\(snapshot.shadowSkippedStep)",
            "shadow_skip_no_context=\(snapshot.shadowSkippedNoContext)",
            "shadow_last_ms=\(snapshot.lastShadowLatencyMs)",
            "model_endpoint=\(snapshot.usedModelEndpoint)",
            "used_cleanup=\(usedCleanup)",
            "total_audio_ms=\(Int(Double(snapshot.totalSamples) / 16.0))",
            "final_chars=\(finalChars)",
        ]
        if let error {
            fields.append("error=\(error)")
        }

        return fields.joined(separator: " ")
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        print("[RTDiag][EOU] \(message)")
        #endif
    }

    private func scheduleShadowCleanupIfNeeded(sessionID: Int) {
        let job = withStateLock { () -> ShadowCleanupJob? in
            guard finalizationMode == .speedPlusCleanup else { return nil }
            guard shadowCleanupMode != .off else { return nil }
            guard sessionGate.activeStreamingSessionID == sessionID else { return nil }
            if shadowCleanupInFlight {
                diagnostics.shadowSkippedInFlight += 1
                return nil
            }
            if shadowSampleBuffer.count < shadowCleanupMinSamples {
                diagnostics.shadowSkippedTooShort += 1
                return nil
            }
            if shadowSampleBuffer.count - shadowLastScheduledSampleCount < shadowCleanupStepSamples {
                diagnostics.shadowSkippedStep += 1
                return nil
            }
            guard let cleanupContext else {
                diagnostics.shadowSkippedNoContext += 1
                return nil
            }

            shadowCleanupInFlight = true
            shadowCleanupRevision += 1
            shadowLastScheduledSampleCount = shadowSampleBuffer.count
            diagnostics.shadowScheduled += 1
            let revision = shadowCleanupRevision
            let startedAt = Date()
            let snapshot: [Float]
            if shadowSampleBuffer.count > shadowCleanupWindowSamples {
                snapshot = Array(shadowSampleBuffer.suffix(shadowCleanupWindowSamples))
            } else {
                snapshot = shadowSampleBuffer
            }

            return ShadowCleanupJob(
                sessionID: sessionID,
                revision: revision,
                snapshot: snapshot,
                context: cleanupContext,
                startedAt: startedAt
            )
        }

        guard let job else { return }

        cleanupQueue.async { [weak self] in
            guard let self else { return }
            let cleanupResult = job.context.transcribe(samples: job.snapshot, context: nil)
            self.handleShadowCleanupResult(
                sessionID: job.sessionID,
                revision: job.revision,
                startedAt: job.startedAt,
                text: cleanupResult.text
            )
        }
    }

    private func handleShadowCleanupResult(
        sessionID: Int,
        revision: Int,
        startedAt: Date,
        text: String
    ) {
        let payload = withStateLock { () -> RealtimePartialUpdate? in
            shadowCleanupInFlight = false
            diagnostics.lastShadowLatencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            guard sessionGate.activeStreamingSessionID == sessionID else { return nil }
            guard revision == shadowCleanupRevision else { return nil }

            let cleanedText = applyRegexFillerCleanup(applyDevTermCorrections(text.trimmingCharacters(in: .whitespacesAndNewlines)))
            guard !cleanedText.isEmpty else {
                diagnostics.shadowDroppedEmpty += 1
                return nil
            }
            guard cleanedText != shadowLastEmittedText else {
                diagnostics.shadowDroppedDuplicate += 1
                return nil
            }
            shadowLastEmittedText = cleanedText
            diagnostics.shadowEmitted += 1

            return RealtimePartialUpdate(
                text: cleanedText,
                isConfirmed: true,
                confidence: 1.0,
                timestamp: Date(),
                sessionID: sessionID,
                source: .shadowCleanup
            )
        }

        guard let payload else { return }
        notifyPartial(payload)
    }

    private func transcribeCleanup(context: FluidAudioContext, samples: [Float]) async -> TranscriptionResult {
        let contextBox = CleanupContextBox(context)
        return await withCheckedContinuation { continuation in
            cleanupQueue.async {
                let result = contextBox.context.transcribe(samples: samples, context: nil)
                continuation.resume(returning: result)
            }
        }
    }

    private func makeAudioBuffer(samples: [Float]) -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channelData = buffer.floatChannelData else { return nil }
        samples.withUnsafeBufferPointer { source in
            channelData[0].update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }

    private func publishFailure(_ error: Error, sessionID: Int?) {
        debugLog(
            "service-failure session=\(sessionID.map(String.init) ?? "unknown") error=\(error.localizedDescription)"
        )
        notifyFailure(error, sessionID: sessionID)
    }

    private func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    private func notifyStart(sessionID: Int) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            delegate?.realtimeEouService(self, didStartUtterance: sessionID)
        }
    }

    private func notifyPartial(_ payload: RealtimePartialUpdate) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            delegate?.realtimeEouService(self, didUpdatePartial: payload)
        }
    }

    private func notifyFinish(_ result: RealtimeEouUtteranceResult) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            delegate?.realtimeEouService(self, didFinishUtterance: result)
        }
    }

    private func notifyFailure(_ error: Error, sessionID: Int?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            delegate?.realtimeEouService(self, didFail: error, sessionID: sessionID)
        }
    }
}
