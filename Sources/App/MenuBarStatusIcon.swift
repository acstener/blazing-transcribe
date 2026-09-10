import Foundation

/// Menu bar glyph and tint for the current mic / engine state.
/// Orange matches the macOS Control Center microphone privacy indicator.
enum MenuBarStatusIcon: Equatable {
    case downloading
    case loading
    case recording
    case listening
    case muted
    case micActive
    case idleManual
    case idleOff

    var symbolName: String {
        switch self {
        case .downloading:
            return "arrow.down.circle"
        case .loading:
            return "clock"
        case .recording:
            return "record.circle"
        case .listening:
            return "waveform"
        case .muted, .idleOff:
            return "mic.slash"
        case .micActive, .idleManual:
            return "mic.fill"
        }
    }

    var usesOrangeMicTint: Bool {
        switch self {
        case .recording, .listening, .micActive:
            return true
        case .downloading, .loading, .muted, .idleManual, .idleOff:
            return false
        }
    }

    static func resolve(
        isEngineLoading: Bool,
        isDownloading: Bool,
        isRecording: Bool,
        isListening: Bool,
        isMicMuted: Bool,
        isManualMode: Bool,
        isMicCaptureActive: Bool
    ) -> MenuBarStatusIcon {
        if isEngineLoading {
            return isDownloading ? .downloading : .loading
        }
        if isRecording {
            return .recording
        }
        if isListening {
            return .listening
        }
        if isMicMuted {
            return .muted
        }
        if isMicCaptureActive {
            return .micActive
        }
        if isManualMode {
            return .idleManual
        }
        return .idleOff
    }
}
