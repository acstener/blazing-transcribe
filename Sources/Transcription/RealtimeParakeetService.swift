import Foundation
import FluidAudio

public final class RealtimeParakeetService: @unchecked Sendable {
    public weak var delegate: RealtimeParakeetServiceDelegate?

    public let finalizationMode: RealtimeFinalizationMode
    public let batchFallbackContext: ASRContext

    private let streamManager: StreamingAsrManager
    private let cleanupContext: FluidAudioContext
    private let stateLock = NSLock()

    private var sessionGate = RealtimeSessionGate()
    private var lastPartialText = ""
    private var lastPartialWasConfirmed = false
    private var updateTask: Task<Void, Never>?

    private init(
        streamManager: StreamingAsrManager,
        cleanupContext: FluidAudioContext,
        finalizationMode: RealtimeFinalizationMode
    ) {
        self.streamManager = streamManager
        self.cleanupContext = cleanupContext
        self.finalizationMode = finalizationMode
        self.batchFallbackContext = cleanupContext
    }

    deinit {
        updateTask?.cancel()
        Task { [streamManager] in
            await streamManager.cancel()
        }
    }

    public static func create(
        finalizationMode: RealtimeFinalizationMode = .pureSpeed
    ) async throws -> RealtimeParakeetService {
        let models = try await loadModelsForStartup()
        return try await create(models: models, finalizationMode: finalizationMode)
    }

    public static func create(
        models: AsrModels,
        finalizationMode: RealtimeFinalizationMode
    ) async throws -> RealtimeParakeetService {
        let streamManager = StreamingAsrManager(config: streamingConfig(for: finalizationMode))

        // CTC vocabulary boosting disabled — VocabularyRescorer ignores context thresholds,
        // causing false positives (e.g. replacing "Alex Christou" with "Big John") and
        // adding ~370ms latency. Regex post-processing handles corrections instead.
        // await Self.configureCustomVocabularyBiasing(for: streamManager)

        try await streamManager.start(models: models, source: .microphone)
        let cleanupContext = try await FluidAudioContext.create(models: models, version: .v3)
        let service = RealtimeParakeetService(
            streamManager: streamManager,
            cleanupContext: cleanupContext,
            finalizationMode: finalizationMode
        )
        service.startConsumingUpdates()
        return service
    }

    private static func loadModelsForStartup() async throws -> AsrModels {
        return try await AsrModels.downloadAndLoad(version: .v3)
    }

    public func startUtterance(prerollSamples: [Float]) async throws -> Int {
        let sessionID = try withStateLock {
            let sessionID = try sessionGate.startSession()
            lastPartialText = ""
            lastPartialWasConfirmed = false
            return sessionID
        }

        notifyStart(sessionID: sessionID)

        if !prerollSamples.isEmpty {
            await streamManager.streamSamples(prerollSamples)
        }

        return sessionID
    }

    public func appendAudio(samples: [Float]) async {
        guard let _ = withStateLock({ sessionGate.activeStreamingSessionID }) else { return }
        guard !samples.isEmpty else { return }
        await streamManager.streamSamples(samples)
    }

    public func finishUtterance(
        endpointSegment: [Float],
        speechDuration: TimeInterval
    ) async {
        let sessionID: Int
        do {
            sessionID = try withStateLock { try sessionGate.beginFinishing() }
        } catch {
            publishFailure(error, sessionID: nil)
            return
        }

        do {
            let rawStreamText = try await streamManager.finalizeCurrentUtterance()
            let streamText = applyRegexFillerCleanup(applyDevTermCorrections(
                rawStreamText.trimmingCharacters(in: .whitespacesAndNewlines)
            ))

            var finalText = streamText
            var usedCleanup = false

            if finalizationMode == .speedPlusCleanup, !endpointSegment.isEmpty {
                let cleanupResult = cleanupContext.transcribe(samples: endpointSegment, context: nil)
                let cleanupText = applyRegexFillerCleanup(applyDevTermCorrections(
                    cleanupResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
                if !cleanupText.isEmpty {
                    usedCleanup = cleanupText != streamText
                    finalText = cleanupText
                }
            }

            guard !finalText.isEmpty else {
                throw RealtimeParakeetServiceError.emptyFinalTranscript
            }

            let result = RealtimeUtteranceResult(
                text: finalText,
                sessionID: sessionID,
                speechDuration: speechDuration,
                streamText: streamText,
                usedCleanup: usedCleanup,
                finalizationMode: finalizationMode
            )

            notifyFinish(result)
        } catch {
            publishFailure(error, sessionID: sessionID)
        }

        do {
            try await streamManager.reset()
        } catch {
            publishFailure(error, sessionID: sessionID)
        }

        withStateLock {
            sessionGate.complete(sessionID: sessionID)
            lastPartialText = ""
            lastPartialWasConfirmed = false
        }
    }

    public func cancelUtterance() async {
        let cancelledSessionID = withStateLock { sessionGate.cancelCurrent() }
        do {
            try await streamManager.reset()
        } catch {
            publishFailure(error, sessionID: cancelledSessionID)
        }
        withStateLock {
            lastPartialText = ""
            lastPartialWasConfirmed = false
        }
    }

    public func shutdown() async {
        updateTask?.cancel()
        updateTask = nil
        await streamManager.cancel()
    }

    private func startConsumingUpdates() {
        updateTask = Task { [weak self] in
            guard let self else { return }
            let updates = await self.streamManager.transcriptionUpdates

            for await update in updates {
                guard !Task.isCancelled else { return }

                let payload = self.withStateLock { () -> RealtimePartialUpdate? in
                    guard let sessionID = self.sessionGate.currentSessionID,
                          self.sessionGate.acceptsUpdate(for: sessionID)
                    else {
                        return nil
                    }

                    let cleanedText = applyRegexFillerCleanup(applyDevTermCorrections(
                        update.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                    guard !cleanedText.isEmpty else { return nil }
                    guard cleanedText != self.lastPartialText else {
                        // Keep confirmation state internally, but suppress no-op UI rewrites.
                        self.lastPartialWasConfirmed = self.lastPartialWasConfirmed || update.isConfirmed
                        return nil
                    }

                    self.lastPartialText = cleanedText
                    self.lastPartialWasConfirmed = update.isConfirmed

                    return RealtimePartialUpdate(
                        text: cleanedText,
                        isConfirmed: update.isConfirmed,
                        confidence: update.confidence,
                        timestamp: update.timestamp,
                        sessionID: sessionID
                    )
                }

                guard let payload else { continue }

                self.notifyPartial(payload)
            }
        }
    }

    private func publishFailure(_ error: Error, sessionID: Int?) {
        notifyFailure(error, sessionID: sessionID)
    }

    private func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    /// Configure CTC biasing for user custom terms only (names, company terms).
    /// Small vocab (5-20 terms) = fast, no false positives on common words.
    /// Uses FluidVoice's conservative thresholds for accuracy.
    /// Non-fatal — if no custom terms or loading fails, transcription works without biasing.
    private static func configureCustomVocabularyBiasing(for manager: StreamingAsrManager) async {
        let userTerms = loadUserCustomTermsStructured()
        guard !userTerms.isEmpty else {
            print("[Vocab] No user custom terms — CTC biasing skipped")
            return
        }

        do {
            let ctcModels = try await CtcModels.downloadAndLoad()
            let ctcTokenizer = try await CtcTokenizer.load(
                from: CtcModels.defaultCacheDirectory(for: .ctc110m)
            )

            let tokenizedTerms = userTerms.compactMap { term -> CustomVocabularyTerm? in
                let tokenIds = ctcTokenizer.encode(term.canonical)
                guard !tokenIds.isEmpty else { return nil }
                return CustomVocabularyTerm(
                    text: term.canonical,
                    weight: 10.0,
                    aliases: term.aliases.isEmpty ? nil : term.aliases,
                    ctcTokenIds: tokenIds
                )
            }

            guard !tokenizedTerms.isEmpty else {
                print("[Vocab] No valid custom terms after tokenization")
                return
            }

            // FluidVoice's conservative thresholds — tuned for small vocab, low false positives
            let vocab = CustomVocabularyContext(
                terms: tokenizedTerms,
                alpha: 2.8,
                minCtcScore: -2.2,
                minSimilarity: 0.72,
                minCombinedConfidence: 0.64,
                minTermLength: 3
            )
            try await manager.configureVocabularyBoosting(vocabulary: vocab, ctcModels: ctcModels)
            print("[Vocab] CTC biasing: \(tokenizedTerms.count) user custom terms")
        } catch {
            print("[Vocab] CTC biasing failed (non-fatal): \(error.localizedDescription)")
        }
    }

    private static func streamingConfig(for mode: RealtimeFinalizationMode) -> StreamingAsrConfig {
        let confirmationThreshold: Double
        switch mode {
        case .pureSpeed:
            confirmationThreshold = 0.55
        case .speedPlusCleanup:
            confirmationThreshold = 0.72
        }

        return StreamingAsrConfig(
            chunkSeconds: 0.32,
            hypothesisChunkSeconds: 0.16,
            leftContextSeconds: 0.96,
            rightContextSeconds: 0.16,
            minContextForConfirmation: 0.32,
            confirmationThreshold: confirmationThreshold
        )
    }

    private func notifyStart(sessionID: Int) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.realtimeParakeetService(self, didStartUtterance: sessionID)
        }
    }

    private func notifyPartial(_ payload: RealtimePartialUpdate) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.realtimeParakeetService(self, didUpdatePartial: payload)
        }
    }

    private func notifyFinish(_ result: RealtimeUtteranceResult) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.realtimeParakeetService(self, didFinishUtterance: result)
        }
    }

    private func notifyFailure(_ error: Error, sessionID: Int?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.realtimeParakeetService(self, didFail: error, sessionID: sessionID)
        }
    }
}
