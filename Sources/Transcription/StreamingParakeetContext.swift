import Foundation
import FluidAudio
import AVFoundation
import CoreML

/// Streaming ASR engine using FluidAudio's Parakeet EOU 120M model.
///
/// The EOU (End-of-Utterance) model is 5x smaller than Parakeet TDT 0.6B and
/// supports true 160ms streaming with built-in end-of-utterance detection.
/// This gives much faster perceived latency for real-time transcription.
///
/// Like `FluidAudioContext`, init is async (model download + compilation on
/// first run), so use the static `create()` factory method.
///
/// The `transcribe` method bridges FluidAudio's async API to synchronous using
/// DispatchSemaphore — safe because TranscriptionService always calls from its
/// background queue, never from the main thread.
public final class StreamingParakeetContext: ASRContext {
    private let manager: StreamingEouAsrManager

    public let debugName = "streaming-parakeet-eou"

    private init(manager: StreamingEouAsrManager) {
        self.manager = manager
    }

    /// Create a StreamingParakeetContext by downloading (if needed) and loading the Parakeet EOU model.
    ///
    /// - Parameter chunkSize: Streaming chunk size (default `.ms160` for lowest latency).
    /// - Returns: A ready-to-use StreamingParakeetContext.
    public static func create(chunkSize: StreamingChunkSize = .ms160) async throws -> StreamingParakeetContext {
        #if DEBUG
        print("[StreamingParakeet] Preparing Parakeet EOU 160ms models...")
        #endif

        // Create manager with fast EOU debounce for snappy response
        let manager = StreamingEouAsrManager(chunkSize: chunkSize, eouDebounceMs: 800)
        var modelDir = try await FluidAudioModelStore.ensureRealtimeEou160ModelsAvailable()

        do {
            try await manager.loadModels(modelDir: modelDir)
        } catch {
            #if DEBUG
            print(
                "[StreamingParakeet] Cached Parakeet EOU load failed: \(error.localizedDescription). Re-downloading..."
            )
            #endif
            modelDir = try await FluidAudioModelStore.ensureRealtimeEou160ModelsAvailable(forceRedownload: true)
            try await manager.loadModels(modelDir: modelDir)
        }

        #if DEBUG
        print("[StreamingParakeet] Parakeet EOU 160ms ready")
        #endif
        return StreamingParakeetContext(manager: manager)
    }

    /// Transcribe Float32 PCM audio (16kHz mono) to text using streaming inference.
    ///
    /// Bridges FluidAudio's async API to synchronous via DispatchSemaphore.
    /// This is safe because TranscriptionService calls from its background queue.
    ///
    /// - Parameters:
    ///   - samples: 16kHz mono Float32 PCM samples.
    ///   - context: Optional recent transcription text (unused by streaming EOU).
    /// - Returns: TranscriptionResult with text. noSpeechProb is 0 and avgTokenProb
    ///   is 1.0 as the streaming EOU model does not expose per-token confidence.
    public func transcribe(samples: [Float], context: String?) -> TranscriptionResult {
        let semaphore = DispatchSemaphore(value: 0)
        var transcriptionResult = TranscriptionResult(text: "", noSpeechProb: 0, avgTokenProb: 1.0)

        Task {
            do {
                // Create AVAudioPCMBuffer from Float32 samples (16kHz mono)
                let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
                buffer.frameLength = AVAudioFrameCount(samples.count)
                memcpy(buffer.floatChannelData![0], samples, samples.count * MemoryLayout<Float>.size)

                // Feed audio through the streaming pipeline
                let _ = try await manager.process(audioBuffer: buffer)

                // Finalize and get the transcript
                let transcript = try await manager.finish()
                let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

                #if DEBUG
                print("[StreamingParakeet] raw text: \"\(text)\"")
                #endif

                transcriptionResult = TranscriptionResult(
                    text: text,
                    noSpeechProb: 0,
                    avgTokenProb: 1.0
                )

                // Reset for next utterance
                await manager.reset()
            } catch {
                #if DEBUG
                print("[StreamingParakeet] Transcription error: \(error)")
                #endif
                // Reset even on error to ensure clean state
                await manager.reset()
            }
            semaphore.signal()
        }

        semaphore.wait()
        return transcriptionResult
    }
}
