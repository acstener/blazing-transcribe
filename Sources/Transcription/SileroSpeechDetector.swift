import Foundation
import CWhisper
import AudioEngine

/// ML-based speech detector using Silero VAD via whisper.cpp's standalone VAD API.
/// Thread-safe: all Silero calls are serialized on a dedicated queue.
public final class SileroSpeechDetector: SpeechDetector {
    private let vctx: OpaquePointer
    private let queue = DispatchQueue(label: "silero-vad", qos: .userInteractive)

    /// Load Silero VAD model from disk. Returns nil if the model fails to load.
    public init?(modelPath: String) {
        var params = whisper_vad_default_context_params()
        params.n_threads = 2
        params.use_gpu = false

        guard let ctx = whisper_vad_init_from_file_with_params(modelPath, params) else {
            #if DEBUG
            print("[VAD] Failed to load Silero model from \(modelPath)")
            #endif
            return nil
        }
        self.vctx = ctx
        #if DEBUG
        print("[VAD] Silero model loaded from \(modelPath)")
        #endif
    }

    deinit {
        whisper_vad_free(vctx)
        #if DEBUG
        print("[VAD] Silero model freed")
        #endif
    }

    /// Run Silero VAD on the given samples and return both peak and recent speech
    /// probabilities across the emitted 512-sample chunk scores.
    public func analyzeSpeech(samples: [Float]) -> SpeechDetectionResult {
        queue.sync {
            let success = samples.withUnsafeBufferPointer { ptr -> Bool in
                whisper_vad_detect_speech(vctx, ptr.baseAddress!, Int32(samples.count))
            }
            guard success else {
                return SpeechDetectionResult(
                    peakProbability: 0,
                    trailingMaxProbability: 0,
                    trailingAverageProbability: 0,
                    frameCount: 0
                )
            }

            let nProbs = whisper_vad_n_probs(vctx)
            guard nProbs > 0, let probs = whisper_vad_probs(vctx) else {
                return SpeechDetectionResult(
                    peakProbability: 0,
                    trailingMaxProbability: 0,
                    trailingAverageProbability: 0,
                    frameCount: 0
                )
            }

            let frameCount = Int(nProbs)
            var peakProbability: Float = 0
            var trailingMaxProbability: Float = 0
            var trailingSumProbability: Float = 0
            let trailingWindow = min(4, frameCount)

            for i in 0..<frameCount {
                let probability = probs[i]
                peakProbability = max(peakProbability, probability)

                if i >= frameCount - trailingWindow {
                    trailingMaxProbability = max(trailingMaxProbability, probability)
                    trailingSumProbability += probability
                }
            }

            let trailingAverageProbability = trailingWindow > 0
                ? trailingSumProbability / Float(trailingWindow)
                : 0

            return SpeechDetectionResult(
                peakProbability: peakProbability,
                trailingMaxProbability: trailingMaxProbability,
                trailingAverageProbability: trailingAverageProbability,
                frameCount: frameCount
            )
        }
    }
}
