import Foundation

/// Streams audio samples to a temp file during manual recordings.
/// Thread-safe via NSLock (same pattern as RingBuffer).
public final class ToggleRecordingBuffer {
    private let lock = NSLock()
    private var fileHandle: FileHandle?
    private var fileURL: URL?
    private var sampleCount: Int = 0
    private var startTime: Date?

    private let sampleRate: Double = 16000

    private var _isActive: Bool = false

    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isActive
    }

    public var duration: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(sampleCount) / sampleRate
    }

    /// Start recording to a temp file.
    public func begin() {
        lock.lock()
        defer { lock.unlock() }

        // Clean up any previous state
        closeAndCleanup()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("toggle_recording_\(UUID().uuidString).pcm")
        FileManager.default.createFile(atPath: url.path, contents: nil)

        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            #if DEBUG
            print("[DiskBuffer] Failed to create temp file at \(url.path)")
            #endif
            return
        }

        fileHandle = handle
        fileURL = url
        sampleCount = 0
        startTime = Date()
        _isActive = true

        #if DEBUG
        print("[DiskBuffer] Recording started → \(url.lastPathComponent)")
        #endif
    }

    /// Append audio samples from the audio callback.
    public func append(_ samples: UnsafeBufferPointer<Float>) {
        lock.lock()
        defer { lock.unlock() }

        guard let handle = fileHandle,
              samples.count > 0,
              let base = samples.baseAddress else { return }

        let data = Data(bytes: base, count: samples.count * MemoryLayout<Float>.size)
        handle.write(data)
        sampleCount += samples.count
    }

    /// Finish recording. Returns the file URL and sample count, or nil if nothing was recorded.
    public func finish() -> (url: URL, sampleCount: Int)? {
        lock.lock()
        defer { lock.unlock() }

        guard let handle = fileHandle, let url = fileURL else { return nil }

        try? handle.close()
        fileHandle = nil
        _isActive = false

        guard sampleCount > 0 else {
            try? FileManager.default.removeItem(at: url)
            fileURL = nil
            return nil
        }

        let result = (url: url, sampleCount: sampleCount)

        #if DEBUG
        let dur = Double(sampleCount) / sampleRate
        print("[DiskBuffer] Recording finished — \(String(format: "%.1f", dur))s, \(sampleCount) samples")
        #endif

        fileURL = nil
        sampleCount = 0
        startTime = nil
        return result
    }

    /// Cancel and delete the temp file.
    public func cancel() {
        discard(logCancellation: true)
    }

    /// Discard the temp file without logging a user-visible cancellation.
    public func discard() {
        discard(logCancellation: false)
    }

    private func discard(logCancellation: Bool) {
        lock.lock()
        defer { lock.unlock() }
        closeAndCleanup()

        if logCancellation {
            #if DEBUG
            print("[DiskBuffer] Recording cancelled")
            #endif
        }
    }

    /// Read all samples from a disk-backed recording file.
    public static func readSamples(from url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { return nil }

        var samples = [Float](repeating: 0, count: count)
        _ = samples.withUnsafeMutableBytes { dest in
            data.copyBytes(to: dest)
        }
        return samples
    }

    private func closeAndCleanup() {
        if let handle = fileHandle {
            try? handle.close()
            fileHandle = nil
        }
        if let url = fileURL {
            try? FileManager.default.removeItem(at: url)
            fileURL = nil
        }
        sampleCount = 0
        startTime = nil
        _isActive = false
    }

    deinit {
        lock.lock()
        closeAndCleanup()
        lock.unlock()
    }
}
