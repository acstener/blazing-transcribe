import Foundation
import FluidAudio

/// Shared model cache paths used by the app-level startup loaders.
public enum FluidAudioModelStore {
    private static let fileManager = FileManager.default

    public static var modelsRootDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    public static var realtimeEou160ModelDirectory: URL {
        modelsRootDirectory.appendingPathComponent("parakeet-eou-streaming/160ms", isDirectory: true)
    }

    public static func hasRealtimeEou160Models() -> Bool {
        ModelNames.ParakeetEOU.requiredModels.allSatisfy { fileName in
            let fileURL = realtimeEou160ModelDirectory.appendingPathComponent(fileName)
            return fileManager.fileExists(atPath: fileURL.path)
        }
    }

    @discardableResult
    public static func ensureRealtimeEou160ModelsAvailable(
        forceRedownload: Bool = false
    ) async throws -> URL {
        let modelDirectory = realtimeEou160ModelDirectory

        try fileManager.createDirectory(at: modelsRootDirectory, withIntermediateDirectories: true)

        if forceRedownload, fileManager.fileExists(atPath: modelDirectory.path) {
            try? fileManager.removeItem(at: modelDirectory)
        }

        if !hasRealtimeEou160Models() {
            try await DownloadUtils.downloadRepo(.parakeetEou160, to: modelsRootDirectory)
        }

        return modelDirectory
    }
}
