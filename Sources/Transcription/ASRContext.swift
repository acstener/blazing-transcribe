import Foundation

/// Common interface for speech recognition engines.
public protocol ASRContext: AnyObject {
    var debugName: String { get }
    func transcribe(samples: [Float], context: String?) -> TranscriptionResult
    /// Run a no-op inference to keep the underlying model resident in the ANE.
    /// macOS evicts idle CoreML models after a few minutes, forcing the next
    /// real inference to pay a multi-second cold-load cost. Engines without
    /// this problem (cloud, streaming-already-active) can use the default no-op.
    func warmup() async
}

public extension ASRContext {
    var debugName: String {
        String(describing: type(of: self))
    }
    func warmup() async {}
}
