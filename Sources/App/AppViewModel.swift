import SwiftUI
import AVFoundation
import AudioEngine
import Transcription
import HotkeyModule

/// Isolated audio level to avoid re-rendering all views that read AppViewModel at 60Hz.
@Observable
final class AudioLevelMeter {
    var level: Float = 0
}

/// Text cleanup mode — mirrors the menu bar Text Cleanup submenu.
enum TextCleanupMode: String {
    case off
    case regex
    case llm

    var displayTitle: String {
        switch self {
        case .off: return "Off"
        case .regex: return "Filler Removal"
        case .llm: return "LLM Cleanup"
        }
    }

    /// Derive from the current LLMCleanupService state.
    static var current: TextCleanupMode {
        guard LLMCleanupService.isEnabled else { return .off }
        return LLMCleanupService.modelID == "regex" ? .regex : .llm
    }
}

/// Observable state layer bridging AppDelegate services to SwiftUI views.
@Observable
final class AppViewModel {
    // MARK: - Published State

    var appState: AppState.State = .idle
    var recordingMode: RecordingMode = ShortcutConfig.shared.recordingMode
    var transcriptionPreset: TranscriptionPreset = {
        guard let raw = UserDefaults.standard.string(forKey: "transcriptionPreset"),
              let preset = TranscriptionPreset(rawValue: raw) else {
            return .stable
        }
        return preset.canonicalPreset
    }()
    /// Isolated audio level — use `audioLevelMeter.level` instead of reading this from views.
    let audioLevelMeter = AudioLevelMeter()
    var isEngineLoading: Bool = false
    var hasStartedServices: Bool = false
    var isDeveloperTestingVisible: Bool = false
    var textCleanupMode: TextCleanupMode = TextCleanupMode.current
    var selectedLLMProviderModelID: String = LLMCleanupService.selectedCloudCleanupModelID()
    var customPromptInstruction: String = LLMCleanupService.isVoiceStyleEnabled ? LLMCleanupService.customPromptInstruction : ""
    var isCustomPromptEnabled: Bool = LLMCleanupService.isVoiceStyleEnabled
        && !LLMCleanupService.customPromptInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    var groqAPIKey: String = LLMCleanupService.groqAPIKeyStored
    var geminiAPIKey: String = LLMCleanupService.geminiAPIKeyStored
    var useLocalLLM: Bool = LLMCleanupService.useLocalModel
    var isLocalModelDownloaded: Bool = false
    var localModelDownloadProgress: Double?
    var isTurboModeEnabled: Bool = UserDefaults.standard.bool(forKey: "turboMode")
    var isOnboardingPreviewActive: Bool = false
    var isCurrentEngineDownloadPending: Bool = false
    var currentEngineDownloadProgress: Double?
    var currentEngineDownloadCompletedFiles: Int = 0
    var currentEngineDownloadTotalFiles: Int = 0
    var currentEngineDownloadRepoName: String?

    var isLLMCleanupAvailable: Bool {
        transcriptionPreset.supportsLLMCleanup
    }

    // MARK: - Onboarding State

    /// Transcription result routed here during onboarding "Try It" step
    var onboardingTranscriptionResult: String?
    /// Live-polled: whether Accessibility permission is granted
    var isAccessibilityGranted: Bool = false
    /// Live-polled: whether Microphone permission is granted
    var isMicrophoneGranted: Bool = false
    /// Whether the onboarding text field is focused (controls transcription routing)
    var isOnboardingTextFieldFocused: Bool = false

    // MARK: - Service References (read-only for views)

    private(set) var audioCapture: AudioCaptureService?

    // MARK: - Action Closures (set by AppDelegate)

    var onToggleListening: (() -> Void)?
    var onSwitchRecordingMode: ((RecordingMode) -> Void)?
    var onSwitchPreset: ((TranscriptionPreset) -> Void)?
    var onUpdatePTTShortcut: ((GlobalShortcut) -> Void)?
    var onUpdateToggleShortcut: ((GlobalShortcut) -> Void)?
    var onUpdateMicToggleShortcut: ((StoredShortcut) -> Void)?
    var onUpdateModeToggleShortcut: ((GlobalShortcut?) -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onCopyLogs: (() -> Void)?
    var onOpenMainWindow: (() -> Void)?
    var onQuit: (() -> Void)?
    var onSetLowLatencyTuningEnabled: ((Bool) -> Void)?
    var onSwitchTextCleanup: ((TextCleanupMode) -> Void)?
    var onSelectLLMProvider: ((String) -> Void)?
    var onToggleLocalLLM: ((Bool) -> Void)?
    var onSelectLocalModel: ((String) -> Void)?
    var onCustomPromptChanged: ((String) -> Void)?
    var onGroqAPIKeyChanged: ((String) -> Void)?
    var onGeminiAPIKeyChanged: ((String) -> Void)?
    var onOpenOnboardingPreview: (() -> Void)?
    var onCloseOnboardingPreview: (() -> Void)?
    var onStartOnboardingRecording: (() -> Void)?
    var onStopOnboardingRecording: (() -> Void)?
    var onResetVoiceModels: (() -> Void)?
    var onResetAccessibilityPermission: (() -> Void)?
    var onResetMicrophonePermission: (() -> Void)?
    var onTrackOnboardingEvent: ((String, [String: Any]) -> Void)?
    var onReloadEngine: (() -> Void)?

    // MARK: - Init

    func configure(audioCapture: AudioCaptureService) {
        self.audioCapture = audioCapture
    }

    func refreshPermissionState() {
        let accessibilityGranted = KeyboardInjector.hasAccessibilityPermission
        let microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

        if isAccessibilityGranted != accessibilityGranted {
            isAccessibilityGranted = accessibilityGranted
        }
        if isMicrophoneGranted != microphoneGranted {
            isMicrophoneGranted = microphoneGranted
        }
    }
}
