import Foundation

/// Deepgram Flux real-time streaming ASR engine.
///
/// Connects to Deepgram's v2 WebSocket API (Flux model) per transcription request.
/// Flux uses a learned end-of-turn model (~260ms median) instead of silence-based
/// endpointing, and returns TurnInfo events instead of is_final/speech_final.
///
/// The `transcribe` method uses DispatchSemaphore to bridge the async WebSocket
/// API to synchronous — safe because TranscriptionService always calls from its
/// background queue, never from the main thread.
public final class DeepgramASRContext: ASRContext {
    private let apiKey: String

    public let debugName = "deepgram-flux"

    private static let baseURL = "wss://api.deepgram.com/v2/listen"
    private static let queryParameters = [
        "model=flux-general-en",
        "encoding=linear32",
        "sample_rate=16000",
        "channels=1",
        "eot_threshold=0.7",
        "eot_timeout_ms=3000",
    ].joined(separator: "&")

    private init(apiKey: String) {
        self.apiKey = apiKey
    }

    /// Create a DeepgramASRContext with the given API key.
    public static func create(apiKey: String) -> DeepgramASRContext {
        return DeepgramASRContext(apiKey: apiKey)
    }

    /// Transcribe Float32 PCM audio (16kHz mono) to text via Deepgram Flux.
    ///
    /// Opens a WebSocket, sends the audio buffer in ~80ms chunks to simulate
    /// real-time streaming, then collects TurnInfo events until EndOfTurn.
    public func transcribe(samples: [Float], context: String?) -> TranscriptionResult {
        let semaphore = DispatchSemaphore(value: 0)
        var transcriptionResult = TranscriptionResult(text: "", noSpeechProb: 1.0, avgTokenProb: 0.0)

        guard !samples.isEmpty else {
            return transcriptionResult
        }

        // Convert Float32 samples to raw little-endian bytes
        let audioData = samples.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.size)
        }

        let urlString = "\(Self.baseURL)?\(Self.queryParameters)"
        guard let url = URL(string: urlString) else {
            #if DEBUG
            print("[Deepgram Flux] Invalid URL: \(urlString)")
            #endif
            return transcriptionResult
        }

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url, protocols: ["token", apiKey])
        task.resume()

        let workItem = DispatchWorkItem {
            // Send audio in ~80ms chunks (1280 samples * 4 bytes = 5120 bytes)
            let chunkSamples = 1280
            let bytesPerSample = MemoryLayout<Float>.size
            let chunkBytes = chunkSamples * bytesPerSample
            var offset = 0

            while offset < audioData.count {
                let end = min(offset + chunkBytes, audioData.count)
                let chunk = audioData[offset..<end]
                let sendGroup = DispatchGroup()
                var sendError: Error?

                sendGroup.enter()
                task.send(.data(Data(chunk))) { error in
                    sendError = error
                    sendGroup.leave()
                }
                sendGroup.wait()

                if let error = sendError {
                    #if DEBUG
                    print("[Deepgram Flux] Send error: \(error)")
                    #endif
                    task.cancel(with: .goingAway, reason: nil)
                    semaphore.signal()
                    return
                }

                offset = end
            }

            // Signal end of audio
            let sendGroup = DispatchGroup()
            sendGroup.enter()
            task.send(.string("{\"type\": \"CloseStream\"}")) { _ in
                sendGroup.leave()
            }
            sendGroup.wait()

            // Receive TurnInfo events until EndOfTurn or connection closes
            var latestTranscript = ""
            var latestConfidence: Float = 0.0

            while true {
                let receiveGroup = DispatchGroup()
                var receivedMessage: URLSessionWebSocketTask.Message?
                var receiveError: Error?

                receiveGroup.enter()
                task.receive { result in
                    switch result {
                    case .success(let message):
                        receivedMessage = message
                    case .failure(let error):
                        receiveError = error
                    }
                    receiveGroup.leave()
                }
                receiveGroup.wait()

                if receiveError != nil { break }
                guard let message = receivedMessage else { break }
                guard case .string(let text) = message else { continue }

                guard let data = text.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = json["type"] as? String
                else { continue }

                if type == "TurnInfo" {
                    let event = json["event"] as? String ?? ""
                    let transcript = (json["transcript"] as? String ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    // Track best confidence from words array
                    if let words = json["words"] as? [[String: Any]] {
                        let confs = words.compactMap { $0["confidence"] as? Float }
                        if !confs.isEmpty {
                            latestConfidence = confs.reduce(0, +) / Float(confs.count)
                        }
                    }

                    if !transcript.isEmpty {
                        latestTranscript = transcript
                    }

                    #if DEBUG
                    let eotConf = json["end_of_turn_confidence"] as? Float ?? 0
                    print("[Deepgram Flux] \(event): \"\(transcript)\" eot_conf=\(String(format: "%.2f", eotConf))")
                    #endif

                    if event == "EndOfTurn" { break }
                }
            }

            if latestTranscript.isEmpty {
                transcriptionResult = TranscriptionResult(text: "", noSpeechProb: 1.0, avgTokenProb: 0.0)
            } else {
                transcriptionResult = TranscriptionResult(text: latestTranscript, noSpeechProb: 0.0, avgTokenProb: latestConfidence)
            }

            task.cancel(with: .normalClosure, reason: nil)
            semaphore.signal()
        }

        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)

        let timeout = semaphore.wait(timeout: .now() + 10.0)
        if timeout == .timedOut {
            #if DEBUG
            print("[Deepgram Flux] Transcription timed out")
            #endif
            task.cancel(with: .goingAway, reason: nil)
            return TranscriptionResult(text: "", noSpeechProb: 1.0, avgTokenProb: 0.0)
        }

        return transcriptionResult
    }
}
