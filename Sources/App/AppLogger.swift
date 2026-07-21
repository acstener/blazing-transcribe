import Foundation
import os.log

/// Persistent file + os_log logger for release builds.
/// Logs to ~/Library/Logs/BlazingTranscribe/app.log
final class AppLogger {
    static let shared = AppLogger()

    private let osLog = OSLog(subsystem: "com.blazingtranscribe.app", category: "app")
    private let fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.blazingtranscribe.logger")

    /// Path to the current log file.
    let logFilePath: String

    private init() {
        let logsDir = NSHomeDirectory() + "/Library/Logs/BlazingTranscribe"
        logFilePath = logsDir + "/app.log"

        // Create logs directory
        try? FileManager.default.createDirectory(atPath: logsDir, withIntermediateDirectories: true)

        // Rotate if log > 2 MB
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logFilePath),
           let size = attrs[.size] as? Int, size > 2_000_000 {
            let old = logsDir + "/app.old.log"
            try? FileManager.default.removeItem(atPath: old)
            try? FileManager.default.moveItem(atPath: logFilePath, toPath: old)
        }

        // Open or create log file
        if !FileManager.default.fileExists(atPath: logFilePath) {
            FileManager.default.createFile(atPath: logFilePath, contents: nil)
        }
        fileHandle = FileHandle(forWritingAtPath: logFilePath)
        fileHandle?.seekToEndOfFile()

        info("=== Blazing Transcribe launched ===")
    }

    func info(_ message: String) {
        log(level: .info, prefix: "INFO", message: message)
    }

    func warn(_ message: String) {
        log(level: .default, prefix: "WARN", message: message)
    }

    func error(_ message: String) {
        log(level: .error, prefix: "ERROR", message: message)
    }

    private func log(level: OSLogType, prefix: String, message: String) {
        os_log("%{public}@", log: osLog, type: level, message)

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [\(prefix)] \(message)\n"

        queue.async { [weak self] in
            if let data = line.data(using: .utf8) {
                self?.fileHandle?.write(data)
            }
        }
    }
}

/// Shorthand for logging throughout the app.
func appLog(_ message: String) { AppLogger.shared.info(message) }
func appWarn(_ message: String) { AppLogger.shared.warn(message) }
func appError(_ message: String) { AppLogger.shared.error(message) }
