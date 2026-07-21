import Foundation

public struct TranscriptionResult {
    public let text: String
    public let noSpeechProb: Float  // 0.0 = definitely speech, 1.0 = definitely not speech
    public let avgTokenProb: Float  // average per-token probability (0.0 = garbage, 1.0 = perfect)
}

public enum TranscriptionTimingEventKind {
    case queued
    case started
    case finished
    case failed(reason: String)
}

public struct TranscriptionTimingEvent {
    public let kind: TranscriptionTimingEventKind
    public let timestamp: Date
    public let sampleCount: Int
    public let duration: TimeInterval?

    public init(
        kind: TranscriptionTimingEventKind,
        timestamp: Date = Date(),
        sampleCount: Int,
        duration: TimeInterval? = nil
    ) {
        self.kind = kind
        self.timestamp = timestamp
        self.sampleCount = sampleCount
        self.duration = duration
    }
}

public struct Utterance {
    public let text: String
    public let timestamp: Date
    public let duration: TimeInterval

    public init(text: String, timestamp: Date = Date(), duration: TimeInterval = 0) {
        self.text = text
        self.timestamp = timestamp
        self.duration = duration
    }
}
