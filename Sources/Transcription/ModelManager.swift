import Foundation

public enum ModelManagerError: Error, LocalizedError {
    case downloadFailed(Error)
    case invalidResponse
    case fileSystemError(Error)

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let error):
            return "Model download failed: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from model server"
        case .fileSystemError(let error):
            return "File system error: \(error.localizedDescription)"
        }
    }
}

/// Manages VAD model download and discovery.
public final class ModelManager {

    // Silero VAD model — ML-based speech detection (~864 KB)
    public static let vadModelFilename = "ggml-silero-v6.2.0.bin"
    private static let vadModelURL =
        "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin"

    /// Application Support directory for storing models.
    public static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("BlazingFastTranscription")
            .appendingPathComponent("Models")
    }

    /// Path to the VAD model.
    public static var vadModelPath: String {
        modelsDirectory.appendingPathComponent(vadModelFilename).path
    }

    /// Check if the VAD model exists on disk.
    public static var isVADModelDownloaded: Bool {
        FileManager.default.fileExists(atPath: vadModelPath)
    }

    /// Download the Silero VAD model from HuggingFace (~864 KB, typically < 1s).
    public static func downloadVADModel(
        completion: @escaping (Result<String, ModelManagerError>) -> Void
    ) {
        guard let url = URL(string: vadModelURL) else {
            completion(.failure(.invalidResponse))
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: modelsDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            completion(.failure(.fileSystemError(error)))
            return
        }

        let destination = modelsDirectory.appendingPathComponent(vadModelFilename)

        if FileManager.default.fileExists(atPath: destination.path) {
            completion(.success(destination.path))
            return
        }

        let session = URLSession(configuration: .default, delegate: nil, delegateQueue: nil)
        let task = session.downloadTask(with: url) { tempURL, response, error in
            if let error = error {
                DispatchQueue.main.async {
                    completion(.failure(.downloadFailed(error)))
                }
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let tempURL = tempURL else {
                DispatchQueue.main.async {
                    completion(.failure(.invalidResponse))
                }
                return
            }

            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: tempURL, to: destination)
                DispatchQueue.main.async {
                    completion(.success(destination.path))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(.fileSystemError(error)))
                }
            }
        }

        task.resume()
    }
}
