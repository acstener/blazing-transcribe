import CoreML
import Foundation
import FluidAudio

/// FluidAudio-based ASR engine using NVIDIA Parakeet TDT models on Apple Neural Engine.
///
/// FluidAudio runs inference entirely on the ANE, keeping CPU and GPU free.
/// Parakeet TDT v3 achieves ~210x real-time on M4 Pro with 2.5% WER.
///
/// Init is async (model download + CoreML compilation on first run), so use
/// the static `create()` factory method.
///
/// The `transcribe` method bridges FluidAudio's async API to synchronous using
/// DispatchSemaphore — safe because TranscriptionService always calls from its
/// background queue, never from the main thread.
public final class FluidAudioContext: ASRContext {
    private let asrManager: AsrManager

    public let debugName = "parakeet-tdt-v3"

    private init(asrManager: AsrManager) {
        self.asrManager = asrManager
    }

    /// Create a FluidAudioContext by downloading (if needed) and loading a Parakeet TDT model.
    ///
    /// - Parameter version: Model version (.v3 for multilingual, .v2 for English-only).
    /// - Returns: A ready-to-use FluidAudioContext.
    public static func create(version: AsrModelVersion = .v3) async throws -> FluidAudioContext {
        let config = makeOverrideConfiguration()
        let models = try await AsrModels.downloadAndLoad(configuration: config, version: version)
        return try await create(models: models, version: version)
    }

    /// FluidAudio defensively forces `.cpuOnly` on macOS 26 + M1/M2/M3 because of
    /// an early-Tahoe CoreML bug. Measured cost on M1 Pro: ~20-50× slower than
    /// ANE, plus the model never pins so memory pressure evicts it constantly.
    /// We override back to `.cpuAndNeuralEngine` by default — set the toggle to
    /// false to fall back to FluidAudio's safe default without rebuilding:
    ///
    ///   defaults write com.blazingtranscribe.app BFParakeetForceANE -bool false
    ///
    /// Returns nil when the toggle is off, which preserves FluidAudio's default
    /// behavior for that compute path.
    private static func makeOverrideConfiguration() -> MLModelConfiguration? {
        let key = "BFParakeetForceANE"
        let defaults = UserDefaults.standard
        if defaults.object(forKey: key) == nil {
            defaults.set(true, forKey: key)
        }
        guard defaults.bool(forKey: key) else {
            #if DEBUG
            print("[FluidAudio] ANE override disabled by user preference — using FluidAudio default (likely cpuOnly on this OS+chip)")
            #endif
            return nil
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        config.allowLowPrecisionAccumulationOnGPU = true
        #if DEBUG
        print("[FluidAudio] ANE override active — forcing computeUnits=cpuAndNeuralEngine")
        #endif
        return config
    }

    /// Create a FluidAudioContext from pre-loaded ASR models.
    public static func create(models: AsrModels, version: AsrModelVersion = .v3) async throws -> FluidAudioContext {
        let asrManager = AsrManager(config: .default)
        try await asrManager.initialize(models: models)

        // CTC vocabulary boosting disabled — FluidAudio's VocabularyRescorer ignores
        // the minSimilarity threshold from CustomVocabularyContext (uses internal 0.50
        // default), causing false positives even with conservative settings. The regex
        // post-processing in TextPostProcessing.swift handles corrections reliably.

        #if DEBUG
        print("[FluidAudio] Parakeet TDT \(version) ready")
        #endif
        return FluidAudioContext(asrManager: asrManager)
    }

    /// Run a single dummy inference to prime CoreML's compute pipeline.
    ///
    /// The first CoreML prediction after model load incurs a one-time penalty
    /// (~3-4s on M1 Pro) for ANE kernel compilation and buffer allocation.
    /// Calling this with a short silent buffer absorbs that cost at startup
    /// so the first real PTT transcription runs at full speed (~190ms).
    ///
    /// Safe to call multiple times — subsequent calls are effectively no-ops
    /// (fast warm-path inference on 0.5s of silence).
    public func warmup() async {
        // 1s of silence at 16kHz — must be >= 16,000 samples to pass
        // AsrManager's minimum length guard. All inputs get padded to
        // 240,000 (maxModelSamples) anyway, so this exercises the full
        // encoder/decoder pipeline at the same tensor shapes as real audio.
        let silentSamples = [Float](repeating: 0, count: 16_000)
        let startTime = CFAbsoluteTimeGetCurrent()
        _ = transcribe(samples: silentSamples, context: nil)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        #if DEBUG
        print("[FluidAudio] Warmup inference completed in \(String(format: "%.0f", elapsed * 1000))ms")
        #endif
    }

    /// Transcribe Float32 PCM audio (16kHz mono) to text.
    ///
    /// Bridges FluidAudio's async API to synchronous via DispatchSemaphore.
    /// This is safe because TranscriptionService calls from its background queue.
    ///
    /// - Parameters:
    ///   - samples: 16kHz mono Float32 PCM samples.
    ///   - context: Optional recent transcription text (unused by Parakeet TDT).
    /// - Returns: TranscriptionResult with text. noSpeechProb and avgTokenProb
    ///   are derived from FluidAudio's confidence score.
    public func transcribe(samples: [Float], context: String?) -> TranscriptionResult {
        let semaphore = DispatchSemaphore(value: 0)
        var transcriptionResult = TranscriptionResult(text: "", noSpeechProb: 0, avgTokenProb: 1.0)

        Task {
            do {
                let result = try await asrManager.transcribe(samples, source: .microphone)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                #if DEBUG
                print("[FluidAudio] raw text: \"\(text)\" confidence: \(result.confidence)")
                #endif
                transcriptionResult = TranscriptionResult(
                    text: text,
                    noSpeechProb: 0,
                    avgTokenProb: result.confidence
                )
            } catch {
                #if DEBUG
                print("[FluidAudio] Transcription error: \(error)")
                #endif
            }
            semaphore.signal()
        }

        semaphore.wait()
        return transcriptionResult
    }

}
