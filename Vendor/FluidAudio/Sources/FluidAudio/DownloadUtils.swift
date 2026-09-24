import CoreML
import Foundation
import OSLog

/// HuggingFace model downloader using URLSession
public class DownloadUtils {

    private static let logger = AppLogger(category: "DownloadUtils")
    private static let downloadProgressNotification = Notification.Name("FluidAudioDownloadProgressDidChange")

    /// Shared URLSession with registry and proxy configuration
    public static let sharedSession: URLSession = ModelRegistry.configuredSession()

    /// Get HuggingFace token from environment if available.
    /// Supports multiple env vars for compatibility with different HuggingFace tools:
    /// - HF_TOKEN: Official HuggingFace CLI
    /// - HUGGING_FACE_HUB_TOKEN: Python huggingface_hub library
    /// - HUGGINGFACEHUB_API_TOKEN: LangChain and older integrations
    private static var huggingFaceToken: String? {
        ProcessInfo.processInfo.environment["HF_TOKEN"]
            ?? ProcessInfo.processInfo.environment["HUGGING_FACE_HUB_TOKEN"]
            ?? ProcessInfo.processInfo.environment["HUGGINGFACEHUB_API_TOKEN"]
    }

    /// Create a URLRequest with optional auth header and timeout
    private static func authorizedRequest(
        url: URL, timeout: TimeInterval = DownloadConfig.default.timeout
    ) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        if let token = huggingFaceToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Fetch data from a URL with HuggingFace authentication if available
    /// Use this for API calls that need auth tokens for private repos or higher rate limits
    public static func fetchWithAuth(from url: URL) async throws -> (Data, URLResponse) {
        let request = authorizedRequest(url: url)
        return try await sharedSession.data(for: request)
    }

    public enum HuggingFaceDownloadError: LocalizedError {
        case invalidResponse
        case rateLimited(statusCode: Int, message: String)
        case downloadFailed(path: String, underlying: Error)
        case modelNotFound(path: String)

        public var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Received an invalid response from Hugging Face."
            case .rateLimited(_, let message):
                return "Hugging Face rate limit encountered: \(message)"
            case .downloadFailed(let path, let underlying):
                return "Failed to download \(path): \(underlying.localizedDescription)"
            case .modelNotFound(let path):
                return "Model file not found: \(path)"
            }
        }
    }

    /// Download configuration
    /// Progress handler type for download progress callbacks (unused but kept for API compatibility)
    public typealias ProgressHandler = (Double) -> Void

    public struct DownloadConfig: Sendable {
        public let timeout: TimeInterval

        public init(timeout: TimeInterval = 1800) {  // 30 minutes for large models
            self.timeout = timeout
        }

        public static let `default` = DownloadConfig()
    }

    private static func postDownloadProgress(
        repo: Repo,
        completed: Int,
        total: Int,
        completedBytes: Int64 = 0,
        totalBytes: Int64 = 0
    ) {
        NotificationCenter.default.post(
            name: downloadProgressNotification,
            object: nil,
            userInfo: [
                "repo": repo.folderName,
                "completed": completed,
                "total": total,
                "completedBytes": completedBytes,
                "totalBytes": totalBytes,
            ]
        )
    }

    /// Delegate-backed download that surfaces byte-level progress while a single
    /// file downloads. Without this, progress only ticks once per completed file —
    /// invisible for the multi-hundred-MB encoder weights that dominate a repo.
    /// The async `download(for:delegate:)` convenience never delivers
    /// `urlSession(_:downloadTask:didWriteData:…)`, so this uses a short-lived
    /// session with a delegate-based task bridged into async/await.
    private final class ProgressReportingDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let onBytesWritten: (Int64) -> Void
        private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
        private let throttleInterval: TimeInterval = 0.25
        private var lastReport = Date.distantPast

        init(onBytesWritten: @escaping (Int64) -> Void) {
            self.onBytesWritten = onBytesWritten
        }

        func download(
            _ request: URLRequest, configuration: URLSessionConfiguration
        ) async throws -> (URL, URLResponse) {
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let task = session.downloadTask(with: request)
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { cont in
                    self.continuation = cont
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            // Serialized on the session's delegate queue.
            let now = Date()
            guard now.timeIntervalSince(lastReport) >= throttleInterval else { return }
            lastReport = now
            onBytesWritten(totalBytesWritten)
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            // `location` is only valid inside this callback — move it out first.
            let stable = FileManager.default.temporaryDirectory
                .appendingPathComponent("fluidaudio-\(UUID().uuidString).download")
            do {
                try FileManager.default.moveItem(at: location, to: stable)
                guard let response = downloadTask.response else {
                    throw HuggingFaceDownloadError.invalidResponse
                }
                continuation?.resume(returning: (stable, response))
            } catch {
                continuation?.resume(throwing: error)
            }
            continuation = nil
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            // Success already resumed in didFinishDownloadingTo; this only fires
            // the continuation for failures (including cancellation).
            if let error {
                continuation?.resume(throwing: error)
                continuation = nil
            }
        }
    }

    public static func loadModels(
        _ repo: Repo,
        modelNames: [String],
        directory: URL,
        computeUnits: MLComputeUnits = .cpuAndNeuralEngine,
        variant: String? = nil
    ) async throws -> [String: MLModel] {
        await SystemInfo.logOnce(using: logger)
        do {
            return try await loadModelsOnce(
                repo, modelNames: modelNames,
                directory: directory, computeUnits: computeUnits, variant: variant)
        } catch let error as HuggingFaceDownloadError {
            // Network-shaped failure: keep the cache. Completed files are skipped
            // on the next attempt, so wiping here would throw away hundreds of MB
            // and force flaky connections to start over from zero every time.
            logger.warning("Download failed, keeping partial cache: \(error.localizedDescription)")
            throw error
        } catch let error as URLError {
            logger.warning("Download failed, keeping partial cache: \(error.localizedDescription)")
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Anything else means the files are on disk but CoreML couldn't load
            // them — treat as corrupt cache: wipe and re-download once.
            logger.warning("First load failed: \(error.localizedDescription)")
            logger.info("Deleting cache and re-downloading…")
            let repoPath = directory.appendingPathComponent(repo.folderName)
            try? FileManager.default.removeItem(at: repoPath)

            return try await loadModelsOnce(
                repo, modelNames: modelNames,
                directory: directory, computeUnits: computeUnits, variant: variant)
        }
    }

    public static func clearModelCache(forRepo repo: Repo, directory: URL) {
        let repoPath = directory.appendingPathComponent(repo.folderName)
        try? FileManager.default.removeItem(at: repoPath)
    }

    private static func loadModelsOnce(
        _ repo: Repo,
        modelNames: [String],
        directory: URL,
        computeUnits: MLComputeUnits = .cpuAndNeuralEngine,
        variant: String? = nil
    ) async throws -> [String: MLModel] {
        await SystemInfo.logOnce(using: logger)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let repoPath = directory.appendingPathComponent(repo.folderName)
        let requiredModels = ModelNames.getRequiredModelNames(for: repo, variant: variant)
        let allModelsExist = requiredModels.allSatisfy { model in
            let modelPath = repoPath.appendingPathComponent(model)
            return FileManager.default.fileExists(atPath: modelPath.path)
        }

        if !allModelsExist {
            logger.info("Models not found in cache at \(repoPath.path)")
            try await downloadRepo(repo, to: directory, variant: variant)
        } else {
            logger.info("Found \(repo.folderName) locally, no download needed")
        }

        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        config.allowLowPrecisionAccumulationOnGPU = true

        var models: [String: MLModel] = [:]
        for name in modelNames {
            let modelPath = repoPath.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: modelPath.path) else {
                throw CocoaError(
                    .fileNoSuchFile,
                    userInfo: [
                        NSFilePathErrorKey: modelPath.path,
                        NSLocalizedDescriptionKey: "Model file not found: \(name)",
                    ])
            }

            var isDirectory: ObjCBool = false
            guard
                FileManager.default.fileExists(atPath: modelPath.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                throw CocoaError(
                    .fileReadCorruptFile,
                    userInfo: [
                        NSFilePathErrorKey: modelPath.path,
                        NSLocalizedDescriptionKey: "Model path is not a directory: \(name)",
                    ])
            }

            let coremlDataPath = modelPath.appendingPathComponent("coremldata.bin")
            guard FileManager.default.fileExists(atPath: coremlDataPath.path) else {
                logger.error("Missing coremldata.bin in \(name)")
                throw CocoaError(
                    .fileReadCorruptFile,
                    userInfo: [
                        NSFilePathErrorKey: coremlDataPath.path,
                        NSLocalizedDescriptionKey: "Missing coremldata.bin in model: \(name)",
                    ])
            }

            let start = Date()
            let model = try MLModel(contentsOf: modelPath, configuration: config)
            let elapsed = Date().timeIntervalSince(start)

            models[name] = model

            let ms = elapsed * 1000
            let formatted = String(format: "%.2f", ms)
            logger.info("Compiled model \(name) in \(formatted) ms :: \(SystemInfo.summary())")
        }

        return models
    }

    /// Download a HuggingFace repository using URLSession (does not load models)
    public static func downloadRepo(_ repo: Repo, to directory: URL, variant: String? = nil) async throws {
        logger.info("Downloading \(repo.folderName) from HuggingFace...")

        let repoPath = directory.appendingPathComponent(repo.folderName)
        try FileManager.default.createDirectory(at: repoPath, withIntermediateDirectories: true)

        let requiredModels = ModelNames.getRequiredModelNames(for: repo, variant: variant)
        let subPath = repo.subPath  // e.g., "160ms" for parakeetEou160

        // Build patterns for filtering (relative to subPath if present)
        var patterns: [String] = []
        for model in requiredModels {
            if let sub = subPath {
                patterns.append("\(sub)/\(model)/")
            } else {
                patterns.append("\(model)/")
            }
        }

        // Get all files recursively using HuggingFace API
        var filesToDownload: [(path: String, size: Int)] = []

        // A required entry is usually a directory bundle ("Encoder.mlmodelc/") but can
        // be a plain file ("vocab.json") — the trailing-slash pattern never
        // prefix-matches a file path, so also compare with the slash stripped.
        func matchesRequiredEntry(_ itemPath: String) -> Bool {
            patterns.contains { itemPath.hasPrefix($0) || String($0.dropLast()) == itemPath }
        }
        func isOnPathToRequiredEntry(_ itemPath: String) -> Bool {
            patterns.contains { itemPath.hasPrefix($0) || $0.hasPrefix(itemPath + "/") }
        }

        func listDirectory(path: String) async throws {
            let apiPath = path.isEmpty ? "tree/main" : "tree/main/\(path)"
            let dirURL = try ModelRegistry.apiModels(repo.remotePath, apiPath)
            let request = authorizedRequest(url: dirURL)

            let (dirData, response) = try await sharedSession.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 429 || httpResponse.statusCode == 503 {
                    throw HuggingFaceDownloadError.rateLimited(
                        statusCode: httpResponse.statusCode, message: "Rate limited while listing files")
                }
            }

            guard let items = try JSONSerialization.jsonObject(with: dirData) as? [[String: Any]] else {
                return
            }

            for item in items {
                guard let itemPath = item["path"] as? String,
                    let itemType = item["type"] as? String
                else { continue }

                if itemType == "directory" {
                    // Only descend toward required entries — this skips sibling
                    // bundles the app never loads (.mlpackage exports, unused
                    // preprocessor variants).
                    if patterns.isEmpty || isOnPathToRequiredEntry(itemPath) {
                        try await listDirectory(path: itemPath)
                    }
                } else if itemType == "file" {
                    let shouldInclude: Bool
                    if let sub = subPath {
                        // Only files that belong to a required entry. The old
                        // .json/.model catch-all also pulled .mlpackage manifests
                        // and metadata for bundles the app never loads.
                        shouldInclude =
                            itemPath.hasPrefix("\(sub)/")
                            && (patterns.isEmpty || matchesRequiredEntry(itemPath))
                    } else {
                        // Top-level .json/.txt catch-all keeps vocab/config/tokenizer
                        // files that live beside the model bundles.
                        let isTopLevelMetadata =
                            !itemPath.contains("/")
                            && (itemPath.hasSuffix(".json") || itemPath.hasSuffix(".txt"))
                        shouldInclude =
                            patterns.isEmpty || matchesRequiredEntry(itemPath) || isTopLevelMetadata
                    }
                    if shouldInclude {
                        let fileSize = item["size"] as? Int ?? -1
                        filesToDownload.append((path: itemPath, size: fileSize))
                    }
                }
            }
        }

        // Start listing from subPath if specified, otherwise from root
        try await listDirectory(path: subPath ?? "")
        logger.info("Found \(filesToDownload.count) files to download")

        func destinationPath(for filePath: String) -> URL {
            var localPath = filePath
            if let sub = subPath, filePath.hasPrefix("\(sub)/") {
                localPath = String(filePath.dropFirst(sub.count + 1))
            }
            return repoPath.appendingPathComponent(localPath)
        }

        let totalFileCount = filesToDownload.count
        let totalBytes = filesToDownload.reduce(Int64(0)) { $0 + Int64(max($1.size, 0)) }
        var completedFiles = 0
        var completedBytes: Int64 = 0
        for file in filesToDownload {
            if FileManager.default.fileExists(atPath: destinationPath(for: file.path).path) {
                completedFiles += 1
                completedBytes += Int64(max(file.size, 0))
            }
        }
        postDownloadProgress(
            repo: repo, completed: completedFiles, total: totalFileCount,
            completedBytes: completedBytes, totalBytes: totalBytes)

        // Download each file
        for (index, file) in filesToDownload.enumerated() {
            let destPath = destinationPath(for: file.path)

            // Skip if already exists
            if FileManager.default.fileExists(atPath: destPath.path) {
                continue
            }

            // Create parent directory
            try FileManager.default.createDirectory(
                at: destPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            // HuggingFace returns 500 for 0-byte files — create empty file locally
            if file.size == 0 {
                FileManager.default.createFile(atPath: destPath.path, contents: Data())
                completedFiles += 1
                postDownloadProgress(
                    repo: repo, completed: completedFiles, total: totalFileCount,
                    completedBytes: completedBytes, totalBytes: totalBytes)
                continue
            }

            // Download file (use original path for HuggingFace URL)
            let encodedFilePath =
                file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.path
            let fileURL = try ModelRegistry.resolveModel(repo.remotePath, encodedFilePath)
            let request = authorizedRequest(url: fileURL)

            // Snapshot progress so the delegate (called on the session queue)
            // never races the loop's mutable counters.
            let filesDoneSoFar = completedFiles
            let bytesDoneSoFar = completedBytes
            let downloader = ProgressReportingDownloader { totalBytesWritten in
                postDownloadProgress(
                    repo: repo, completed: filesDoneSoFar, total: totalFileCount,
                    completedBytes: bytesDoneSoFar + totalBytesWritten, totalBytes: totalBytes)
            }

            let (tempFileURL, response) = try await downloader.download(
                request, configuration: sharedSession.configuration)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw HuggingFaceDownloadError.invalidResponse
            }

            if httpResponse.statusCode == 429 || httpResponse.statusCode == 503 {
                throw HuggingFaceDownloadError.rateLimited(
                    statusCode: httpResponse.statusCode,
                    message: "Rate limited while downloading \(file.path)")
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                throw HuggingFaceDownloadError.downloadFailed(
                    path: file.path,
                    underlying: NSError(domain: "HTTP", code: httpResponse.statusCode)
                )
            }

            // Remove existing file if present (handles parallel download race conditions)
            if FileManager.default.fileExists(atPath: destPath.path) {
                try? FileManager.default.removeItem(at: destPath)
            }
            try FileManager.default.moveItem(at: tempFileURL, to: destPath)
            completedFiles += 1
            completedBytes += Int64(max(file.size, 0))
            postDownloadProgress(
                repo: repo, completed: completedFiles, total: totalFileCount,
                completedBytes: completedBytes, totalBytes: totalBytes)

            if (index + 1) % 10 == 0 || index == filesToDownload.count - 1 {
                logger.info("Downloaded \(index + 1)/\(filesToDownload.count) files")
            }
        }

        // Verify required models are present
        for model in requiredModels {
            let modelPath = repoPath.appendingPathComponent(model)
            guard FileManager.default.fileExists(atPath: modelPath.path) else {
                throw HuggingFaceDownloadError.modelNotFound(path: model)
            }
        }

        logger.info("Downloaded all required models for \(repo.folderName)")
    }

    /// Fetch a single file from HuggingFace with retry
    public static func fetchHuggingFaceFile(
        from url: URL,
        description: String,
        maxAttempts: Int = 4,
        minBackoff: TimeInterval = 1.0
    ) async throws -> Data {
        var lastError: Error?
        let request = authorizedRequest(url: url)

        for attempt in 1...maxAttempts {
            do {
                let (data, response) = try await sharedSession.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw HuggingFaceDownloadError.invalidResponse
                }

                if httpResponse.statusCode == 429 || httpResponse.statusCode == 503 {
                    throw HuggingFaceDownloadError.rateLimited(
                        statusCode: httpResponse.statusCode,
                        message: "HTTP \(httpResponse.statusCode)"
                    )
                }

                guard (200..<300).contains(httpResponse.statusCode) else {
                    throw HuggingFaceDownloadError.invalidResponse
                }

                return data

            } catch {
                lastError = error
                if attempt < maxAttempts {
                    let backoffSeconds = pow(2.0, Double(attempt - 1)) * minBackoff
                    logger.warning(
                        "Download attempt \(attempt) for \(description) failed: \(error.localizedDescription). Retrying in \(String(format: "%.1f", backoffSeconds))s."
                    )
                    try await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
                }
            }
        }

        throw lastError ?? HuggingFaceDownloadError.invalidResponse
    }
}
