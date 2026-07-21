import Foundation

public enum RealtimeFinalizationMode: String, CaseIterable, Sendable {
    case pureSpeed = "pure-speed"
    case speedPlusCleanup = "speed-plus-cleanup"

    public var displayName: String {
        switch self {
        case .pureSpeed:
            return "Pure speed"
        case .speedPlusCleanup:
            return "Speed + cleanup"
        }
    }
}

public enum RealtimeShadowCleanupMode: String, CaseIterable, Sendable {
    case off = "off"
    case overlay = "overlay"
    case field = "field"

    public var displayName: String {
        switch self {
        case .off:
            return "Final-only commit"
        case .overlay:
            return "Overlay first, then final commit"
        case .field:
            return "Clean up directly in input field"
        }
    }
}

public enum TerminalInlineCleanupMode: String, CaseIterable, Sendable {
    case off = "off"
    case backspaceRewrite = "backspace-rewrite"
    case clipboardPaste = "clipboard-paste"
    case deferredCleanup = "deferred-cleanup"
    case inlineCleanup = "inline-cleanup"
}

public enum RealtimeLLMCleanupMode: String, CaseIterable, Sendable {
    case off = "off"
    case regexOnly = "regex-turbo"
    case deferredLLM = "deferred-llm"
    case shadowLLM = "shadow-llm"
    case sentenceLLM = "sentence-llm"

    public var displayName: String {
        switch self {
        case .off: return "Off (batch only)"
        case .regexOnly: return "Regex Turbo (fillers only)"
        case .deferredLLM: return "LLM Deferred (rewrite at end)"
        case .shadowLLM: return "LLM Shadow (progressive)"
        case .sentenceLLM: return "LLM Sentence (per sentence)"
        }
    }
}

public enum RealtimePartialSource: String, Sendable {
    case eouLive = "eou-live"
    case shadowCleanup = "shadow-cleanup"
}

public struct RealtimePartialUpdate: Sendable {
    public let text: String
    public let isConfirmed: Bool
    public let confidence: Float
    public let timestamp: Date
    public let sessionID: Int
    public let source: RealtimePartialSource

    public init(
        text: String,
        isConfirmed: Bool,
        confidence: Float,
        timestamp: Date = Date(),
        sessionID: Int,
        source: RealtimePartialSource = .eouLive
    ) {
        self.text = text
        self.isConfirmed = isConfirmed
        self.confidence = confidence
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.source = source
    }
}

public struct RealtimeUtteranceResult: Sendable {
    public let text: String
    public let sessionID: Int
    public let timestamp: Date
    public let speechDuration: TimeInterval
    public let streamText: String
    public let usedCleanup: Bool
    public let finalizationMode: RealtimeFinalizationMode

    public init(
        text: String,
        sessionID: Int,
        timestamp: Date = Date(),
        speechDuration: TimeInterval,
        streamText: String,
        usedCleanup: Bool,
        finalizationMode: RealtimeFinalizationMode
    ) {
        self.text = text
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.speechDuration = speechDuration
        self.streamText = streamText
        self.usedCleanup = usedCleanup
        self.finalizationMode = finalizationMode
    }
}

public protocol RealtimeParakeetServiceDelegate: AnyObject {
    func realtimeParakeetService(_ service: RealtimeParakeetService, didStartUtterance sessionID: Int)
    func realtimeParakeetService(_ service: RealtimeParakeetService, didUpdatePartial update: RealtimePartialUpdate)
    func realtimeParakeetService(_ service: RealtimeParakeetService, didFinishUtterance result: RealtimeUtteranceResult)
    func realtimeParakeetService(_ service: RealtimeParakeetService, didFail error: Error, sessionID: Int?)
}

public enum RealtimeParakeetServiceError: Error, LocalizedError {
    case utteranceAlreadyActive
    case noActiveUtterance
    case emptyFinalTranscript

    public var errorDescription: String? {
        switch self {
        case .utteranceAlreadyActive:
            return "A realtime utterance is already active"
        case .noActiveUtterance:
            return "No realtime utterance is active"
        case .emptyFinalTranscript:
            return "Realtime utterance produced no transcript"
        }
    }
}

enum RealtimeSessionPhase: Equatable {
    case idle
    case active(Int)
    case finishing(Int)
}

struct RealtimeSessionGate {
    private(set) var phase: RealtimeSessionPhase = .idle
    private(set) var nextSessionID: Int = 0

    mutating func startSession() throws -> Int {
        guard case .idle = phase else {
            throw RealtimeParakeetServiceError.utteranceAlreadyActive
        }
        nextSessionID += 1
        phase = .active(nextSessionID)
        return nextSessionID
    }

    mutating func beginFinishing() throws -> Int {
        guard case .active(let sessionID) = phase else {
            throw RealtimeParakeetServiceError.noActiveUtterance
        }
        phase = .finishing(sessionID)
        return sessionID
    }

    mutating func cancelCurrent() -> Int? {
        let current = currentSessionID
        phase = .idle
        return current
    }

    mutating func complete(sessionID: Int) {
        guard currentSessionID == sessionID else { return }
        phase = .idle
    }

    var currentSessionID: Int? {
        switch phase {
        case .idle:
            return nil
        case .active(let sessionID), .finishing(let sessionID):
            return sessionID
        }
    }

    var activeStreamingSessionID: Int? {
        if case .active(let sessionID) = phase {
            return sessionID
        }
        return nil
    }

    func acceptsUpdate(for sessionID: Int) -> Bool {
        currentSessionID == sessionID
    }
}
