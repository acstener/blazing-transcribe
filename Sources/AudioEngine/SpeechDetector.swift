import Foundation

public protocol SpeechDetector: AnyObject {
    /// Analyze audio samples and return both peak and recent trailing speech probabilities.
    /// Expects 16kHz mono Float32 PCM. Samples should be at least ~500ms for reliable detection.
    func analyzeSpeech(samples: [Float]) -> SpeechDetectionResult

    /// Analyze audio samples and return speech probability (0.0 - 1.0).
    /// Expects 16kHz mono Float32 PCM. Samples should be at least ~500ms for reliable detection.
    func detectSpeech(samples: [Float]) -> Float
}

public extension SpeechDetector {
    func detectSpeech(samples: [Float]) -> Float {
        analyzeSpeech(samples: samples).peakProbability
    }
}
