import Foundation

/// Menu bar glyph and tint for the current mic / engine state.
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

    /// Red only while actively recording. Do not tint orange: that copies
    /// the macOS mic privacy light, which is already annoying on its own.
    var usesRedRecordingTint: Bool {
        self == .recording
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
