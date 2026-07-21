import Foundation

public protocol TranscriptionDelegate: AnyObject {
    func transcriptionDidStart()
    func transcriptionDidComplete(utterance: Utterance)
    func transcriptionDidFail(error: Error)
}

public enum TranscriptionError: Error, LocalizedError {
    case modelNotLoaded
    case transcriptionFailed
    case alreadyTranscribing
    case noSpeechDetected
    case audioTooShort

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "ASR engine not loaded"
        case .transcriptionFailed:
            return "Transcription failed"
        case .alreadyTranscribing:
            return "Already transcribing"
        case .noSpeechDetected:
            return "No speech detected"
        case .audioTooShort:
            return "Audio too short to transcribe"
        }
    }
}

/// Orchestrates transcription on a background queue.
public final class TranscriptionService {
    public weak var delegate: TranscriptionDelegate?
    public var onTimingEvent: ((TranscriptionTimingEvent) -> Void)?
    /// Fired after each successful keep-warm tick. `duration` is the time
    /// spent inside the engine's warmup call (seconds). Used by diagnostics
    /// to track ANE residency / contention.
    public var onKeepWarmTick: ((TimeInterval) -> Void)?

    private let queue = DispatchQueue(label: "com.blazing.transcription", qos: .userInitiated)
    private let stateLock = NSLock()
    private var activeGeneration: Int?
    private var sessionGeneration = 0
    public var minimumASRSamples: Int = 16_000

    /// ASR engine (FluidAudio).
    private var engine: ASRContext?

    /// Last successful transcription text — fed as context to the next utterance for coherence.
    private var lastTranscriptionContext: String = ""

    public init() {}

    /// Whether the engine is loaded and ready.
    public var isReady: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return engine != nil
    }

    /// Set the ASR engine.
    public func setEngine(_ engine: ASRContext) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeGeneration == nil else { return }
        self.engine = engine
        lastTranscriptionContext = ""
        sessionGeneration += 1
        #if DEBUG
        print("[Transcription] Engine set → \(engine.debugName)")
        #endif
    }

    /// Clear the ASR engine (symmetric with setEngine).
    public func clearEngine() {
        stateLock.lock()
        defer { stateLock.unlock() }
        engine = nil
        sessionGeneration += 1
        activeGeneration = nil
        lastTranscriptionContext = ""
    }

    /// Invalidate in-flight work and prevent stale transcription results from being delivered.
    public func invalidateSession() {
        stateLock.lock()
        defer { stateLock.unlock() }
        sessionGeneration += 1
        activeGeneration = nil
        lastTranscriptionContext = ""
    }

    // MARK: - Encoder-window splitting
    //
    // FluidAudio's Parakeet encoder window is 15s (240k samples @16kHz). Audio
    // longer than one window goes through FluidAudio's internal chunk-merge,
    // whose overlap heuristics drop words at the seams (observed: a 16.5s
    // segment lost everything past ~15s; a 22s toggle recording garbled and
    // truncated around the boundary). Always-on avoids this by never emitting
    // a segment over 14s. This gives manual/toggle recordings the same
    // guarantee: split at the quietest 200ms near each window boundary and
    // transcribe each piece as a normal single-window request.

    static let encoderWindowLimitSamples = 240_000   // 15s — FluidAudio single-shot boundary
    static let splitTargetSamples = 224_000          // 14s — matches always-on's window budget
    static let splitSearchStartSamples = 160_000     // scan for a quiet point from 10s…
    static let splitQuietSliceSamples = 3_200        // …in 200ms slices
    static let minimumChunkSamples = 16_000          // 1s ASR minimum; pad the last chunk to this

    /// Split audio into chunks that each fit a single encoder window, cutting
    /// at the quietest 200ms slice between 10s and 14s of each window so the
    /// cut lands in a pause rather than mid-word. Audio that already fits one
    /// window is returned unchanged.
    static func splitIntoEncoderWindows(_ samples: [Float]) -> [[Float]] {
        guard samples.count > encoderWindowLimitSamples else { return [samples] }

        var chunks: [[Float]] = []
        var start = 0

        while samples.count - start > encoderWindowLimitSamples {
            var bestSplitOffset = splitTargetSamples
            var bestEnergy = Float.greatestFiniteMagnitude
            var offset = splitSearchStartSamples
            while offset + splitQuietSliceSamples <= splitTargetSamples {
                var energy: Float = 0
                for i in (start + offset)..<(start + offset + splitQuietSliceSamples) {
                    energy += samples[i] * samples[i]
                }
                if energy < bestEnergy {
                    bestEnergy = energy
                    bestSplitOffset = offset + splitQuietSliceSamples / 2
                }
                offset += splitQuietSliceSamples
            }
            chunks.append(Array(samples[start..<(start + bestSplitOffset)]))
            start += bestSplitOffset
        }

        var lastChunk = Array(samples[start...])
        if lastChunk.count < minimumChunkSamples {
            // A sub-1s tail would be rejected by the ASR minimum — pad with
            // silence so the final words of a long recording always transcribe.
            lastChunk.append(contentsOf: repeatElement(0, count: minimumChunkSamples - lastChunk.count))
        }
        chunks.append(lastChunk)
        return chunks
    }

    /// Transcribe audio samples on a background thread.
    public func transcribe(samples: [Float]) {
        let currentEngine: ASRContext
        let generation: Int
        let contextText: String

        stateLock.lock()
        guard let engine else {
            stateLock.unlock()
            delegate?.transcriptionDidFail(error: TranscriptionError.modelNotLoaded)
            return
        }

        guard samples.count >= minimumASRSamples else {
            stateLock.unlock()
            onTimingEvent?(TranscriptionTimingEvent(kind: .failed(reason: "audioTooShort"), sampleCount: samples.count))
            delegate?.transcriptionDidFail(error: TranscriptionError.audioTooShort)
            return
        }

        guard activeGeneration == nil else {
            stateLock.unlock()
            delegate?.transcriptionDidFail(error: TranscriptionError.alreadyTranscribing)
            return
        }

        currentEngine = engine
        generation = sessionGeneration
        activeGeneration = generation
        contextText = lastTranscriptionContext
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.delegate?.transcriptionDidStart()
        }

        let startTime = Date()
        onTimingEvent?(TranscriptionTimingEvent(kind: .queued, sampleCount: samples.count))

        queue.async { [weak self] in
            self?.onTimingEvent?(TranscriptionTimingEvent(kind: .started, sampleCount: samples.count))

            let chunks = Self.splitIntoEncoderWindows(samples)
            #if DEBUG
            if chunks.count > 1 {
                let sizes = chunks.map { String(format: "%.1fs", Double($0.count) / 16_000.0) }
                print("[Transcription] \(String(format: "%.1f", Double(samples.count) / 16_000.0))s audio → \(chunks.count) encoder windows (\(sizes.joined(separator: " + ")))")
            }
            #endif

            // Each chunk sees the previous chunk's text as context, same as
            // consecutive utterances do — keeps casing/punctuation coherent
            // across the split.
            var chunkTexts: [String] = []
            var chunkContext = contextText
            var noSpeechProb: Float = 1.0
            var avgTokenProb: Float = 1.0
            for chunk in chunks {
                let chunkResult = currentEngine.transcribe(samples: chunk, context: chunkContext)
                let text = chunkResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    chunkTexts.append(text)
                    chunkContext = text
                    noSpeechProb = min(noSpeechProb, chunkResult.noSpeechProb)
                    avgTokenProb = min(avgTokenProb, chunkResult.avgTokenProb)
                }
            }
            let result = TranscriptionResult(
                text: chunkTexts.joined(separator: " "),
                noSpeechProb: noSpeechProb,
                avgTokenProb: avgTokenProb
            )

            let duration = Date().timeIntervalSince(startTime)
            self?.onTimingEvent?(TranscriptionTimingEvent(kind: .finished, sampleCount: samples.count, duration: duration))

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.stateLock.lock()
                let isStale = self.activeGeneration != generation
                if self.activeGeneration == generation {
                    self.activeGeneration = nil
                }
                self.stateLock.unlock()

                guard !isStale else {
                    #if DEBUG
                    print("[Transcription] Ignoring stale result for generation \(generation)")
                    #endif
                    return
                }

                let text = applyDevTermCorrections(result.text.trimmingCharacters(in: .whitespacesAndNewlines))
                #if DEBUG
                print("[ASR:\(currentEngine.debugName)] text=\"\(text)\" took \(String(format: "%.0f", duration * 1000))ms")
                #endif

                if text.isEmpty {
                    self.delegate?.transcriptionDidFail(error: TranscriptionError.noSpeechDetected)
                } else {
                    self.updateContext(text)
                    let utterance = Utterance(text: text, duration: duration)
                    self.delegate?.transcriptionDidComplete(utterance: utterance)
                }
            }
        }
    }

    /// Pin the current engine's model hot in the ANE by running a silent inference.
    ///
    /// macOS evicts idle CoreML models after a few minutes of inactivity, causing
    /// the next real PTT to pay a multi-second cold-load cost. A periodic call to
    /// this method prevents that. Bails immediately if no engine is loaded or a
    /// real transcription is in flight, and re-checks state on the background
    /// queue so we never collide with a real PTT that arrived while we were queued.
    public func keepWarm() {
        let currentEngine: ASRContext
        let generation: Int

        stateLock.lock()
        guard let engine, activeGeneration == nil else {
            stateLock.unlock()
            return
        }
        currentEngine = engine
        generation = sessionGeneration
        stateLock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let stillValid = self.engine === currentEngine
                && self.activeGeneration == nil
                && self.sessionGeneration == generation
            self.stateLock.unlock()
            guard stillValid else { return }

            let start = CFAbsoluteTimeGetCurrent()
            let group = DispatchGroup()
            group.enter()
            Task {
                await currentEngine.warmup()
                group.leave()
            }
            group.wait()
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            #if DEBUG
            print("[Transcription] keep-warm tick \(currentEngine.debugName) took \(String(format: "%.0f", elapsed * 1000))ms")
            #endif
            self.onKeepWarmTick?(elapsed)
        }
    }

    /// Keep last ~200 chars of transcription as context for the next utterance.
    private func updateContext(_ text: String) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let combined = lastTranscriptionContext.isEmpty ? text : lastTranscriptionContext + " " + text
        if combined.count > 200 {
            lastTranscriptionContext = String(combined.suffix(200))
        } else {
            lastTranscriptionContext = combined
        }
    }
}
