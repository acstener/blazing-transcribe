import Foundation

public struct AudioSegment {
    public let samples: [Float]
    public let sampleRate: Int
    public let timestamp: Date

    public init(samples: [Float], sampleRate: Int = 16000, timestamp: Date = Date()) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.timestamp = timestamp
    }

    public var duration: TimeInterval {
        Double(samples.count) / Double(sampleRate)
    }
}

public enum EndpointingProfile: String {
    case standard
    case stableExtraQuick
    case aggressiveParakeet
    case realtimeParakeet
}

public struct SpeechDetectionResult {
    public let peakProbability: Float
    public let trailingMaxProbability: Float
    public let trailingAverageProbability: Float
    public let frameCount: Int

    public init(
        peakProbability: Float,
        trailingMaxProbability: Float,
        trailingAverageProbability: Float,
        frameCount: Int
    ) {
        self.peakProbability = peakProbability
        self.trailingMaxProbability = trailingMaxProbability
        self.trailingAverageProbability = trailingAverageProbability
        self.frameCount = frameCount
    }
}

public struct SpeechStartTiming {
    public let detectedAt: Date
    public let detector: String
    public let profile: EndpointingProfile
    public let peakProbability: Float?
    public let trailingAverageProbability: Float?

    public init(
        detectedAt: Date,
        detector: String,
        profile: EndpointingProfile,
        peakProbability: Float?,
        trailingAverageProbability: Float?
    ) {
        self.detectedAt = detectedAt
        self.detector = detector
        self.profile = profile
        self.peakProbability = peakProbability
        self.trailingAverageProbability = trailingAverageProbability
    }
}

public struct SpeechSegmentTiming {
    public let speechDetectedAt: Date?
    public let lastVoiceActivityAt: Date
    public let endpointDetectedAt: Date
    public let endpointLatency: TimeInterval
    public let silenceTimeoutUsed: TimeInterval
    public let speechDuration: TimeInterval
    public let detector: String
    public let profile: EndpointingProfile
    public let peakProbability: Float?
    public let trailingMaxProbability: Float?
    public let trailingAverageProbability: Float?

    public init(
        speechDetectedAt: Date?,
        lastVoiceActivityAt: Date,
        endpointDetectedAt: Date,
        endpointLatency: TimeInterval,
        silenceTimeoutUsed: TimeInterval,
        speechDuration: TimeInterval,
        detector: String,
        profile: EndpointingProfile,
        peakProbability: Float?,
        trailingMaxProbability: Float?,
        trailingAverageProbability: Float?
    ) {
        self.speechDetectedAt = speechDetectedAt
        self.lastVoiceActivityAt = lastVoiceActivityAt
        self.endpointDetectedAt = endpointDetectedAt
        self.endpointLatency = endpointLatency
        self.silenceTimeoutUsed = silenceTimeoutUsed
        self.speechDuration = speechDuration
        self.detector = detector
        self.profile = profile
        self.peakProbability = peakProbability
        self.trailingMaxProbability = trailingMaxProbability
        self.trailingAverageProbability = trailingAverageProbability
    }
}
