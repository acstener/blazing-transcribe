import Foundation

/// Thread-safe circular buffer for Float audio samples.
/// Single producer (audio tap) / single consumer (transcription reader).
public final class RingBuffer {
    private var buffer: [Float]
    private var writeIndex: Int = 0
    private var totalWritten: Int = 0
    private let capacity: Int
    private let lock = NSLock()

    /// Create a ring buffer with the given capacity in samples.
    /// For 30s at 16kHz: capacity = 480_000 (1.83 MB)
    /// For 120s at 16kHz: capacity = 1_920_000 (7.3 MB)
    public init(capacity: Int) {
        self.capacity = capacity
        self.buffer = [Float](repeating: 0, count: capacity)
    }

    /// Write samples into the buffer, overwriting oldest data if full.
    public func write(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }

        for sample in samples {
            buffer[writeIndex] = sample
            writeIndex = (writeIndex + 1) % capacity
        }
        totalWritten += samples.count
    }

    /// Write samples from an UnsafeBufferPointer (zero-copy from audio tap).
    public func write(_ samples: UnsafeBufferPointer<Float>) {
        lock.lock()
        defer { lock.unlock() }

        let count = samples.count
        var remaining = count
        var sourceOffset = 0

        while remaining > 0 {
            let spaceToEnd = capacity - writeIndex
            let chunk = min(remaining, spaceToEnd)

            buffer.withUnsafeMutableBufferPointer { dest in
                let destPtr = dest.baseAddress!.advanced(by: writeIndex)
                let srcPtr = samples.baseAddress!.advanced(by: sourceOffset)
                destPtr.update(from: srcPtr, count: chunk)
            }

            writeIndex = (writeIndex + chunk) % capacity
            sourceOffset += chunk
            remaining -= chunk
        }
        totalWritten += count
    }

    /// Read the last N seconds of audio at the given sample rate.
    public func readLast(seconds: Double, sampleRate: Int = 16000) -> [Float] {
        let sampleCount = min(Int(seconds * Double(sampleRate)), capacity)
        return readLast(sampleCount: sampleCount)
    }

    /// Read the last N samples from the buffer.
    public func readLast(sampleCount: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        let available = min(sampleCount, min(totalWritten, capacity))
        guard available > 0 else { return [] }

        var result = [Float](repeating: 0, count: available)
        var readStart = (writeIndex - available + capacity) % capacity

        var destOffset = 0
        var remaining = available

        while remaining > 0 {
            let spaceToEnd = capacity - readStart
            let chunk = min(remaining, spaceToEnd)

            buffer.withUnsafeBufferPointer { src in
                result.withUnsafeMutableBufferPointer { dest in
                    let srcPtr = src.baseAddress!.advanced(by: readStart)
                    let destPtr = dest.baseAddress!.advanced(by: destOffset)
                    destPtr.update(from: srcPtr, count: chunk)
                }
            }

            readStart = (readStart + chunk) % capacity
            destOffset += chunk
            remaining -= chunk
        }

        return result
    }

    /// Read `count` samples starting at absolute position `from`.
    /// If `from` is older than the buffer's capacity, clamps to oldest available.
    public func read(from absolutePosition: Int, count: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        // Clamp to oldest available data
        let oldestAvailable = totalWritten - capacity
        let clampedPosition = max(absolutePosition, oldestAvailable)

        // Clamp count so we don't read past the write head
        let available = totalWritten - clampedPosition
        let clampedCount = min(count, available)

        guard clampedCount > 0 else { return [] }

        var result = [Float](repeating: 0, count: clampedCount)
        // Calculate physical start index from absolute position
        var readStart = (writeIndex - (totalWritten - clampedPosition) + capacity) % capacity

        var destOffset = 0
        var remaining = clampedCount

        while remaining > 0 {
            let spaceToEnd = capacity - readStart
            let chunk = min(remaining, spaceToEnd)

            buffer.withUnsafeBufferPointer { src in
                result.withUnsafeMutableBufferPointer { dest in
                    let srcPtr = src.baseAddress!.advanced(by: readStart)
                    let destPtr = dest.baseAddress!.advanced(by: destOffset)
                    destPtr.update(from: srcPtr, count: chunk)
                }
            }

            readStart = (readStart + chunk) % capacity
            destOffset += chunk
            remaining -= chunk
        }

        return result
    }

    /// Read all available samples.
    public func readAll() -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        let available = min(totalWritten, capacity)
        guard available > 0 else { return [] }

        return readLast(sampleCount: available)
    }

    /// Clear the buffer.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }

        writeIndex = 0
        totalWritten = 0
    }

    /// Number of samples currently available.
    public var availableSamples: Int {
        lock.lock()
        defer { lock.unlock() }
        return min(totalWritten, capacity)
    }

    /// Total number of samples ever written (monotonically increasing).
    public var totalSamplesWritten: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalWritten
    }
}
