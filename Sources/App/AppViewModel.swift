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
    var isCaptureRunning = false
    var isSpeechEngineReady = false
    var pttShortcutLabel = ShortcutConfig.shared.pttShortcut.displayString
    /// True while the push-to-talk shortcut is physically held and was accepted (manual mode).
    var isShortcutHeld = false
    /// True while a toggle recording is active; the keycap stays pressed for its duration.
    var isToggleRecordingActive = false
    /// Bumped when the shortcut was pressed but recording couldn't start; drives the keycap shake.
    var shortcutRejectionCount = 0

    /// Whether the dictation keycap should render pressed.
    var isShortcutKeycapPressed: Bool {
        recordingMode == .manual && (isShortcutHeld || isToggleRecordingActive)
    }

    func noteShortcutRejected() {
        isShortcutHeld = false
        shortcutRejectionCount &+= 1
    }
    var refreshEngineReadiness: (() -> Bool)?
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
    var currentEngineDownloadCompletedBytes: Int64 = 0
    var currentEngineDownloadTotalBytes: Int64 = 0
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

    // MARK: - Activation (G1: first-run logic; UI lands in G2)

    /// Persisted: the user has dictated into another app at least once.
    /// Existing installs with real usage are treated as already activated.
    var hasCompletedFirstExternalDelivery: Bool = UserDefaults.standard.bool(
        forKey: ActivationTracker.hasCompletedFirstExternalDeliveryKey
    )
    /// What macOS does on fn / Globe press (refreshed on app activation and permission polls).
    var fnKeySystemAction: FnKeySystemAction = FnKeyConflictDetector.currentAction()
    /// True when the push-to-talk shortcut is fn alone and macOS also acts on fn
    /// (Emoji & Symbols, Dictation, Input Source, or the unchanged system default).
    var isFnShortcutConflicting: Bool {
        FnKeyConflictDetector.isConflicting(
            action: fnKeySystemAction,
            pttShortcut: ShortcutConfig.shared.pttShortcut
        )
    }
    /// Set by the practice UI while the practice box is live. Dictations completed
    /// while this is true (or routed into the practice box) don't count toward
    /// UsageStats, History or activation analytics.
    var isPracticeDictationActive: Bool = false
    /// Model download progress, 0...1, or nil when not downloading / unknown
    /// (indeterminate). Same source as `currentEngineDownloadProgress`.
    var modelDownloadFraction: Double? {
        guard isCurrentEngineDownloadPending, let progress = currentEngineDownloadProgress else { return nil }
        return min(max(progress, 0), 1)
    }
    /// Human-readable model download/load error, nil when there is none.
    var modelLoadErrorMessage: String?
    /// True while an automatic retry of a failed model download is pending.
    var isModelDownloadRetryScheduled: Bool = false
    /// True when `appState` is `.error` because the microphone permission was denied
    /// (so the UI can offer "Open System Settings" instead of reloading the model).
    var isMicrophonePermissionError: Bool = false

    /// Ask for microphone access (system prompt if undetermined, otherwise opens
    /// System Settings). Call only from an explicit user click.
    var onRequestMicrophonePermission: (() -> Void)?
    /// Ask for Accessibility access (system prompt / Settings). Call only from an explicit user click.
    var onRequestAccessibilityPermission: (() -> Void)?
    /// Re-check the microphone permission and clear a stale mic error if now granted.
    var onRecheckMicrophonePermission: (() -> Void)?
    /// Retry the speech-model download/load (user-initiated; resets the auto-retry budget).
    var onRetryModelDownload: (() -> Void)?
    /// Internal: AppDelegate reacts to permission changes seen by `refreshPermissionState()`.
    var onPermissionStateRefreshed: (() -> Void)?

    func refreshFnKeySystemAction() {
        let action = FnKeyConflictDetector.currentAction()
        if fnKeySystemAction != action {
            fnKeySystemAction = action
        }
    }

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
    var onCopyDiagnostics: (() -> Void)?
    var requestedWindowSection: SidebarSection?
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
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--experience-preview") || Bundle.main.bundleIdentifier == "com.blazingtranscribe.experience-preview" { return }
        #endif
        isCaptureRunning = audioCapture?.isRunning ?? false
        isSpeechEngineReady = refreshEngineReadiness?() ?? false
        pttShortcutLabel = ShortcutConfig.shared.pttShortcut.displayString
        let accessibilityGranted = KeyboardInjector.hasAccessibilityPermission
        let microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

        if isAccessibilityGranted != accessibilityGranted {
            isAccessibilityGranted = accessibilityGranted
        }
        if isMicrophoneGranted != microphoneGranted {
            isMicrophoneGranted = microphoneGranted
        }
        onPermissionStateRefreshed?()
    }
}
