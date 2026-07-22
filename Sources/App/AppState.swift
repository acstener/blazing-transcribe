import Foundation
import Transcription

/// Recording mode: always-on (VAD auto-detect) or manual (PTT / toggle).
enum RecordingMode: String, Codable {
    case alwaysOn
    case manual
}

enum TranscriptionPreset: String, CaseIterable, Codable {
    case stable = "stable"
    /// Legacy alias kept only so older settings migrate to the new base Stable mode.
    case stableExtraQuick = "stable-extra-quick"
    case powerUserFastest = "power-user-fastest"
    case realtimeCleanup = "realtime-cleanup"

    static var userFacingCases: [TranscriptionPreset] {
        [.stable, .powerUserFastest]
    }

    var isUserFacing: Bool {
        Self.userFacingCases.contains(self)
    }

    var canonicalPreset: TranscriptionPreset {
        switch self {
        case .stableExtraQuick:
            return .stable
        default:
            return self
        }
    }

    var displayName: String {
        switch self {
        case .stable, .stableExtraQuick:
            return "Stable"
        case .powerUserFastest:
            return "Turbo"
        case .realtimeCleanup:
            return "Hybrid (Experimental)"
        }
    }

    var menuTitle: String {
        switch self {
        case .stable, .stableExtraQuick:
            return "Stable"
        case .powerUserFastest:
            return "Turbo  Fastest realtime"
        case .realtimeCleanup:
            return "Hybrid  Realtime cleanup overlay"
        }
    }

    var subtitle: String {
        switch self {
        case .stable:
            return "Current V1 production path. Stable, accurate, and no overlay-driven realtime behavior."
        case .stableExtraQuick:
            return "Fast, reliable batch mode with tighter always-on endpointing and no overlay-driven realtime behavior."
        case .powerUserFastest:
            return "Pure speed. Fastest realtime path, with speed prioritized over polish."
        case .realtimeCleanup:
            return "Realtime overlay while you speak, then one clean final insert when the utterance ends."
        }
    }

    var supportsLLMCleanup: Bool {
        self != .powerUserFastest
    }

    var engineChoice: TranscriptionEngineChoice {
        switch self {
        case .stable, .stableExtraQuick:
            return .parakeetV3
        case .realtimeCleanup, .powerUserFastest:
            return .parakeetEou
        }
    }

    var realtimeFinalizationMode: RealtimeFinalizationMode? {
        switch self {
        case .stable, .stableExtraQuick:
            return nil
        case .realtimeCleanup:
            return .speedPlusCleanup
        case .powerUserFastest:
            return .pureSpeed
        }
    }

    var realtimeShadowCleanupMode: RealtimeShadowCleanupMode? {
        switch self {
        case .stable, .stableExtraQuick:
            return nil
        case .realtimeCleanup:
            return .overlay
        case .powerUserFastest:
            return .off
        }
    }

    var usesRealtimeEngine: Bool {
        switch self {
        case .stable, .stableExtraQuick:
            return false
        case .powerUserFastest, .realtimeCleanup:
            return true
        }
    }

    static func migrateLegacy(
        experimentalMode: Bool,
        experimentalEngineRaw: String?,
        realtimeFinalizationRaw: String?,
        realtimeCleanupRaw: String?
    ) -> TranscriptionPreset {
        guard experimentalMode else { return .stable }

        let engine = experimentalEngineRaw.flatMap(TranscriptionEngineChoice.init(rawValue:))
        let finalization = realtimeFinalizationRaw.flatMap(RealtimeFinalizationMode.init(rawValue:))
        let cleanup = realtimeCleanupRaw.flatMap(RealtimeShadowCleanupMode.init(rawValue:))

        switch engine {
        case .parakeetEou, .parakeetRealtimeTdt:
            if finalization == .speedPlusCleanup || cleanup == .overlay || cleanup == .field {
                return .realtimeCleanup
            }
            return .powerUserFastest
        default:
            return .stable
        }
    }
}

/// Available transcription engine choices.
enum TranscriptionEngineChoice: String, CaseIterable {
    case parakeetV3 = "parakeet-v3"
    case parakeetRealtimeTdt = "parakeet-realtime-tdt"
    case deepgramFlux = "deepgram-flux"
    case parakeetEou = "parakeet-eou-160ms"
    case deepmind = "deepmind"

    var displayName: String {
        switch self {
        case .parakeetV3: return "Parakeet TDT v3 (default)"
        case .parakeetRealtimeTdt: return "Parakeet Realtime TDT"
        case .deepgramFlux: return "Deepgram Flux"
        case .parakeetEou: return "Parakeet EOU 120M (streaming)"
        case .deepmind: return "DeepMind (coming soon)"
        }
    }

    var subtitle: String {
        switch self {
        case .parakeetV3: return "NVIDIA — 0.6B params, ~90ms ANE-only, on-device"
        case .parakeetRealtimeTdt: return "NVIDIA — realtime TDT partials, always-on, on-device"
        case .deepgramFlux: return "Cloud API — learned end-of-turn, ~260ms latency"
        case .parakeetEou: return "NVIDIA — 120M params, 160ms chunks, on-device"
        case .deepmind: return "Placeholder — not yet available"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .parakeetV3: return true
        case .parakeetRealtimeTdt: return true
        case .deepgramFlux: return true
        case .parakeetEou: return true
        case .deepmind: return false
        }
    }
}

extension Notification.Name {
    static let recordingModeDidChange = Notification.Name("recordingModeDidChange")
    static let transcriptionPresetDidChange = Notification.Name("transcriptionPresetDidChange")
    static let keepMicReadyDidChange = Notification.Name("keepMicReadyDidChange")
    static let micIdleSleepPreferenceDidChange = Notification.Name("micIdleSleepPreferenceDidChange")
    static let dockIconPreferenceDidChange = Notification.Name("dockIconPreferenceDidChange")
    static let experimentalEngineDidChange = Notification.Name("experimentalEngineDidChange")
    static let showHistoryTab = Notification.Name("showHistoryTab")
    static let showStatsTab = Notification.Name("showStatsTab")
    static let showCustomDictionaryTab = Notification.Name("showCustomDictionaryTab")
    static let transcriptionHistoryDidChange = Notification.Name("transcriptionHistoryDidChange")
    static let customVocabularyDidChange = Notification.Name("customVocabularyDidChange")
    static let overlayAppearanceDidChange = Notification.Name("overlayAppearanceDidChange")
    static let overlayEnabledDidChange = Notification.Name("overlayEnabledDidChange")
    static let retryTranscriptionRequested = Notification.Name("retryTranscriptionRequested")
    static let retryCopiedToClipboard = Notification.Name("retryCopiedToClipboard")
}

/// Central application state.
final class AppState {
    enum State: Equatable {
        case idle
        case listening
        case recording      // Active manual recording (PTT held / toggle active)
        case transcribing
        case error(String)
    }

    var currentState: State = .idle {
        didSet {
            onStateChange?(currentState)
        }
    }

    /// Callback when state changes (for UI updates).
    var onStateChange: ((State) -> Void)?

    var isListening: Bool {
        if case .listening = currentState { return true }
        return false
    }

    var isRecording: Bool {
        if case .recording = currentState { return true }
        return false
    }

    var isTranscribing: Bool {
        if case .transcribing = currentState { return true }
        return false
    }
}
