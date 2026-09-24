import AppKit
import AVFoundation
import SwiftUI
import ServiceManagement
import AudioEngine
import Transcription
import FluidAudio
import Overlay
import Clipboard
import HotkeyModule
import CWhisper

import Sparkle
import PostHog

/// Send an analytics event to PostHog. No-op when analytics is disabled
/// (empty `AnalyticsSecrets.postHogAPIKey`, i.e. source/fork builds).
func trackEvent(_ name: String, parameters: [String: Any] = [:]) {
    guard !AnalyticsSecrets.postHogAPIKey.isEmpty else { return }
    var enriched = parameters
    #if DEBUG
    enriched["environment"] = "debug"
    #else
    enriched["environment"] = "release"
    #endif
    PostHogSDK.shared.capture(name, properties: enriched)
}

/// Suppress whisper.cpp/ggml verbose logging (DEBUG/INFO). Only WARN/ERROR pass through.
private func whisperLogCallback(level: ggml_log_level, text: UnsafePointer<CChar>?, userData: UnsafeMutableRawPointer?) {
    guard level.rawValue >= GGML_LOG_LEVEL_WARN.rawValue else { return }
    if let text = text {
        fputs(text, stderr)
    }
}

private enum RetainedAudioReference {
    case temporaryFile(URL)
    case cachedFile(String)
}

private struct PendingTranscriptionRequest {
    let id: UInt64
    let samples: [Float]
    let duration: Double
    let source: String
    let speechTiming: SpeechSegmentTiming?
    let enqueuedAt: Date
    let retainedAudio: RetainedAudioReference?
    let historyRetryID: UUID?
}

#if DEBUG
private enum ForcedManualTranscriptionError: Error, LocalizedError {
    case requested

    var errorDescription: String? {
        "Debug: forced manual transcription failure"
    }
}
#endif

private struct AlwaysOnBatchCarryover {
    let request: PendingTranscriptionRequest
    let expiresAt: Date
}

private struct RealtimeOverlayPartialState: Equatable {
    let sessionID: Int
    let rawText: String
    let normalizedText: String
    let confirmed: Bool
    let source: String
}

private struct RealtimeOverlayPartialSkipState: Equatable {
    let sessionID: Int
    let normalizedText: String
    let confirmed: Bool
    let reason: String
}

private enum ManualRecordingActivationKind {
    case ptt
    case toggle
}

private enum FluidAudioDownloadProgressNotification {
    static let name = Notification.Name("FluidAudioDownloadProgressDidChange")
    static let repoKey = "repo"
    static let completedKey = "completed"
    static let totalKey = "total"
    static let completedBytesKey = "completedBytes"
    static let totalBytesKey = "totalBytes"
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let analyticsInstallIDDefaultsKey = "telemetryInstallID"
    private static let postHogDidTrackInstallDefaultsKey = "posthogDidTrackInstall"

    private var statusItem: NSStatusItem?
    private var microphoneMenuAction: NSMenuItem?
    private var statusMenuItem: NSMenuItem?  // cached for lightweight state updates
    private var overlayPanel: OverlaySurface!

    let viewModel = AppViewModel()

    private let appState = AppState()
    private let audioCapture = AudioCaptureService()
    private let transcriptionService = TranscriptionService()
    private let clipboardService = ClipboardService()
    private let hotkeyManager = HotkeyManager()

    private let globalShortcutMonitor = GlobalShortcutMonitor()
    private var isShortcutCaptureSuspended = false
    private var localShortcutMonitor: Any?
    private var lastMicToggleTriggerTime: CFAbsoluteTime = 0
    private var lastLLMCleanupToggleTriggerTime: CFAbsoluteTime = 0

    // Engine loading state
    private var isEngineLoading = false {
        didSet {
            guard oldValue != isEngineLoading else { return }
            viewModel.isEngineLoading = isEngineLoading
            syncEngineLoadingDiagnostics()
        }
    }
    /// Tracks whether the last audio capture event was a failure (for device switch recovery telemetry).
    private var hadAudioFailure = false

    // Manual recording state
    private var isManualRecording = false
    private var isToggleRecording = false
    private var manualRecordingActivationGeneration: UInt = 0
    private var isTranscriptionInProgress = false
    private var nextTranscriptionRequestID: UInt64 = 0
    /// The app/element/window that were active when manual recording started, for sticky text delivery.
    private var manualRecordingOriginApp: NSRunningApplication?
    private var manualRecordingOriginElement: AXUIElement?
    private var manualRecordingOriginWindow: AXUIElement?
    /// Auto-stop timer for toggle recordings (10 min max).
    private var toggleAutoStopWorkItem: DispatchWorkItem?
    /// Warning timer for approaching toggle recording limit (9 min).
    private var toggleWarningWorkItem: DispatchWorkItem?
    /// Debounce work item for menu rebuilds.
    private var menuRebuildWorkItem: DispatchWorkItem?
    private let customPromptMenuRebuildDelay: TimeInterval = 0.2

    private var selectedTranscriptionPreset: TranscriptionPreset {
        guard let rawValue = UserDefaults.standard.string(forKey: "transcriptionPreset"),
              let preset = TranscriptionPreset(rawValue: rawValue) else {
            return .stable
        }
        return preset.canonicalPreset
    }

    private var shouldShowPresetOverlay: Bool {
        selectedTranscriptionPreset == .realtimeCleanup
    }

    internal static func isLLMCleanupAvailable(for transcriptionPreset: TranscriptionPreset) -> Bool {
        transcriptionPreset.supportsLLMCleanup
    }

    internal static func effectiveTextCleanupMode(
        requestedMode: TextCleanupMode,
        transcriptionPreset: TranscriptionPreset
    ) -> TextCleanupMode {
        guard requestedMode == .llm, !isLLMCleanupAvailable(for: transcriptionPreset) else {
            return requestedMode
        }
        return .off
    }

    internal static func toggledLLMCleanupMode(
        currentMode: TextCleanupMode,
        transcriptionPreset: TranscriptionPreset
    ) -> TextCleanupMode? {
        guard isLLMCleanupAvailable(for: transcriptionPreset) else { return nil }
        return currentMode == .llm ? .off : .llm
    }

    internal static func shouldPrewarmLLMCleanupConnection(
        isCleanupEnabled: Bool,
        cleanupModelID: String
    ) -> Bool {
        LLMCleanupService.shouldWarmAPIConnection(
            isEnabled: isCleanupEnabled,
            modelID: cleanupModelID
        )
    }

    internal static func endpointingProfile(
        for preset: TranscriptionPreset,
        engine: TranscriptionEngineChoice
    ) -> EndpointingProfile {
        if engine == .parakeetRealtimeTdt || engine == .parakeetEou {
            return .realtimeParakeet
        }

        // Keep the faster batch endpointing path around as a hidden legacy mode,
        // but restore Stable itself to the older, less twitchy batch behavior.
        if preset == .stableExtraQuick {
            return .stableExtraQuick
        }

        return .standard
    }

    internal static func shouldSkipOnboardingForExistingInstall(
        defaults: UserDefaults,
        keychainService: String
    ) -> Bool {
        guard defaults.object(forKey: "hasCompletedOnboarding") == nil else { return false }

        let defaultsEvidenceKeys = [
            "stats.firstUseDate",
            "stats.totalWords",
            "stats.totalUtterances",
            "preferredInputDevice",
            "silenceTimeout",
            "vadThreshold",
            "energyThreshold",
            "transcriptionPreset",
            "experimentalMode",
            "experimentalEngine",
            "realtimeParakeetFinalizationMode",
            "realtimeEouShadowCleanupMode",
            "llmCleanupEnabled",
            "llmCleanupModel",
        ]

        if defaultsEvidenceKeys.contains(where: { defaults.object(forKey: $0) != nil }) {
            return true
        }

        let keychainEvidenceKeys = [
            "com.blazing.fast-transcription.instanceId",
        ]

        return keychainEvidenceKeys.contains {
            AppKeychainStore.load(key: $0, service: keychainService) != nil
        }
    }

    internal static func shouldAllowRealtimeOverlayPartialDisplay(
        recordingMode: RecordingMode,
        isManualRecording: Bool,
        isToggleRecording: Bool
    ) -> Bool {
        recordingMode != .manual || isManualRecording || isToggleRecording
    }

    internal static func shouldPreferDirectRealtimeTyping(
        preset: TranscriptionPreset,
        bundleIdentifier: String?,
        appName: String?
    ) -> Bool {
        guard preset == .powerUserFastest else { return false }
        return BrowserHostPolicy.prefersDirectRealtimeTyping(
            bundleIdentifier: bundleIdentifier,
            appName: appName
        )
    }

    internal static func shouldAllowModeToggle(
        isManualRecording: Bool,
        isToggleRecording: Bool,
        isPTTShortcutHeld: Bool
    ) -> Bool {
        guard !isToggleRecording else { return false }
        // Double-tap fn ends PTT on the first tap, then asks to switch modes on the
        // second tap while manual teardown is still unwinding. That path should stay
        // allowed as soon as fn is no longer physically held.
        return !(isManualRecording && isPTTShortcutHeld)
    }

    private var realtimeFinalizationMode: RealtimeFinalizationMode {
        // When terminal inline cleanup is active, we need cleanup to produce corrections
        if terminalInlineCleanupMode != .off {
            return .speedPlusCleanup
        }
        if let mode = selectedTranscriptionPreset.realtimeFinalizationMode {
            return mode
        }
        guard let rawValue = UserDefaults.standard.string(forKey: "realtimeParakeetFinalizationMode"),
              let mode = RealtimeFinalizationMode(rawValue: rawValue) else {
            return .pureSpeed
        }
        return mode
    }

    private var realtimeShadowCleanupMode: RealtimeShadowCleanupMode {
        // Deferred and inline cleanup need shadow cleanup in field mode to get corrections during streaming
        let cleanupMode = terminalInlineCleanupMode
        if cleanupMode == .deferredCleanup || cleanupMode == .inlineCleanup {
            return .field
        }
        if let mode = selectedTranscriptionPreset.realtimeShadowCleanupMode {
            return mode
        }
        guard let rawValue = UserDefaults.standard.string(forKey: "realtimeEouShadowCleanupMode"),
              let mode = RealtimeShadowCleanupMode(rawValue: rawValue) else {
            return .off
        }
        return mode
    }

    /// Keep mic engine running between PTT presses for zero-latency recording.
    /// When off, the mic only activates while recording (no orange dot between presses, but ~0.7s startup delay).
    private var keepMicReady: Bool {
        !UserDefaults.standard.bool(forKey: "disableKeepMicReady")  // default: true (keep ready)
    }

    /// Manual realtime needs a warm capture path, otherwise fn press pays a cold-mic
    /// startup penalty and early speech can land before samples are flowing.
    private var shouldKeepCaptureRunningBetweenManualPresses: Bool {
        let mode = ShortcutConfig.shared.recordingMode
        return mode == .alwaysOn || keepMicReady || (mode == .manual && selectedTranscriptionPreset.usesRealtimeEngine)
    }

    private var isMicCaptureActive: Bool {
        audioCapture.isRunning || appState.isListening || appState.isRecording || isManualRecording || isToggleRecording
    }

    /// Tracks whether the mic was explicitly muted via the mic toggle shortcut (Cmd+Shift+M).
    /// Cleared when unmuting, switching recording modes, or starting a new recording.
    private var isMicMuted = false

    // MARK: - Dev Low-Latency Tuning

    private var turboModeEnabled: Bool {
        UserDefaults.standard.bool(forKey: "turboMode")
    }

    // MARK: - Realtime LLM Cleanup Mode

    private var realtimeLLMCleanupMode: RealtimeLLMCleanupMode {
        guard let rawValue = UserDefaults.standard.string(forKey: "realtimeLLMCleanupMode"),
              let mode = RealtimeLLMCleanupMode(rawValue: rawValue) else {
            return .off
        }
        return mode
    }

    private var realtimeLLMShadowRunner: RealtimeLLMShadowRunner?
    private var realtimeSentenceChunker: RealtimeSentenceChunker?

    // MARK: - Dev Terminal Cleanup

    private var terminalInlineCleanupMode: TerminalInlineCleanupMode {
        guard let rawValue = UserDefaults.standard.string(forKey: "terminalInlineCleanupMode"),
              let mode = TerminalInlineCleanupMode(rawValue: rawValue) else {
            return .off
        }
        return mode
    }

    /// Engine recreation was deferred because a session was active when cleanup mode changed.
    private var pendingEngineRecreation = false

    // Speech queue: holds samples that arrive while engine is busy
    private var pendingSpeechQueue: [PendingTranscriptionRequest] = []
    private var pendingAlwaysOnBatchCarryover: AlwaysOnBatchCarryover?
    private var activeTranscriptionRequest: PendingTranscriptionRequest?
    private var activeTranscriptionEngine: TranscriptionEngineChoice = .parakeetV3
    private var engineLoadGeneration: Int = 0
    private var cachedFluidAudioContext: FluidAudioContext?
    private var keepWarmTimer: Timer?
    private static let keepWarmInterval: TimeInterval = 30
    // Mic idle-sleep ("Sleep When Idle"): poll the mic state and turn it fully
    // off after `micIdleSleepMinutes` without dictation. Default 15; 0 = never.
    private var micIdleTimer: Timer?
    private static let micIdleCheckInterval: TimeInterval = 30
    private var micIdleAccumulatedSeconds: TimeInterval = 0
    private var cachedRealtimeEouPreset: TranscriptionPreset?
    private var cachedRealtimeEouContext: ASRContext?
    private var cachedRealtimeEouService: RealtimeEouService?
    private var realtimeParakeetService: RealtimeParakeetService?
    private var realtimeEouService: RealtimeEouService?
    private let realtimeOperationQueue = RealtimeOperationQueue()
    private let realtimeAudioLock = NSLock()
    private var realtimeStreamingArmed = false
    private var manualRealtimeCapturedSampleCount = 0
    private var realtimeStartInFlight = false
    private var realtimePendingAudioBlocks: [[Float]] = []
    private var realtimePendingFinish: (samples: [Float], duration: Double, endpointDetectedAt: Date)?
    private var realtimeSessionID: Int?
    private var realtimeFinishingSessionID: Int?
    private var realtimeDeferredStartTiming: SpeechStartTiming?
    private var realtimeDeferredStartPrerollSamples: [Float] = []
    private var realtimeSpeechStartDetectedAt: Date?
    private var realtimeFirstPartialAt: Date?
    private var realtimeEndpointDetectedAt: Date?
    private var realtimeProvisionalSession: ProvisionalTextSession?
    private var realtimeShouldSuppressFinalCommit = false
    private var realtimeUsingOverlayFallback = false
    private var realtimeUsingDirectTypingFallback = false
    private var realtimeTargetIsTerminal = false
    private var realtimeTerminalTypedText = ""
    private var realtimeTerminalDeferredStreamText: String?
    private var realtimeDisplayedText = ""
    private var realtimeOverlayShadowPinned = false
    private var realtimeOverlayShadowText = ""
    private var realtimeShadowCandidateText: String?
    private var realtimeShadowCandidateStreak = 0
    private var realtimeLastShownOverlayPartial: RealtimeOverlayPartialState?
    private var realtimeLastOverlayPartialSkipState: RealtimeOverlayPartialSkipState?
    private var realtimeDiagnosticsSessionStartedAt: Date?
    private var realtimeDiagnosticsLastPartialAt: Date?
    private var realtimeDiagnosticsLastSummaryAt: Date?
    private var realtimeDiagnosticsLivePartialCount = 0
    private var realtimeDiagnosticsShadowPartialCount = 0
    private var realtimeDiagnosticsShadowPromotionCount = 0
    private var realtimeDiagnosticsLargeRollbackCount = 0
    private var realtimeDiagnosticsFreezeAppliedCount = 0
    private var realtimeDiagnosticsEmittedWarnings: Set<String> = []
    private let realtimeFreezeTailWords = 5
    private var realtimeOverlayOnlyBufferedFinalText = ""
    private var realtimeOverlayOnlyCommitWorkItem: DispatchWorkItem?
    private let realtimeOverlayOnlyCommitDelay: TimeInterval = 0.45
    private let realtimeOverlayMinimumDwell: TimeInterval = 0.45

    private var realtimeUsesOverlayOnlyMode: Bool {
        activeTranscriptionEngine == .parakeetEou &&
            realtimeFinalizationMode == .speedPlusCleanup &&
            realtimeShadowCleanupMode == .overlay
    }

    private var shouldUseRealtimeEngineForCurrentMode: Bool {
        guard activeTranscriptionEngine == .parakeetRealtimeTdt || activeTranscriptionEngine == .parakeetEou else {
            return false
        }

        if ShortcutConfig.shared.recordingMode == .alwaysOn {
            return true
        }

        return ShortcutConfig.shared.recordingMode == .manual && isManualRecording
    }

    private var shouldSuppressDefaultOverlayStates: Bool {
        ShortcutConfig.shared.recordingMode == .manual
    }

    private var shouldDeferOverlayStateToRealtimeSession: Bool {
        shouldSuppressDefaultOverlayStates && selectedTranscriptionPreset.usesRealtimeEngine
    }

    // Speech duration tracking for stats
    private var lastSpeechDuration: Double = 0
    private var currentInputDeviceState: AudioInputDeviceState?

    private let keyboardInjector = KeyboardInjector()

    // Legacy window references removed — UI is now SwiftUI-based

    // Main window is managed by SwiftUI's Window scene

    #if DEBUG
    private let forcedManualTranscriptionFailureDefaultsKey = "debugFailNextManualTranscription"

    private var isForcedManualTranscriptionFailureArmed: Bool {
        UserDefaults.standard.bool(forKey: forcedManualTranscriptionFailureDefaultsKey)
    }

    private let debugShortToggleTimersKey = "debugShortToggleTimers"

    private var isDebugShortToggleTimersEnabled: Bool {
        UserDefaults.standard.bool(forKey: debugShortToggleTimersKey)
    }
    #endif

    // Auto-updates
    private var updaterController: SPUStandardUpdaterController!
    /// Prevents macOS App Nap from throttling audio processing.
    private var activityToken: NSObjectProtocol?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--experience-preview") || Bundle.main.bundleIdentifier == "com.blazingtranscribe.experience-preview" {
            configureExperiencePreview()
            return
        }
        #endif
        // Let windows resolve appearance from the real environment. A global
        // Aqua override forces the overlay into a static light baseline and
        // breaks Liquid Glass adaptation on macOS 26.
        NSApp.appearance = nil
        UserDefaults.standard.register(defaults: ["micIdleSleepMinutes": 15])
        NSApp.setActivationPolicy(userWantsDockIcon ? .regular : .accessory)
        applyApplicationIcon()

        // Prevent App Nap — critical for real-time audio latency
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Real-time audio transcription"
        )

        // Analytics — the official signed build ships a real PostHog key via the
        // gitignored AnalyticsSecrets.swift; source/fork builds compile with the
        // empty template and stay telemetry-free.
        if !AnalyticsSecrets.postHogAPIKey.isEmpty {
            // Stable per-install anonymous ID so PostHog can distinguish users.
            // Without this, macOS has no identifierForVendor and all users share one identity.
            let installID: String
            if let existing = UserDefaults.standard.string(forKey: Self.analyticsInstallIDDefaultsKey) {
                installID = existing
            } else {
                let newID = UUID().uuidString
                UserDefaults.standard.set(newID, forKey: Self.analyticsInstallIDDefaultsKey)
                installID = newID
            }

            let posthogConfig = PostHogConfig(apiKey: AnalyticsSecrets.postHogAPIKey, host: AnalyticsSecrets.postHogHost)
            posthogConfig.captureApplicationLifecycleEvents = false
            posthogConfig.flushAt = 1  // Send every event immediately — default (20) drops events from short sessions
            PostHogSDK.shared.setup(posthogConfig)
            PostHogSDK.shared.identify(installID)
            PostHogSDK.shared.register(["isOfficialBuild": AnalyticsSecrets.isOfficialBuild])
            syncPostHogAnalyticsState(includePersonProperties: true)

            // Track install once ever, using our own UserDefaults flag.
            // PostHog's auto "Application Installed" was misfiring on every launch
            // because its file-backed storage doesn't persist reliably on macOS.
            if !UserDefaults.standard.bool(forKey: Self.postHogDidTrackInstallDefaultsKey) {
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
                let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
                PostHogSDK.shared.capture("Application Installed", properties: [
                    "version": version,
                    "build": build,
                ])
                UserDefaults.standard.set(true, forKey: Self.postHogDidTrackInstallDefaultsKey)
            }
        }

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        trackEvent("appLaunched", parameters: ["version": appVersion])

        // Track shortcut configuration on launch
        let config = ShortcutConfig.shared
        config.clearLegacyModeToggleShortcut()
        trackEvent("shortcutConfig", parameters: [
            "recordingMode": config.recordingMode.rawValue,
            "pttShortcut": config.pttShortcut.displayString,
            "toggleShortcut": config.toggleShortcut.displayString,
            "micToggleShortcut": config.micToggleShortcut.displayString,
            "modeToggleShortcut": config.modeToggleShortcut?.displayString ?? "double-click fn",
        ])

        // Suppress verbose whisper.cpp/ggml debug logging (VAD uses whisper C library)
        whisper_log_set(whisperLogCallback, nil)

        // Initialize Sparkle auto-updater (skip in DEBUG — unsigned binaries can't use Sparkle)
        #if DEBUG
        updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        #else
        updaterController = SPUStandardUpdaterController(startingUpdater: Bundle.main.object(forInfoDictionaryKey: "BlazingLocalTestBuild") as? Bool != true, updaterDelegate: nil, userDriverDelegate: nil)
        #endif

        loadSavedPreferences()
        ensureLaunchAtLoginDefaultIfNeeded()
        setupOverlay()
        setupMenuBar()
        setupWindowVisibilityObservers()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleUsageStatsChange),
            name: .usageStatsDidChange,
            object: nil
        )

        proceedWithStartup()

        // Sleep/wake handling for audio engine recovery
        let wsnc = NSWorkspace.shared.notificationCenter
        wsnc.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        wsnc.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)

        // Crash detection — flag that we're running
        let wasRunning = UserDefaults.standard.bool(forKey: "appIsRunning")
        UserDefaults.standard.set(true, forKey: "appIsRunning")
        if wasRunning {
            appLog("Recovered from unexpected quit — previous session did not terminate cleanly")
            trackEvent("crashRecovered", parameters: ["version": appVersion])
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "appIsRunning")
        windowVisibilityObservers.forEach(NotificationCenter.default.removeObserver)
        windowVisibilityObservers.removeAll()
        audioCapture.stop()
        hotkeyManager.unregister()
        globalShortcutMonitor.stop()
        stopKeepWarmTimer()
        stopMicIdleTimer()
        DiagnosticsService.shared.stop()
    }

    // MARK: - Sleep / Wake

    @objc private func systemWillSleep(_ notification: Notification) {
        appLog("System going to sleep — stopping audio capture")
        audioCapture.stop()
    }

    @objc private func systemDidWake(_ notification: Notification) {
        appLog("System woke — restarting audio capture after delay")
        // Delay restart to let audio hardware reinitialize
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            let mode = ShortcutConfig.shared.recordingMode
            if mode == .alwaysOn || self.keepMicReady {
                self.audioCapture.restart(continuousMode: mode == .alwaysOn)
            }
        }
        // Sleep almost always evicts the CoreML model from the ANE.
        // Restart fires an immediate keep-warm tick, then resumes cadence.
        startKeepWarmTimer()
    }

    @objc private func handleUsageStatsChange(_ notification: Notification) {
        syncPostHogAnalyticsState()
    }

    // MARK: - Setup

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = BlazingMark.menuBarImage()
        }

        rebuildMenu()
    }

    private func applyApplicationIcon() {
        let fileManager = FileManager.default
        let candidateURLs: [URL] = [
            Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/AppIcon.icns"),
            URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent("Resources/AppIcon.icns"),
        ].compactMap { $0 }

        guard let iconURL = candidateURLs.first(where: { fileManager.fileExists(atPath: $0.path) }),
              let iconImage = NSImage(contentsOf: iconURL) else { return }

        NSApp.applicationIconImage = iconImage
    }

    private var isCurrentEngineDownloadPending: Bool {
        let tdtCached = AsrModels.modelsExist(
            at: AsrModels.defaultCacheDirectory(for: .v3),
            version: .v3
        )

        switch activeTranscriptionEngine {
        case .parakeetV3, .parakeetRealtimeTdt:
            return !tdtCached
        case .parakeetEou:
            let eouCached = FluidAudioModelStore.hasRealtimeEou160Models()
            let cleanupNeedsTdt = selectedTranscriptionPreset == .realtimeCleanup && !tdtCached
            return !eouCached || cleanupNeedsTdt
        case .deepgramFlux, .deepmind:
            return false
        }
    }

    private var currentEngineStartupOverlayStatus: OverlayPanel.Status {
        isCurrentEngineDownloadPending ? .downloading : .loading
    }

    private var currentEngineLoadingTitle: String {
        isCurrentEngineDownloadPending ? "Downloading model..." : "Starting transcription..."
    }

    private func resetEngineDownloadProgress() {
        viewModel.currentEngineDownloadProgress = nil
        viewModel.currentEngineDownloadCompletedFiles = 0
        viewModel.currentEngineDownloadTotalFiles = 0
        viewModel.currentEngineDownloadCompletedBytes = 0
        viewModel.currentEngineDownloadTotalBytes = 0
        viewModel.currentEngineDownloadRepoName = nil
    }

    private func syncEngineLoadingDiagnostics() {
        viewModel.isCurrentEngineDownloadPending = isCurrentEngineDownloadPending

        if !isEngineLoading {
            resetEngineDownloadProgress()
        } else if !isCurrentEngineDownloadPending, viewModel.currentEngineDownloadProgress == nil {
            viewModel.currentEngineDownloadProgress = 1
        }
    }

    private func handleFluidAudioDownloadProgress(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let repo = userInfo[FluidAudioDownloadProgressNotification.repoKey] as? String,
              let completed = userInfo[FluidAudioDownloadProgressNotification.completedKey] as? Int,
              let total = userInfo[FluidAudioDownloadProgressNotification.totalKey] as? Int else {
            return
        }

        guard repo.contains("parakeet") else { return }

        let completedBytes = userInfo[FluidAudioDownloadProgressNotification.completedBytesKey] as? Int64 ?? 0
        let totalBytes = userInfo[FluidAudioDownloadProgressNotification.totalBytesKey] as? Int64 ?? 0

        viewModel.currentEngineDownloadRepoName = repo
        viewModel.currentEngineDownloadCompletedFiles = completed
        viewModel.currentEngineDownloadTotalFiles = total
        viewModel.currentEngineDownloadCompletedBytes = completedBytes
        viewModel.currentEngineDownloadTotalBytes = totalBytes
        // Byte-based progress when available — file counts alone freeze for
        // minutes while the single large encoder weights file downloads.
        if totalBytes > 0 {
            viewModel.currentEngineDownloadProgress = Double(completedBytes) / Double(totalBytes)
        } else {
            viewModel.currentEngineDownloadProgress = total > 0 ? Double(completed) / Double(total) : nil
        }
        syncEngineLoadingDiagnostics()
    }

    private func rebuildMenu() {
        guard let statusItem else { return }
        syncEngineLoadingDiagnostics()

        // Skip rebuild while menu is visible to prevent jittering
        if let existingMenu = statusItem.menu, existingMenu.highlightedItem != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.rebuildMenu()
            }
            return
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        status.isEnabled = false
        statusMenuItem = status
        menu.addItem(status)

        let microphone = NSMenuItem(title: "", action: #selector(toggleMicrophoneFromMenu), keyEquivalent: "")
        microphone.target = self
        microphoneMenuAction = microphone
        menu.addItem(microphone)
        menu.addItem(.separator())

        for (title, action) in [
            ("Open Blazing", #selector(showMainWindow)),
            ("History", #selector(showHistoryWindow)),
            ("Settings…", #selector(showSettingsWindow))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Blazing", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
        updateStatusMenuItem()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateStatusMenuItem()
    }

    @objc func showSettingsWindow() {
        viewModel.requestedWindowSection = .general
        showMainWindow()
    }

    @objc private func showHistoryWindow() {
        viewModel.requestedWindowSection = .history
        showMainWindow()
    }

    #if DEBUG
    func showExperiencePreviewMenu() {
        setupMenuBar()
    }

    func openExperiencePreviewMenu() {
        guard let window = NSApp.keyWindow, let content = window.contentView else { return }
        statusItem?.menu?.popUp(positioning: nil, at: NSPoint(x: content.bounds.maxX - 220, y: content.bounds.maxY - 40), in: content)
    }
    #endif

    @objc private func copyDiagnostics() {
        DiagnosticsService.shared.copyToClipboard()
    }

    // MARK: - Sustained slowness (user-facing)

    /// Set when DiagnosticsService reports several consecutive slow
    /// utterances; drives the warning item in the menu. Cleared on recovery.
    private var isPerformanceDegraded = false

    private func handleSustainedSlowness(advice: String) {
        appLog("Sustained slow transcription detected")
        isPerformanceDegraded = true
        scheduleMenuRebuild()
        guard !appState.isRecording, !isTranscriptionInProgress else { return }
        overlayPanel.show(status: .warning("Transcription is running slow — see Settings for diagnostics"))
    }

    private func handleSlownessRecovered() {
        appLog("Transcription performance recovered")
        isPerformanceDegraded = false
        scheduleMenuRebuild()
    }

    @objc private func showSlownessDetails() {
        let alert = NSAlert()
        alert.messageText = "Transcription is running slower than usual"
        alert.informativeText = DiagnosticsService.shared.slownessAdvice()
        alert.addButton(withTitle: "Copy Diagnostics")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            DiagnosticsService.shared.copyToClipboard()
        }
    }

    /// Coalesced menu rebuild — batches same-runloop updates without adding visible lag.
    private func scheduleMenuRebuild(after delay: TimeInterval = 0) {
        menuRebuildWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.rebuildMenu()
        }
        menuRebuildWorkItem = work
        if delay <= 0 {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// Update the status menu item title in-place without rebuilding the whole menu.
    private func updateStatusMenuItem() {
        guard let item = statusMenuItem else { return }
        let status = MicrophonePresentation.resolve(
            state: appState.currentState, captureRunning: audioCapture.isRunning,
            engineReady: transcriptionService.isReady, loading: isEngineLoading,
            permissionsGranted: KeyboardInjector.hasAccessibilityPermission
                && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            mode: ShortcutConfig.shared.recordingMode)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--experience-preview") || Bundle.main.bundleIdentifier == "com.blazingtranscribe.experience-preview" {
            item.title = "Mic off"
            microphoneMenuAction?.title = "Resume microphone"
            microphoneMenuAction?.isEnabled = false
            return
        }
        #endif
        item.title = isPerformanceDegraded ? "Dictation needs attention" : status.title
        item.isEnabled = false
        microphoneMenuAction?.title = audioCapture.isRunning ? "Pause microphone" : "Resume microphone"
        microphoneMenuAction?.isEnabled = transcriptionService.isReady && !isTranscriptionInProgress

    }

    @objc private func toggleMicrophoneFromMenu() {
        performMicToggleShortcut()
    }

    private func makeMenuSectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title.uppercased(), action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func setupOverlay() {
        overlayPanel = OverlaySurface.create()
        DispatchQueue.main.async { [weak self] in
            self?.overlayPanel.prewarmIfNeeded()
        }
    }

    private func syncPostHogAnalyticsState(includePersonProperties: Bool = false) {
        guard !AnalyticsSecrets.postHogAPIKey.isEmpty else { return }
        let properties = makePostHogAnalyticsProperties()
        PostHogSDK.shared.register(properties)
        guard includePersonProperties else { return }
        PostHogSDK.shared.setPersonProperties(userPropertiesToSet: properties)
    }

    private func makePostHogAnalyticsProperties() -> [String: Any] {
        let stats = UsageStats.shared
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let properties: [String: Any] = [
            "appVersion": appVersion,
            "build": build,
            "planType": "free",
            "totalWords": stats.totalWords,
            "totalUtterances": stats.totalUtterances,
            "totalCharacters": stats.totalCharacters,
            "totalSpeechSeconds": roundedAnalyticsValue(stats.totalSpeechSeconds),
            "totalTranscriptionSeconds": roundedAnalyticsValue(stats.totalTranscriptionSeconds),
            "recordingMode": ShortcutConfig.shared.recordingMode.rawValue,
            "transcriptionPreset": selectedTranscriptionPreset.rawValue,
        ]

        return properties
    }

    private func roundedAnalyticsValue(_ value: Double) -> Double {
        Double(String(format: "%.2f", value)) ?? 0.0
    }

    @discardableResult
    private func recordCompletedTranscriptionUsage(
        text: String,
        transcriptionDuration: Double,
        speechDuration: Double,
        analyticsDurationSeconds: Double,
        source: String,
        engine: String,
        mode: String,
        finalization: String,
        cleanup: Bool,
        terminal: Bool,
        additionalParameters: [String: Any] = [:]
    ) -> Int {
        let wordCount = WordCounter.countWords(in: text)

        UsageStats.shared.record(
            wordCount: wordCount,
            characterCount: text.count,
            transcriptionDuration: transcriptionDuration,
            speechDuration: speechDuration
        )

        var parameters: [String: Any] = [
            "wordCount": wordCount,
            "durationSeconds": Double(String(format: "%.2f", analyticsDurationSeconds)) ?? 0.0,
            "engine": engine,
            "mode": mode,
            "source": source,
            "finalization": finalization,
            "cleanup": cleanup,
            "terminal": terminal,
            "turboMode": turboModeEnabled,
            "totalWords": UsageStats.shared.totalWords,
            "totalUtterances": UsageStats.shared.totalUtterances,
            "planType": "free",
        ]
        additionalParameters.forEach { parameters[$0.key] = $0.value }
        trackEvent("transcriptionCompleted", parameters: parameters)

        return wordCount
    }

    private func completeBatchTranscription(
        finalText: String,
        cleanupUsed: Bool,
        utterance: Utterance,
        completedRequest: PendingTranscriptionRequest?,
        batchSource: String
    ) {
        let finalWordCount = recordCompletedTranscriptionUsage(
            text: finalText,
            transcriptionDuration: utterance.duration,
            speechDuration: lastSpeechDuration,
            analyticsDurationSeconds: utterance.duration,
            source: batchSource,
            engine: activeTranscriptionEngine.rawValue,
            mode: "batch",
            finalization: "n/a",
            cleanup: cleanupUsed,
            terminal: false
        )

        if let retryID = completedRequest?.historyRetryID,
           TranscriptionHistoryStore.shared.markRetrySucceeded(
               id: retryID,
               text: finalText,
               wordCount: finalWordCount,
               transcriptionDuration: utterance.duration
           ) {
            cleanupRetainedAudioAfterSuccess(for: completedRequest)
            appLog("Retry transcription succeeded for history entry \(retryID.uuidString)")
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(finalText, forType: .string)
            NotificationCenter.default.post(name: .retryCopiedToClipboard, object: retryID)
            isTranscriptionInProgress = false
            appState.currentState = .idle
            processNextInQueue()
            return
        }

        cleanupRetainedAudioAfterSuccess(for: completedRequest)
        recordHistorySuccess(
            text: finalText,
            wordCount: finalWordCount,
            speechDuration: lastSpeechDuration,
            transcriptionDuration: utterance.duration,
            source: batchSource
        )

        if shouldRouteTranscriptionToOnboarding {
            viewModel.onboardingTranscriptionResult = finalText
            isTranscriptionInProgress = false
            appState.currentState = .idle
            processNextInQueue()
            return
        }

        let delivered = deliverText(finalText)
        if delivered,
           let endpointAt = completedRequest?.speechTiming?.endpointDetectedAt {
            let totalStopToTextMs = Int(Date().timeIntervalSince(endpointAt) * 1000)
            appLog("Timing: text-injected source=\(batchSource) total_stop_to_text_ms=\(totalStopToTextMs)")
        }
        if completedRequest?.source == "toggle", ShortcutConfig.shared.recordingMode != .manual {
            overlayPanel.show(status: .result(finalText, wordCount: finalWordCount, duration: utterance.duration))
        }
        processNextInQueue()
    }

    private func proceedWithStartup() {
        guard !viewModel.hasStartedServices else { return }
        appLog("Proceeding with startup")
        viewModel.hasStartedServices = true
        setupDelegates()
        setupAudioLevelMeter()
        setupStateObserver()
        setupViewModel()
        // Apply dev turbo settings from UserDefaults
        audioCapture.turboSilenceGate = turboModeEnabled
        rebuildMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            TranscriptionHistoryStore.shared.cleanupExpiredAudio()
        }
        // Onboarding is handled by SwiftUI OnboardingView via @AppStorage("hasCompletedOnboarding")
        startServices()
    }

    private func setupDelegates() {
        audioCapture.delegate = self
        transcriptionService.delegate = self
        hotkeyManager.delegate = self
        globalShortcutMonitor.delegate = self
        globalShortcutMonitor.logHandler = { appLog($0) }
        installLocalShortcutMonitorIfNeeded()
    }

    private func installLocalShortcutMonitorIfNeeded() {
        guard localShortcutMonitor == nil else { return }
        localShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleLocalShortcutKeyDown(event) ?? event
        }
    }

    private func handleLocalShortcutKeyDown(_ event: NSEvent) -> NSEvent? {
        guard viewModel.hasStartedServices, !isShortcutCaptureSuspended else { return event }

        let micShortcut = ShortcutConfig.shared.micToggleShortcut.asGlobalShortcut
        if micShortcut.canUseCarbonHotKey,
           micShortcut.matchesKeyEvent(
            keyCode: UInt32(event.keyCode),
            modifierRawValue: event.modifierFlags.rawValue
           ) {
            triggerMicToggleShortcut(source: "localMonitor")
            return nil
        }

        let llmCleanupShortcut = GlobalShortcut.defaultLLMCleanupToggle
        if llmCleanupShortcut.canUseCarbonHotKey,
           llmCleanupShortcut.matchesKeyEvent(
            keyCode: UInt32(event.keyCode),
            modifierRawValue: event.modifierFlags.rawValue
           ) {
            triggerLLMCleanupToggleShortcut(source: "localMonitor")
            return nil
        }

        return event
    }

    private func triggerMicToggleShortcut(source: String) {
        let now = CFAbsoluteTimeGetCurrent()
        guard (now - lastMicToggleTriggerTime) > 0.15 else {
            #if DEBUG
            print("[App] Ignoring duplicate mic toggle from \(source)")
            #endif
            return
        }
        lastMicToggleTriggerTime = now
        performMicToggleShortcut()
    }

    private func performMicToggleShortcut() {
        let shouldEnableMic = !isMicCaptureActive
        trackEvent("micToggleUsed", parameters: [
            "action": shouldEnableMic ? "on" : "off",
            "shortcut": ShortcutConfig.shared.micToggleShortcut.displayString,
        ])
        if !shouldEnableMic {
            audioCapture.stop()
            audioCapture.cancelManualRecording()
            audioCapture.cancelToggleRecording()
            cancelToggleTimers()
            resetRealtimeDeliveryState()
            Task { [weak self] in
                await self?.cancelRealtimeStreamingUtterances()
            }
            isManualRecording = false
            isToggleRecording = false
            isMicMuted = true
            appState.currentState = .idle
            #if DEBUG
            print("[App] Mic OFF")
            #endif
        } else {
            guard transcriptionService.isReady else {
                #if DEBUG
                print("[App] Cannot start — ASR engine still loading")
                #endif
                return
            }
            isMicMuted = false
            audioCapture.start()
            if ShortcutConfig.shared.recordingMode == .alwaysOn {
                appState.currentState = .listening
            } else {
                appState.currentState = .idle
            }
            #if DEBUG
            print("[App] Mic ON")
            #endif
        }
    }

    private func triggerLLMCleanupToggleShortcut(source: String) {
        let now = CFAbsoluteTimeGetCurrent()
        guard (now - lastLLMCleanupToggleTriggerTime) > 0.15 else {
            #if DEBUG
            print("[App] Ignoring duplicate LLM cleanup toggle from \(source)")
            #endif
            return
        }
        lastLLMCleanupToggleTriggerTime = now
        performLLMCleanupToggleShortcut()
    }

    private func performLLMCleanupToggleShortcut() {
        let currentMode = Self.effectiveTextCleanupMode(
            requestedMode: TextCleanupMode.current,
            transcriptionPreset: selectedTranscriptionPreset
        )
        guard let nextMode = Self.toggledLLMCleanupMode(
            currentMode: currentMode,
            transcriptionPreset: selectedTranscriptionPreset
        ) else {
            appLog("LLM cleanup toggle ignored — unavailable for preset=\(selectedTranscriptionPreset.rawValue)")
            #if DEBUG
            print("[App] LLM cleanup toggle ignored — Turbo preset disables LLM cleanup")
            #endif
            return
        }

        applyTextCleanupMode(nextMode)
        appLog("LLM cleanup toggled via shortcut → \(viewModel.textCleanupMode.rawValue)")
        #if DEBUG
        print("[App] LLM cleanup toggled → \(viewModel.textCleanupMode.rawValue)")
        #endif
    }

    private func setupAudioLevelMeter() {
        audioCapture.onAudioLevel = { [weak self] level in
            self?.overlayPanel.updateAudioLevel(level)
            self?.viewModel.audioLevelMeter.level = level
        }
    }

    private func setupStateObserver() {
        appState.onStateChange = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .idle:
                self.updateMenuBarIcon(listening: false)
                if self.shouldShowPresetOverlay, !self.shouldSuppressDefaultOverlayStates {
                    self.overlayPanel.show(status: self.isMicMuted ? .muted : .idle)
                }
            case .listening:
                self.updateMenuBarIcon(listening: true)
            case .recording:
                self.updateMenuBarIcon(recording: true)
                if self.shouldShowPresetOverlay, !self.shouldSuppressDefaultOverlayStates {
                    self.overlayPanel.show(status: .recording)
                }
            case .transcribing:
                if self.shouldShowPresetOverlay, !self.shouldSuppressDefaultOverlayStates {
                    self.overlayPanel.show(status: .transcribing)
                }
            case .error(let message):
                if self.shouldShowPresetOverlay { self.overlayPanel.show(status: .error(message)) }
            }
            self.updateStatusMenuItem()
            if self.viewModel.appState != state {
                self.viewModel.appState = state
            }
        }
    }

    private func setupViewModel() {
        viewModel.configure(audioCapture: audioCapture)
        viewModel.recordingMode = ShortcutConfig.shared.recordingMode
        viewModel.transcriptionPreset = selectedTranscriptionPreset
        viewModel.isEngineLoading = isEngineLoading
        viewModel.isDeveloperTestingVisible = realtimeDiagnosticsEnabled
        viewModel.textCleanupMode = Self.effectiveTextCleanupMode(
            requestedMode: TextCleanupMode.current,
            transcriptionPreset: selectedTranscriptionPreset
        )
        viewModel.selectedLLMProviderModelID = LLMCleanupService.preferredAPIModelID
        viewModel.useLocalLLM = LLMCleanupService.useLocalModel
        if let localModel = LLMCleanupService.availableModels.first(where: { $0.id == LLMCleanupService.preferredLocalModelID }) {
            viewModel.isLocalModelDownloaded = LLMCleanupService.isModelDownloaded(localModel)
        }
        viewModel.groqAPIKey = LLMCleanupService.groqAPIKeyStored
        viewModel.isTurboModeEnabled = turboModeEnabled
        viewModel.isOnboardingPreviewActive = false
        syncEngineLoadingDiagnostics()

        // Action closures
        viewModel.refreshEngineReadiness = { [weak self] in self?.transcriptionService.isReady ?? false }
        viewModel.onToggleListening = { [weak self] in
            self?.performMicToggleShortcut()
        }
        viewModel.onSwitchRecordingMode = { [weak self] mode in
            // Optimistic UI: reflect change instantly before heavy work
            if self?.viewModel.recordingMode != mode {
                self?.viewModel.recordingMode = mode
            }
            self?.switchRecordingMode(mode)
        }
        viewModel.onSwitchPreset = { [weak self] preset in
            // Optimistic UI: reflect change instantly before heavy work
            let canonicalPreset = preset.canonicalPreset
            if self?.viewModel.transcriptionPreset != canonicalPreset {
                self?.viewModel.transcriptionPreset = canonicalPreset
            }
            self?.switchTranscriptionPreset(to: canonicalPreset)
        }
        viewModel.onUpdatePTTShortcut = { [weak self] shortcut in
            ShortcutConfig.shared.pttShortcut = shortcut
            self?.registerGlobalShortcuts()
        }
        viewModel.onUpdateToggleShortcut = { [weak self] shortcut in
            ShortcutConfig.shared.toggleShortcut = shortcut
            self?.registerGlobalShortcuts()
        }
        viewModel.onUpdateMicToggleShortcut = { [weak self] shortcut in
            ShortcutConfig.shared.micToggleShortcut = shortcut
            self?.registerGlobalShortcuts()
        }
        viewModel.onUpdateModeToggleShortcut = { [weak self] shortcut in
            ShortcutConfig.shared.modeToggleShortcut = shortcut
            self?.registerGlobalShortcuts()
        }
        viewModel.onCheckForUpdates = { [weak self] in
            guard Bundle.main.object(forInfoDictionaryKey: "BlazingLocalTestBuild") as? Bool != true else {
                let alert = NSAlert()
                alert.messageText = "You’re using a local test build"
                alert.informativeText = "Public updates are disabled for this build. Install a newer test build or restore your saved release to change versions."
                alert.runModal()
                return
            }
            self?.updaterController.checkForUpdates(nil)
        }
        viewModel.onCopyDiagnostics = { DiagnosticsService.shared.copyToClipboard() }
        viewModel.onCopyLogs = { [weak self] in
            self?.copyLogsToClipboard()
        }
        viewModel.onOpenMainWindow = { [weak self] in
            self?.showMainWindow()
        }
        viewModel.onQuit = {
            NSApp.terminate(nil)
        }
        viewModel.onSetLowLatencyTuningEnabled = { [weak self] isEnabled in
            self?.setLowLatencyTuningEnabled(isEnabled)
        }
        viewModel.onSwitchTextCleanup = { [weak self] mode in
            self?.applyTextCleanupMode(mode)
        }
        viewModel.onSelectLLMProvider = { [weak self] modelID in
            self?.setPreferredLLMProviderModel(modelID)
        }
        viewModel.onToggleLocalLLM = { [weak self] useLocal in
            self?.setUseLocalLLM(useLocal)
        }
        viewModel.onSelectLocalModel = { [weak self] modelID in
            self?.setUseLocalLLM(true, localModelID: modelID)
        }
        viewModel.onCustomPromptChanged = { [weak self] prompt in
            let trimmed = LLMCleanupService.applyDashboardCustomPrompt(prompt)
            self?.viewModel.customPromptInstruction = trimmed
            self?.viewModel.isCustomPromptEnabled = !trimmed.isEmpty
            self?.scheduleMenuRebuild(after: self?.customPromptMenuRebuildDelay ?? 0)
        }
        viewModel.onGroqAPIKeyChanged = { [weak self] apiKey in
            LLMCleanupService.groqAPIKeyStored = apiKey
            self?.viewModel.groqAPIKey = apiKey
            self?.scheduleMenuRebuild()
        }
        viewModel.onGeminiAPIKeyChanged = { [weak self] apiKey in
            LLMCleanupService.geminiAPIKeyStored = apiKey
            self?.viewModel.geminiAPIKey = apiKey
            self?.scheduleMenuRebuild()
        }
        LLMCleanupService.onCleanupFallback = { [weak self] reason in
            DispatchQueue.main.async {
                self?.handleCleanupFallback(reason)
            }
        }
        DiagnosticsService.shared.onSustainedSlowness = { [weak self] advice in
            DispatchQueue.main.async {
                self?.handleSustainedSlowness(advice: advice)
            }
        }
        DiagnosticsService.shared.onSlownessRecovered = { [weak self] in
            DispatchQueue.main.async {
                self?.handleSlownessRecovered()
            }
        }
        viewModel.onOpenOnboardingPreview = { [weak self] in
            guard let self else { return }
            if self.practicePreviousPreferences == nil {
                self.practicePreviousPreferences = (ShortcutConfig.shared.recordingMode, self.selectedTranscriptionPreset)
            }
            self.switchRecordingMode(.manual)
            self.switchTranscriptionPreset(to: .stable)
            self.viewModel.onboardingTranscriptionResult = nil
            self.viewModel.isOnboardingPreviewActive = true
            self.showMainWindow()
        }
        viewModel.onCloseOnboardingPreview = { [weak self] in
            if self?.isManualRecording == true {
                self?.pttDidCancel()
            }
            self?.viewModel.isOnboardingPreviewActive = false
            self?.viewModel.onboardingTranscriptionResult = nil
            if let self, let previous = self.practicePreviousPreferences {
                self.practicePreviousPreferences = nil
                self.switchTranscriptionPreset(to: previous.1)
                self.switchRecordingMode(previous.0)
            }
        }
        viewModel.onStartOnboardingRecording = { [weak self] in
            self?.pttDidPress()
        }
        viewModel.onStopOnboardingRecording = { [weak self] in
            self?.pttDidRelease()
        }
        viewModel.onResetVoiceModels = { [weak self] in
            self?.resetVoiceModelsForOnboardingTesting()
        }
        viewModel.onResetAccessibilityPermission = { [weak self] in
            self?.resetSystemPermissionForTesting(
                service: "Accessibility",
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            )
        }
        viewModel.onResetMicrophonePermission = { [weak self] in
            self?.resetSystemPermissionForTesting(
                service: "Microphone",
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            )
        }

        viewModel.onTrackOnboardingEvent = { name, params in
            trackEvent(name, parameters: params)
        }

        viewModel.onReloadEngine = { [weak self] in
            guard let self else { return }
            self.switchEngine(to: self.activeTranscriptionEngine)
        }

        // Observe mode changes (with equality guards to avoid redundant sets)
        NotificationCenter.default.addObserver(forName: .recordingModeDidChange, object: nil, queue: .main) { [weak self] notification in
            if let mode = notification.userInfo?["mode"] as? RecordingMode,
               self?.viewModel.recordingMode != mode {
                self?.viewModel.recordingMode = mode
            }
        }
        NotificationCenter.default.addObserver(forName: .transcriptionPresetDidChange, object: nil, queue: .main) { [weak self] _ in
            if let self = self {
                let latest = self.selectedTranscriptionPreset
                if self.viewModel.transcriptionPreset != latest {
                    self.viewModel.transcriptionPreset = latest
                }
            }
        }
        NotificationCenter.default.addObserver(forName: .shortcutCaptureStateDidChange, object: nil, queue: .main) { [weak self] notification in
            let isCapturing = notification.userInfo?[ShortcutCaptureNotificationKey.isCapturing] as? Bool ?? false
            self?.setShortcutCaptureSuspended(isCapturing)
        }
        NotificationCenter.default.addObserver(forName: .customVocabularyDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.refreshCustomVocabularyIntegrations()
        }
        NotificationCenter.default.addObserver(forName: .overlayAppearanceDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.overlayPanel.reloadConfiguration()
        }
        NotificationCenter.default.addObserver(forName: .overlayEnabledDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.overlayPanel.reloadConfiguration()
        }
        NotificationCenter.default.addObserver(forName: .retryTranscriptionRequested, object: nil, queue: .main) { [weak self] notification in
            guard let id = notification.object as? UUID else { return }
            self?.retryTranscription(id: id)
        }
        NotificationCenter.default.addObserver(
            forName: FluidAudioDownloadProgressNotification.name,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleFluidAudioDownloadProgress(notification)
        }
        // keepMicReadyDidChange handled by selector-based observer in startServices()

        syncTextCleanupAvailabilityForCurrentPreset()
    }

    private func loadSavedPreferences() {
        migrateOnboardingCompletionIfNeeded()
        migrateTranscriptionPresetIfNeeded()
        normalizeHiddenTranscriptionPresetIfNeeded()
        migrateLegacyLLMCleanupModelIfNeeded()
        applyDefaultTextCleanupIfNeeded()

        let defaults = UserDefaults.standard
        if defaults.object(forKey: "silenceTimeout") != nil {
            audioCapture.silenceTimeout = defaults.double(forKey: "silenceTimeout")
        }
        if defaults.object(forKey: "vadThreshold") != nil {
            audioCapture.vadThreshold = Float(defaults.double(forKey: "vadThreshold"))
        }

        if defaults.object(forKey: "energyThreshold") != nil {
            audioCapture.energyThreshold = Float(defaults.double(forKey: "energyThreshold"))
        }

        // Migrate old shortcut defaults (v2: Cmd+Option+M → Cmd+Shift+M, remove Cmd+Shift+V action)
        if !defaults.bool(forKey: "shortcutMigrationV2") {
            defaults.set(true, forKey: "shortcutMigrationV2")
            defaults.removeObject(forKey: "shortcut.action")
            defaults.removeObject(forKey: "shortcut.micToggle")
            #if DEBUG
            print("[App] Migration: cleared old shortcut defaults")
            #endif
        }

        #if DEBUG
        print("[App] Loaded prefs — silence: \(audioCapture.silenceTimeout)s, vadThreshold: \(audioCapture.vadThreshold)")
        #endif
    }

    private func migrateOnboardingCompletionIfNeeded(
        defaults: UserDefaults = .standard,
        keychainService: String = Constants.bundleIdentifier
    ) {
        guard Self.shouldSkipOnboardingForExistingInstall(
            defaults: defaults,
            keychainService: keychainService
        ) else {
            return
        }

        defaults.set(true, forKey: "hasCompletedOnboarding")

        #if DEBUG
        print("[App] Migration: marked onboarding complete for existing install")
        #endif
    }

    internal static func defaultTextCleanupSelection(
        existingCleanupEnabled: Bool?,
        existingCleanupModelID: String?
    ) -> (isEnabled: Bool, modelID: String)? {
        guard existingCleanupEnabled == nil,
              existingCleanupModelID == nil else {
            return nil
        }

        return (true, "regex")
    }

    internal static func migratedLLMCleanupModelID(_ existingModelID: String?) -> String? {
        switch existingModelID {
        case "api-gemini-2.5-flash":
            return LLMCleanupService.defaultAPIModelID
        default:
            return existingModelID
        }
    }

    private func migrateLegacyLLMCleanupModelIfNeeded(defaults: UserDefaults = .standard) {
        let existingModelID = defaults.string(forKey: "llmCleanupModel")
        guard let migratedModelID = Self.migratedLLMCleanupModelID(existingModelID),
              migratedModelID != existingModelID else {
            return
        }

        defaults.set(migratedModelID, forKey: "llmCleanupModel")

        #if DEBUG
        print("[App] Migration: switched LLM cleanup model \(existingModelID ?? "nil") → \(migratedModelID)")
        #endif
    }

    private func applyDefaultTextCleanupIfNeeded(defaults: UserDefaults = .standard) {
        let existingCleanupEnabled = defaults.object(forKey: "llmCleanupEnabled") as? Bool
        let existingCleanupModelID = defaults.string(forKey: "llmCleanupModel")

        guard let selection = Self.defaultTextCleanupSelection(
            existingCleanupEnabled: existingCleanupEnabled,
            existingCleanupModelID: existingCleanupModelID
        ) else {
            return
        }

        defaults.set(selection.isEnabled, forKey: "llmCleanupEnabled")
        defaults.set(selection.modelID, forKey: "llmCleanupModel")

        #if DEBUG
        print("[App] Default text cleanup enabled — regex filler removal")
        #endif
    }

    private func syncTextCleanupAvailabilityForCurrentPreset() {
        let currentMode = TextCleanupMode.current
        let effectiveMode = Self.effectiveTextCleanupMode(
            requestedMode: currentMode,
            transcriptionPreset: selectedTranscriptionPreset
        )

        guard effectiveMode != currentMode else {
            if viewModel.textCleanupMode != effectiveMode {
                viewModel.textCleanupMode = effectiveMode
            }
            return
        }

        appLog("Text cleanup LLM unavailable for preset=\(selectedTranscriptionPreset.rawValue) — forcing Off")
        applyTextCleanupMode(effectiveMode)
    }

    private func ensureLaunchAtLoginDefaultIfNeeded() {
        guard #available(macOS 13.0, *) else { return }

        let defaults = UserDefaults.standard
        let appliedKey = "launchAtLoginDefaultApplied"
        let userSetKey = "launchAtLoginUserSet"
        guard !defaults.bool(forKey: userSetKey),
              !defaults.bool(forKey: appliedKey) else { return }

        do {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } catch {
            #if DEBUG
            print("[App] Launch at login default failed: \(error)")
            #endif
        }

        defaults.set(true, forKey: appliedKey)
    }

    private func migrateTranscriptionPresetIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: "transcriptionPreset") == nil else { return }

        let preset = TranscriptionPreset.migrateLegacy(
            experimentalMode: defaults.bool(forKey: "experimentalMode"),
            experimentalEngineRaw: defaults.string(forKey: "experimentalEngine"),
            realtimeFinalizationRaw: defaults.string(forKey: "realtimeParakeetFinalizationMode"),
            realtimeCleanupRaw: defaults.string(forKey: "realtimeEouShadowCleanupMode")
        )

        defaults.set(preset.rawValue, forKey: "transcriptionPreset")
        defaults.set(preset.usesRealtimeEngine, forKey: "experimentalMode")
        defaults.set(preset.engineChoice.rawValue, forKey: "experimentalEngine")
        if let finalizationMode = preset.realtimeFinalizationMode {
            defaults.set(finalizationMode.rawValue, forKey: "realtimeParakeetFinalizationMode")
        }
        if let cleanupMode = preset.realtimeShadowCleanupMode {
            defaults.set(cleanupMode.rawValue, forKey: "realtimeEouShadowCleanupMode")
        }
    }

    private func normalizeHiddenTranscriptionPresetIfNeeded() {
        let defaults = UserDefaults.standard
        guard let rawValue = defaults.string(forKey: "transcriptionPreset"),
              let preset = TranscriptionPreset(rawValue: rawValue),
              !preset.isUserFacing else { return }

        defaults.set(TranscriptionPreset.stable.rawValue, forKey: "transcriptionPreset")
        defaults.set(false, forKey: "experimentalMode")
        defaults.set(TranscriptionPreset.stable.engineChoice.rawValue, forKey: "experimentalEngine")
        defaults.removeObject(forKey: "realtimeParakeetFinalizationMode")
        defaults.removeObject(forKey: "realtimeEouShadowCleanupMode")
    }

    private func startServices() {
        // Prompt for Accessibility permission on first launch (needed by KeyboardInjector
        // to type transcribed text in ALL modes, not just manual/PTT)
        if !KeyboardInjector.hasAccessibilityPermission {
            appWarn("Accessibility not granted — prompting user")
            KeyboardInjector.requestAccessibilityPermission()
        } else {
            appLog("Accessibility permission granted")
        }

        // Load Silero VAD for ML-based speech detection
        if ModelManager.isVADModelDownloaded {
            initSileroVAD()
        } else {
            ModelManager.downloadVADModel { [weak self] result in
                if case .success = result {
                    #if DEBUG
                    print("[App] VAD model downloaded")
                    #endif
                    self?.initSileroVAD()
                }
            }
        }

        // Load preferred mic (falls back to system default if unavailable)
        audioCapture.preferredInputDeviceName = UserDefaults.standard.string(forKey: "preferredInputDevice")
        let initialEngine = preferredStartupEngine
        applyEndpointingProfile(for: initialEngine)

        // Start mic based on mode and keepMicReady preference. In manual mode
        // the mic doesn't depend on the ASR engine (it only fills the ring
        // buffer), so start it now and let AVAudioEngine's ~700ms warm-up run
        // in parallel with the multi-second engine load instead of after it.
        // Always-on stays gated on engine readiness: VAD would otherwise emit
        // speech segments with no engine to transcribe them
        // (resumeListeningAfterEngineReadyIfNeeded starts it once ready).
        let mode = ShortcutConfig.shared.recordingMode
        audioCapture.continuousMode = (mode == .alwaysOn)
        if shouldKeepCaptureRunningBetweenManualPresses
            && (mode == .manual || transcriptionService.isReady) {
            audioCapture.start()
        }

        NotificationCenter.default.addObserver(self, selector: #selector(keepMicReadyDidChange), name: .keepMicReadyDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(micIdleSleepPreferenceDidChange), name: .micIdleSleepPreferenceDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(dockIconPreferenceDidChange), name: .dockIconPreferenceDidChange, object: nil)
        // experimentalEngineDidChange observer removed — ExperimentalPrefsViewController was deleted

        registerHotkeys()
        registerGlobalShortcuts()
        transcriptionService.onTimingEvent = { [weak self] event in
            DispatchQueue.main.async {
                self?.handleTranscriptionTimingEvent(event)
            }
        }
        transcriptionService.onKeepWarmTick = { duration in
            DiagnosticsService.shared.recordWarmup(durationMs: duration * 1000)
        }
        switchEngine(to: initialEngine, clearCurrent: false)
        warmUpLLMCleanup()
        registerITNCustomRules()
        startKeepWarmTimer()
        startMicIdleTimer()
        DiagnosticsService.shared.start()

        // Check for remote announcements on launch + every 4 hours
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            AnnouncementService.shared.startPeriodicChecks()
        }
    }

    private func prewarmStableModeEngineIfNeeded() {
        guard shouldPrewarmAlternateEngines else { return }
        guard cachedFluidAudioContext == nil else { return }
        guard AsrModels.modelsExist(
            at: AsrModels.defaultCacheDirectory(for: .v3),
            version: .v3
        ) else { return }

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let context = try await FluidAudioContext.create(version: .v3)
                // Prime CoreML before the context becomes user-visible.
                // Without this, the first real PTT pays the ~3s ANE cold-start
                // tax — the cached path in loadFluidAudioEngine assumes the
                // context is already primed and skips warmup.
                await context.warmup()
                await MainActor.run {
                    self.cachedFluidAudioContext = context
                }
                #if DEBUG
                print("[App] Stable mode engine prewarmed")
                #endif
            } catch {
                #if DEBUG
                print("[App] Stable mode prewarm skipped: \(error.localizedDescription)")
                #endif
            }
        }
    }

    private func prewarmPowerModeEngineIfNeeded() {
        guard shouldPrewarmAlternateEngines else { return }
        guard cachedRealtimeEouPreset != .powerUserFastest else { return }
        guard FluidAudioModelStore.hasRealtimeEou160Models() else { return }

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let context = try await StreamingParakeetContext.create()
                let service = try await RealtimeEouService.create(
                    finalizationMode: .pureSpeed,
                    shadowCleanupMode: .off
                )
                await MainActor.run {
                    self.cachedRealtimeEouPreset = .powerUserFastest
                    self.cachedRealtimeEouContext = context
                    self.cachedRealtimeEouService = service
                    self.cachedRealtimeEouService?.delegate = self
                }
                #if DEBUG
                print("[App] Turbo preset engine prewarmed")
                #endif
            } catch {
                #if DEBUG
                print("[App] Turbo preset prewarm skipped: \(error.localizedDescription)")
                #endif
            }
        }
    }

    /// Start a recurring timer that fires `transcriptionService.keepWarm()` every
    /// `keepWarmInterval` seconds. Pins the active ASR model hot in the ANE so we
    /// never pay the ~3-5s CoreML cold-load tax after idle. Idempotent — calling
    /// twice replaces the existing timer.
    private func startKeepWarmTimer() {
        keepWarmTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.keepWarmInterval, repeats: true) { [weak self] _ in
            self?.transcriptionService.keepWarm()
        }
        timer.tolerance = 5
        keepWarmTimer = timer
        // Fire immediately so we don't wait up to `keepWarmInterval` for the
        // first tick (e.g. right after launch, or right after wake-from-sleep).
        transcriptionService.keepWarm()
        #if DEBUG
        print("[App] Keep-warm timer started (every \(Int(Self.keepWarmInterval))s)")
        #endif
    }

    private func stopKeepWarmTimer() {
        keepWarmTimer?.invalidate()
        keepWarmTimer = nil
    }

    // MARK: - Mic Idle Sleep

    /// Start the poll timer that implements "Sleep When Idle". Cheap: it only
    /// does anything once the user opts in (`micIdleSleepMinutes > 0`). Waking
    /// is free — the existing cold-start paths (manual PTT/toggle) and
    /// re-enabling listening (always-on) restart the mic; a stopped mic simply
    /// resets the accumulator on the next tick.
    private func startMicIdleTimer() {
        micIdleTimer?.invalidate()
        micIdleAccumulatedSeconds = 0
        let timer = Timer.scheduledTimer(withTimeInterval: Self.micIdleCheckInterval, repeats: true) { [weak self] _ in
            self?.tickMicIdleTimer()
        }
        timer.tolerance = 10
        micIdleTimer = timer
    }

    private func stopMicIdleTimer() {
        micIdleTimer?.invalidate()
        micIdleTimer = nil
        micIdleAccumulatedSeconds = 0
    }

    private func tickMicIdleTimer() {
        let minutes = UserDefaults.standard.integer(forKey: "micIdleSleepMinutes")
        guard minutes > 0 else { micIdleAccumulatedSeconds = 0; return }

        // Nothing to sleep if the mic is already off (cold manual mode, muted,
        // or already asleep) — reset so waking starts a fresh idle window.
        guard audioCapture.isRunning else { micIdleAccumulatedSeconds = 0; return }

        // Any in-flight dictation resets the clock. Re-checked here (not just at
        // the sleep decision) so we never accumulate idle time during real use.
        let isActive = isManualRecording
            || isToggleRecording
            || appState.isRecording
            || appState.isTranscribing
            || audioCapture.isSpeechActive
            || !pendingSpeechQueue.isEmpty
            || activeTranscriptionRequest != nil
        if isActive {
            micIdleAccumulatedSeconds = 0
            return
        }

        micIdleAccumulatedSeconds += Self.micIdleCheckInterval
        guard micIdleAccumulatedSeconds >= TimeInterval(minutes) * 60 else { return }
        sleepMicForIdle(afterMinutes: minutes)
    }

    private func sleepMicForIdle(afterMinutes minutes: Int) {
        micIdleAccumulatedSeconds = 0
        guard audioCapture.isRunning else { return }
        appLog("Mic idle for \(minutes)m — sleeping to clear standby")
        audioCapture.stop()
        if ShortcutConfig.shared.recordingMode == .alwaysOn {
            appState.currentState = .idle
        }
        updateStatusMenuItem()
        updateMenuBarIcon()
    }

    /// User changed the "Sleep When Idle" duration — measure the new window from
    /// now, and make sure the poll timer is live.
    @objc private func micIdleSleepPreferenceDidChange() {
        micIdleAccumulatedSeconds = 0
        if micIdleTimer == nil { startMicIdleTimer() }
    }

    private var shouldPrewarmAlternateEngines: Bool {
        #if DEBUG
        return false
        #else
        let os = SystemInfo.operatingSystemVersion
        let chip = SystemInfo.chipDescription.lowercased()
        let isOlderAppleSilicon =
            chip.contains("apple m1") || chip.contains("apple m2") || chip.contains("apple m3")
        return !(os.majorVersion >= 26 && isOlderAppleSilicon)
        #endif
    }

    private func clearTransientOverlayAfterEngineReady() {
        guard shouldShowPresetOverlay else { return }
        overlayPanel.show(status: .idle)
    }

    private func initSileroVAD() {
        // Load the whisper VAD model off the main thread — it blocks for the
        // model read/compile, and launch shouldn't stall on it. Energy-based
        // VAD covers the gap until the detector lands (same as the
        // download-then-init path, which was already async).
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let detector = SileroSpeechDetector(modelPath: ModelManager.vadModelPath)
            DispatchQueue.main.async {
                guard let self else { return }
                if let detector {
                    self.audioCapture.speechDetector = detector
                    #if DEBUG
                    print("[App] Silero VAD active — ML-based speech detection enabled")
                    #endif
                } else {
                    #if DEBUG
                    print("[App] Silero VAD failed to load — falling back to energy-based detection")
                    #endif
                }
            }
        }
    }

    private var preferredStartupEngine: TranscriptionEngineChoice {
        selectedTranscriptionPreset.engineChoice
    }

    private func applyEndpointingProfile(for engine: TranscriptionEngineChoice) {
        let profile = Self.endpointingProfile(
            for: selectedTranscriptionPreset,
            engine: engine
        )
        let useRealtimeParakeetProfile = profile == .realtimeParakeet
        let shouldRouteLiveAudio = useRealtimeParakeetProfile

        audioCapture.endpointingProfile = profile
        transcriptionService.minimumASRSamples = 16_000
        audioCapture.onProcessedAudio = shouldRouteLiveAudio ? { [weak self] samples in
            self?.handleRealtimeAudioBlock(samples)
        } : nil

        if useRealtimeParakeetProfile {
            if engine == .parakeetEou {
                appLog(
                    "Realtime Parakeet EOU endpointing active: 20ms poll, 150ms preroll, " +
                    "adaptive user-tunable silence gate shadow_cleanup=\(realtimeShadowCleanupMode.rawValue)"
                )
            } else {
                appLog("Realtime Parakeet endpointing active: 20ms poll, 150ms preroll, adaptive user-tunable silence gate")
            }
        } else if profile == .stableExtraQuick {
            appLog("Stable endpointing active: 20ms poll, tighter adaptive silence gate, batch Parakeet V3")
        } else {
            appLog("Standard endpointing active for \(engine.displayName)")
        }
    }

    private func beginEngineLoad(for engine: TranscriptionEngineChoice) -> Int {
        engineLoadGeneration += 1
        let generation = engineLoadGeneration
        appLog(
            "Engine load requested generation=\(generation) " +
            "preset=\(selectedTranscriptionPreset.rawValue) engine=\(engine.rawValue)"
        )
        return generation
    }

    private func acceptsEngineLoad(
        generation: Int,
        engine: TranscriptionEngineChoice,
        preset: TranscriptionPreset? = nil
    ) -> Bool {
        guard engineLoadGeneration == generation else { return false }
        guard activeTranscriptionEngine == engine else { return false }
        if let preset {
            guard selectedTranscriptionPreset == preset else { return false }
        }
        return true
    }

    private func logDiscardedEngineLoad(
        generation: Int,
        engine: TranscriptionEngineChoice,
        preset: TranscriptionPreset? = nil,
        reason: String
    ) {
        let presetLabel = preset?.rawValue ?? selectedTranscriptionPreset.rawValue
        appLog(
            "Discarded stale engine load generation=\(generation) " +
            "preset=\(presetLabel) engine=\(engine.rawValue) reason=\(reason)"
        )
    }

    private func deepgramAPIKey() -> String? {
        let apiKey = (UserDefaults.standard.string(forKey: "deepgramApiKey") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return apiKey.isEmpty ? nil : apiKey
    }

    private func engineSelectionFailureMessage(for engine: TranscriptionEngineChoice) -> String? {
        switch engine {
        case .deepgramFlux:
            return deepgramAPIKey() == nil
                ? "Deepgram API key not set — keeping the current engine."
                : nil
        case .deepmind:
            return "DeepMind engine is still a placeholder — keeping the current engine."
        case .parakeetV3, .parakeetEou, .parakeetRealtimeTdt:
            return nil
        }
    }

    private func switchEngine(to engine: TranscriptionEngineChoice, clearCurrent: Bool = true) {
        if let failureMessage = engineSelectionFailureMessage(for: engine) {
            appWarn(failureMessage)
            if !transcriptionService.isReady {
                appState.currentState = .error(failureMessage)
            }
            updateMenuBarIcon(listening: appState.isListening)
            scheduleMenuRebuild()
            return
        }

        if clearCurrent {
            transcriptionService.clearEngine()
            resetRealtimeDeliveryState()
            Task { [weak self] in
                await self?.cancelRealtimeStreamingUtterances()
            }
            if engine != .parakeetRealtimeTdt {
                teardownRealtimeParakeetService()
            }
        }

        activeTranscriptionEngine = engine
        resetEngineDownloadProgress()
        syncEngineLoadingDiagnostics()
        suspendListeningForEngineLoadIfNeeded()
        let loadGeneration = beginEngineLoad(for: engine)
        applyEndpointingProfile(for: engine)

        switch engine {
        case .parakeetV3:
            loadFluidAudioEngine(loadGeneration: loadGeneration)

        case .deepgramFlux:
            guard let apiKey = deepgramAPIKey() else {
                appError("Deepgram API key missing after preflight")
                return
            }
            let context = DeepgramASRContext.create(apiKey: apiKey)
            transcriptionService.setEngine(context)
            isEngineLoading = false
            resumeListeningAfterEngineReadyIfNeeded()
            updateMenuBarIcon(listening: appState.isListening)
            scheduleMenuRebuild()
            clearTransientOverlayAfterEngineReady()
            appLog("Deepgram Flux engine ready")

        case .parakeetEou:
            loadRealtimeEouEngine(loadGeneration: loadGeneration)

        case .parakeetRealtimeTdt:
            loadRealtimeParakeetEngine(loadGeneration: loadGeneration)

        case .deepmind:
            assertionFailure("DeepMind engine should have been rejected during preflight")
        }
    }

    private func handleTranscriptionTimingEvent(_ event: TranscriptionTimingEvent) {
        let request = activeTranscriptionRequest
        switch event.kind {
        case .queued:
            if let endpointAt = request?.speechTiming?.endpointDetectedAt {
                let endpointToDispatch = event.timestamp.timeIntervalSince(endpointAt) * 1000
                appLog("Timing: asr-dispatch source=\(request?.source ?? "unknown") endpoint_to_dispatch_ms=\(Int(endpointToDispatch)) samples=\(event.sampleCount)")
            } else {
                appLog("Timing: asr-dispatch source=\(request?.source ?? "unknown") samples=\(event.sampleCount)")
            }
        case .started:
            if let enqueuedAt = request?.enqueuedAt {
                let queueDelay = event.timestamp.timeIntervalSince(enqueuedAt) * 1000
                appLog("Timing: asr-start source=\(request?.source ?? "unknown") queue_delay_ms=\(Int(queueDelay)) samples=\(event.sampleCount)")
            } else {
                appLog("Timing: asr-start source=\(request?.source ?? "unknown") samples=\(event.sampleCount)")
            }
        case .finished:
            let duration = event.duration ?? 0
            let durationMs = Int(duration * 1000)
            appLog("Timing: asr-finish source=\(request?.source ?? "unknown") asr_ms=\(durationMs) samples=\(event.sampleCount)")
            // Sample rate is fixed at 16kHz for ASR input.
            let audioSeconds = Double(event.sampleCount) / 16_000.0
            DiagnosticsService.shared.recordPTT(audioSeconds: audioSeconds, inferenceMs: duration * 1000)
        case .failed(let reason):
            appLog("Timing: asr-fail source=\(request?.source ?? "unknown") reason=\(reason) samples=\(event.sampleCount)")
        }
    }

    // MARK: - FluidAudio Engine

    private func loadFluidAudioEngine(loadGeneration: Int) {
        if let cachedFluidAudioContext {
            guard acceptsEngineLoad(generation: loadGeneration, engine: .parakeetV3) else {
                logDiscardedEngineLoad(
                    generation: loadGeneration,
                    engine: .parakeetV3,
                    reason: "cached-context-arrived-after-engine-changed"
                )
                return
            }
            transcriptionService.setEngine(cachedFluidAudioContext)
            isEngineLoading = false
            resumeListeningAfterEngineReadyIfNeeded()
            updateMenuBarIcon(listening: appState.isListening)
            scheduleMenuRebuild()
            clearTransientOverlayAfterEngineReady()
            appLog("FluidAudio engine ready (cached Parakeet TDT v3)")
            // No warmup needed — cached context was previously used, CoreML already primed.
            // Running warmup here would race with real PTT via TranscriptionService.
            return
        }

        let modelsOnDisk = AsrModels.modelsExist(
            at: AsrModels.defaultCacheDirectory(for: .v3),
            version: .v3
        )
        isEngineLoading = true
        updateMenuBarIcon()
        scheduleMenuRebuild()

        if modelsOnDisk {
            appLog("Loading FluidAudio engine (models cached)...")
            if shouldShowPresetOverlay { overlayPanel.show(status: currentEngineStartupOverlayStatus) }
        } else {
            appLog("Downloading FluidAudio models...")
            if shouldShowPresetOverlay { overlayPanel.show(status: currentEngineStartupOverlayStatus) }
        }

        Task {
            do {
                let context = try await FluidAudioContext.create(version: .v3)
                // Prime CoreML compute pipeline before declaring ready
                await context.warmup()
                await MainActor.run {
                    self.cachedFluidAudioContext = context
                    guard self.acceptsEngineLoad(generation: loadGeneration, engine: .parakeetV3) else {
                        self.logDiscardedEngineLoad(
                            generation: loadGeneration,
                            engine: .parakeetV3,
                            reason: "async-load-finished-after-engine-changed"
                        )
                        return
                    }
                    self.transcriptionService.setEngine(context)
                    self.isEngineLoading = false
                    self.resumeListeningAfterEngineReadyIfNeeded()
                    self.updateMenuBarIcon(listening: self.appState.isListening)
                    self.scheduleMenuRebuild()
                    self.clearTransientOverlayAfterEngineReady()
                    appLog("FluidAudio engine ready (Parakeet TDT v3)")
                    trackEvent("engineLoaded", parameters: [
                        "engine": self.activeTranscriptionEngine.rawValue,
                    ])
                    self.prewarmPowerModeEngineIfNeeded()
                }
            } catch {
                await MainActor.run {
                    guard self.acceptsEngineLoad(generation: loadGeneration, engine: .parakeetV3) else {
                        self.logDiscardedEngineLoad(
                            generation: loadGeneration,
                            engine: .parakeetV3,
                            reason: "async-load-failed-after-engine-changed"
                        )
                        return
                    }
                    self.isEngineLoading = false
                    self.updateMenuBarIcon(listening: self.appState.isListening)
                    self.scheduleMenuRebuild()
                    appError("FluidAudio failed: \(error.localizedDescription)")
                    trackEvent("errorOccurred", parameters: ["source": "engineLoad", "error": error.localizedDescription])
                    self.appState.currentState = .error("FluidAudio failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func loadRealtimeParakeetEngine(loadGeneration: Int) {
        let modelsOnDisk = AsrModels.modelsExist(
            at: AsrModels.defaultCacheDirectory(for: .v3),
            version: .v3
        )
        isEngineLoading = true
        updateMenuBarIcon()
        scheduleMenuRebuild()

        if modelsOnDisk {
            appLog("Loading realtime Parakeet engine (models cached)...")
            if shouldShowPresetOverlay { overlayPanel.show(status: currentEngineStartupOverlayStatus) }
        } else {
            appLog("Downloading realtime Parakeet models...")
            if shouldShowPresetOverlay { overlayPanel.show(status: currentEngineStartupOverlayStatus) }
        }

        let finalizationMode = realtimeFinalizationMode
        Task {
            do {
                let service = try await RealtimeParakeetService.create(finalizationMode: finalizationMode)
                await MainActor.run {
                    guard self.acceptsEngineLoad(generation: loadGeneration, engine: .parakeetRealtimeTdt) else {
                        self.logDiscardedEngineLoad(
                            generation: loadGeneration,
                            engine: .parakeetRealtimeTdt,
                            reason: "async-load-finished-after-engine-changed"
                        )
                        Task {
                            await service.cancelUtterance()
                            await service.shutdown()
                        }
                        return
                    }
                    self.realtimeParakeetService = service
                    service.delegate = self
                    self.transcriptionService.setEngine(service.batchFallbackContext)
                    self.isEngineLoading = false
                    self.resumeListeningAfterEngineReadyIfNeeded()
                    self.updateMenuBarIcon(listening: self.appState.isListening)
                    self.scheduleMenuRebuild()
                    self.clearTransientOverlayAfterEngineReady()
                    appLog("Realtime Parakeet engine ready finalization=\(finalizationMode.rawValue)")
                    trackEvent("engineLoaded", parameters: [
                        "engine": TranscriptionEngineChoice.parakeetRealtimeTdt.rawValue,
                        "finalization": finalizationMode.rawValue,
                    ])
                }
            } catch {
                await MainActor.run {
                    guard self.acceptsEngineLoad(generation: loadGeneration, engine: .parakeetRealtimeTdt) else {
                        self.logDiscardedEngineLoad(
                            generation: loadGeneration,
                            engine: .parakeetRealtimeTdt,
                            reason: "async-load-failed-after-engine-changed"
                        )
                        return
                    }
                    self.isEngineLoading = false
                    self.updateMenuBarIcon(listening: self.appState.isListening)
                    self.scheduleMenuRebuild()
                    appError("Realtime Parakeet failed: \(error.localizedDescription)")
                    trackEvent("errorOccurred", parameters: [
                        "source": "engineLoad",
                        "engine": TranscriptionEngineChoice.parakeetRealtimeTdt.rawValue,
                        "error": error.localizedDescription,
                    ])
                    self.appState.currentState = .error("Realtime Parakeet failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func teardownRealtimeParakeetService() {
        let service = realtimeParakeetService
        realtimeParakeetService = nil
        resetRealtimeDeliveryState()
        guard let service else { return }
        Task {
            await service.cancelUtterance()
            await service.shutdown()
        }
    }

    private func loadRealtimeEouEngine(loadGeneration: Int) {
        let requestedPreset = selectedTranscriptionPreset
        let finalizationMode = realtimeFinalizationMode
        let shadowCleanupMode = realtimeShadowCleanupMode

        if cachedRealtimeEouPreset == requestedPreset,
           let cachedRealtimeEouContext,
           let cachedRealtimeEouService,
           cachedRealtimeEouService.finalizationMode == finalizationMode,
           cachedRealtimeEouService.shadowCleanupMode == shadowCleanupMode {
            guard acceptsEngineLoad(generation: loadGeneration, engine: .parakeetEou, preset: requestedPreset) else {
                logDiscardedEngineLoad(
                    generation: loadGeneration,
                    engine: .parakeetEou,
                    preset: requestedPreset,
                    reason: "cached-context-arrived-after-engine-changed"
                )
                return
            }
            realtimeEouService = cachedRealtimeEouService
            cachedRealtimeEouService.delegate = self
            if turboModeEnabled {
                cachedRealtimeEouService.setEouDebounceMs(140)
            }
            transcriptionService.setEngine(cachedRealtimeEouContext)
            isEngineLoading = false
            resumeListeningAfterEngineReadyIfNeeded()
            updateMenuBarIcon(listening: appState.isListening)
            scheduleMenuRebuild()
            clearTransientOverlayAfterEngineReady()
            appLog("Parakeet EOU realtime engine ready (cached preset=\(requestedPreset.rawValue))")
            return
        }

        isEngineLoading = true
        updateMenuBarIcon()
        scheduleMenuRebuild()
        if shouldShowPresetOverlay { overlayPanel.show(status: currentEngineStartupOverlayStatus) }

        Task {
            do {
                let context: ASRContext
                switch requestedPreset {
                case .stable, .stableExtraQuick, .realtimeCleanup:
                    context = try await FluidAudioContext.create(version: .v3)
                case .powerUserFastest:
                    context = try await StreamingParakeetContext.create()
                }
                let service = try await RealtimeEouService.create(
                    finalizationMode: finalizationMode,
                    shadowCleanupMode: shadowCleanupMode
                )

                await MainActor.run {
                    guard self.acceptsEngineLoad(generation: loadGeneration, engine: .parakeetEou, preset: requestedPreset) else {
                        self.logDiscardedEngineLoad(
                            generation: loadGeneration,
                            engine: .parakeetEou,
                            preset: requestedPreset,
                            reason: "async-load-finished-after-engine-changed"
                        )
                        Task {
                            await service.cancelUtterance()
                            await service.shutdown()
                        }
                        return
                    }
                    self.cachedRealtimeEouPreset = requestedPreset
                    self.cachedRealtimeEouContext = context
                    self.cachedRealtimeEouService = service
                    self.realtimeEouService = service
                    service.delegate = self
                    if self.turboModeEnabled {
                        service.setEouDebounceMs(140)
                    }
                    self.transcriptionService.setEngine(context)
                    self.isEngineLoading = false
                    self.resumeListeningAfterEngineReadyIfNeeded()
                    self.updateMenuBarIcon(listening: self.appState.isListening)
                    self.scheduleMenuRebuild()
                    self.clearTransientOverlayAfterEngineReady()
                    appLog(
                        "Parakeet EOU realtime engine ready preset=\(requestedPreset.rawValue) " +
                        "finalization=\(finalizationMode.rawValue) shadow_cleanup=\(shadowCleanupMode.rawValue)"
                    )
                    if finalizationMode == .speedPlusCleanup {
                        appLog("Parakeet EOU cleanup model warming in background")
                    }
                    trackEvent("engineLoaded", parameters: [
                        "engine": TranscriptionEngineChoice.parakeetEou.rawValue,
                        "mode": "realtime",
                        "finalization": finalizationMode.rawValue,
                        "shadowCleanup": shadowCleanupMode.rawValue,
                    ])
                    self.prewarmStableModeEngineIfNeeded()
                }
            } catch {
                await MainActor.run {
                    guard self.acceptsEngineLoad(generation: loadGeneration, engine: .parakeetEou, preset: requestedPreset) else {
                        self.logDiscardedEngineLoad(
                            generation: loadGeneration,
                            engine: .parakeetEou,
                            preset: requestedPreset,
                            reason: "async-load-failed-after-engine-changed"
                        )
                        return
                    }
                    self.isEngineLoading = false
                    self.updateMenuBarIcon(listening: self.appState.isListening)
                    self.scheduleMenuRebuild()
                    appError("Parakeet EOU failed: \(error.localizedDescription)")
                    trackEvent("errorOccurred", parameters: [
                        "source": "engineLoad",
                        "engine": TranscriptionEngineChoice.parakeetEou.rawValue,
                        "error": error.localizedDescription,
                    ])
                    self.appState.currentState = .error("Parakeet EOU failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func teardownRealtimeEouService() {
        let service = realtimeEouService
        realtimeEouService = nil
        resetRealtimeDeliveryState()
        guard let service else { return }
        Task {
            await service.cancelUtterance()
            await service.shutdown()
        }
    }

    private func registerHotkeys() {
        let config = ShortcutConfig.shared
        let action = config.actionShortcut
        let mic = config.micToggleShortcut
        let micForCarbon = mic.asGlobalShortcut.canUseCarbonHotKey ? mic : nil
        let llmCleanupShortcut = GlobalShortcut.defaultLLMCleanupToggle
        hotkeyManager.unregister()
        guard !isShortcutCaptureSuspended else { return }
        hotkeyManager.register(
            actionKeyCode: action?.keyCode,
            actionModifiers: action?.nsModifiers ?? [],
            micKeyCode: micForCarbon?.keyCode,
            micModifiers: micForCarbon?.nsModifiers ?? [],
            llmCleanupToggleKeyCode: llmCleanupShortcut.keyCode,
            llmCleanupToggleModifiers: llmCleanupShortcut.nsModifiers
        )
        #if DEBUG
        let micRoute = micForCarbon?.displayString ?? "global monitor"
        print("[App] Hotkeys registered — action: \(action?.displayString ?? "none"), mic: \(micRoute), llmCleanup: \(llmCleanupShortcut.displayString)")
        #endif
    }

    private func registerGlobalShortcuts() {
        let config = ShortcutConfig.shared
        let micShortcut = config.micToggleShortcut.asGlobalShortcut
        globalShortcutMonitor.pttShortcut = config.pttShortcut
        globalShortcutMonitor.toggleShortcut = config.toggleShortcut
        globalShortcutMonitor.micToggleShortcut = micShortcut.canUseCarbonHotKey ? nil : micShortcut
        globalShortcutMonitor.modeToggleShortcut = config.modeToggleShortcut
        guard !isShortcutCaptureSuspended else {
            globalShortcutMonitor.stop()
            return
        }
        // Always run — double-click fn mode toggle needs to work in both modes;
        // PTT/toggle are guarded by recording mode checks in the delegate.
        globalShortcutMonitor.start()
        if globalShortcutMonitor.hasConfiguredKeyBasedShortcuts,
           !globalShortcutMonitor.isKeySuppressionAvailable {
            appWarn("Key-based shortcuts are disabled because macOS event suppression is unavailable. Modifier-only shortcuts still work.")
        }
        #if DEBUG
        let modeToggleLabel = config.modeToggleShortcut?.displayString ?? "double-click fn"
        print("[App] Global shortcuts registered — PTT: \(config.pttShortcut.displayString), Toggle: \(config.toggleShortcut.displayString), Mode: \(modeToggleLabel)")
        #endif
    }

    private func setShortcutCaptureSuspended(_ suspended: Bool) {
        guard isShortcutCaptureSuspended != suspended else { return }
        isShortcutCaptureSuspended = suspended

        if suspended {
            hotkeyManager.unregister()
            globalShortcutMonitor.stop()
            return
        }

        guard viewModel.hasStartedServices else { return }
        registerHotkeys()
        registerGlobalShortcuts()
    }

    /// Switch recording mode live from any UI surface without requiring restart.
    @objc private func keepMicReadyDidChange() {
        let mode = ShortcutConfig.shared.recordingMode
        guard mode == .manual, !isManualRecording else { return }
        applyAudioCaptureMode(for: mode)
    }

    private func applyAudioCaptureMode(for mode: RecordingMode) {
        audioCapture.setContinuousMode(mode == .alwaysOn)

        if mode == .alwaysOn && !transcriptionService.isReady {
            audioCapture.stop()
            return
        }

        if shouldKeepCaptureRunningBetweenManualPresses {
            if !audioCapture.isRunning {
                audioCapture.start()
            }
        } else {
            audioCapture.stop()
        }
    }

    func switchRecordingMode(_ mode: RecordingMode) {
        let currentMode = ShortcutConfig.shared.recordingMode
        guard currentMode != mode else {
            if viewModel.recordingMode != mode {
                viewModel.recordingMode = mode
            }
            return
        }

        // Cancel any in-flight manual recording
        audioCapture.cancelManualRecording()
        audioCapture.cancelToggleRecording()
        cancelToggleTimers()
        resetRealtimeDeliveryState()
        Task { [weak self] in
            await self?.cancelRealtimeStreamingUtterances()
        }
        isManualRecording = false
        isToggleRecording = false
        isMicMuted = false
        clearManualRecordingOrigin()
        if shouldShowPresetOverlay {
            overlayPanel.show(status: .idle)
        }

        let config = ShortcutConfig.shared
        config.recordingMode = mode
        viewModel.recordingMode = mode
        trackEvent("recordingModeChanged", parameters: ["mode": mode.rawValue])
        NotificationCenter.default.post(name: .recordingModeDidChange, object: nil, userInfo: ["mode": mode])

        if mode == .manual {
            appState.currentState = .idle
        } else if transcriptionService.isReady && audioCapture.isRunning {
            appState.currentState = .listening
        } else {
            appState.currentState = .idle
        }

        updateMenuBarIcon(listening: mode == .alwaysOn)
        updateStatusMenuItem()
        scheduleMenuRebuild()

        // Apply capture behavior after publishing the new mode so both UI surfaces
        // reflect the selection immediately even if the hardware transition is slow.
        applyAudioCaptureMode(for: mode)

        registerGlobalShortcuts()

        #if DEBUG
        print("[App] Switched to \(mode.rawValue) mode")
        #endif
    }

    // MARK: - Menu Actions

    @objc private func toggleListening() {
        if appState.isListening {
            audioCapture.stop()
            appState.currentState = .idle
        } else {
            guard transcriptionService.isReady else {
                #if DEBUG
                print("[App] Cannot start — ASR engine still loading")
                #endif
                return
            }
            audioCapture.start()
        }
    }

    private func suspendListeningForEngineLoadIfNeeded() {
        guard ShortcutConfig.shared.recordingMode == .alwaysOn else { return }
        audioCapture.stop()
        appState.currentState = .idle
    }

    private func resumeListeningAfterEngineReadyIfNeeded() {
        let mode = ShortcutConfig.shared.recordingMode
        applyAudioCaptureMode(for: mode)

        if mode == .alwaysOn {
            appState.currentState = audioCapture.isRunning ? .listening : .idle
        } else if !isManualRecording && !isToggleRecording {
            appState.currentState = .idle
        }
    }

    // Preferences and Welcome windows removed — handled by SwiftUI views

    private func redownloadModel() {
        let modelDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FluidAudio")
            .appendingPathComponent("Models")
            .appendingPathComponent("parakeet-tdt-0.6b-v3-coreml")
        try? FileManager.default.removeItem(at: modelDir)
        transcriptionService.clearEngine()
        let loadGeneration = beginEngineLoad(for: .parakeetV3)
        loadFluidAudioEngine(loadGeneration: loadGeneration)
    }

    // experimentalEngineDidChange removed — old ExperimentalPrefsViewController was deleted

    private func switchTranscriptionPreset(to preset: TranscriptionPreset) {
        let preset = preset.canonicalPreset
        guard selectedTranscriptionPreset != preset else {
            if viewModel.transcriptionPreset != preset {
                viewModel.transcriptionPreset = preset
            }
            return
        }
        if let failureMessage = engineSelectionFailureMessage(for: preset.engineChoice) {
            appWarn("Preset switch blocked: \(failureMessage)")
            scheduleMenuRebuild()
            return
        }
        let defaults = UserDefaults.standard
        defaults.set(preset.rawValue, forKey: "transcriptionPreset")
        defaults.set(preset.usesRealtimeEngine, forKey: "experimentalMode")
        defaults.set(preset.engineChoice.rawValue, forKey: "experimentalEngine")
        if let finalizationMode = preset.realtimeFinalizationMode {
            defaults.set(finalizationMode.rawValue, forKey: "realtimeParakeetFinalizationMode")
        }
        if let cleanupMode = preset.realtimeShadowCleanupMode {
            defaults.set(cleanupMode.rawValue, forKey: "realtimeEouShadowCleanupMode")
        }
        viewModel.transcriptionPreset = preset
        syncTextCleanupAvailabilityForCurrentPreset()
        appLog("Transcription preset switched: \(preset.displayName) engine=\(preset.engineChoice.rawValue)")
        NotificationCenter.default.post(name: .transcriptionPresetDidChange, object: nil, userInfo: ["preset": preset])
        scheduleMenuRebuild()
        if !isManualRecording {
            applyAudioCaptureMode(for: ShortcutConfig.shared.recordingMode)
        }
        switchEngine(to: preset.engineChoice)
    }

    @objc private func setAlwaysOnMode() {
        switchRecordingMode(.alwaysOn)
    }

    @objc private func setManualMode() {
        switchRecordingMode(.manual)
    }

    @objc private func setTranscriptionPreset(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let preset = TranscriptionPreset(rawValue: rawValue) else { return }
        switchTranscriptionPreset(to: preset)
    }

    @objc private func copyLogsToClipboard() {
        let path = AppLogger.shared.logFilePath
        if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
            // Take last 100 lines max to keep clipboard manageable
            let lines = contents.components(separatedBy: "\n")
            let tail = lines.suffix(100).joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tail, forType: .string)
            appLog("Logs copied to clipboard (\(lines.count) total lines, last 100 copied)")
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("No log file found at \(path)", forType: .string)
        }
    }

    // MARK: - LLM Cleanup

    private func applyTextCleanupMode(_ mode: TextCleanupMode) {
        let effectiveMode = Self.effectiveTextCleanupMode(
            requestedMode: mode,
            transcriptionPreset: selectedTranscriptionPreset
        )
        if effectiveMode != mode {
            appLog("Text cleanup mode \(mode.rawValue) unavailable for preset=\(selectedTranscriptionPreset.rawValue) — keeping Off")
        }

        switch effectiveMode {
        case .off:
            LLMCleanupService.isEnabled = false
        case .regex:
            LLMCleanupService.modelID = "regex"
            LLMCleanupService.isEnabled = true
        case .llm:
            if LLMCleanupService.useLocalModel {
                var modelID = LLMCleanupService.preferredLocalModelID
                var modelInfo = LLMCleanupService.availableModels.first(where: { $0.id == modelID })
                if modelInfo == nil {
                    appLog("Preferred local model '\(modelID)' not found — falling back to default")
                    modelID = LLMCleanupService.defaultLocalModelID
                    LLMCleanupService.preferredLocalModelID = modelID
                    modelInfo = LLMCleanupService.availableModels.first(where: { $0.id == modelID })
                }
                guard let modelInfo else { return }

                LLMCleanupService.modelID = modelID
                LLMCleanupService.isEnabled = true

                if LLMCleanupService.isModelDownloaded(modelInfo) {
                    LLMCleanupService.shared.loadModel()
                } else if modelInfo.canDownload {
                    downloadAndActivateLocalModel(modelInfo)
                }
            } else {
                var modelID = LLMCleanupService.preferredAPIModelID
                var modelInfo = LLMCleanupService.availableModels.first(where: { $0.id == modelID })
                if modelInfo == nil {
                    appLog("Preferred API model '\(modelID)' not found — falling back to default")
                    modelID = LLMCleanupService.defaultAPIModelID
                    LLMCleanupService.preferredAPIModelID = modelID
                    modelInfo = LLMCleanupService.availableModels.first(where: { $0.id == modelID })
                }
                guard let modelInfo else { return }
                guard canUseLLMCleanupModel(modelInfo, showAlert: false) else {
                    // BYO keys: no key for the chosen cloud provider. Degrade
                    // instead of silently no-opping at cleanup time — local
                    // model if it's on disk, else regex cleanup. The explicit
                    // provider-picker path still alerts; this path also runs
                    // at launch where an alert would be hostile.
                    let localInfo = LLMCleanupService.availableModels.first(
                        where: { $0.id == LLMCleanupService.preferredLocalModelID }
                    )
                    if let localInfo, LLMCleanupService.isModelDownloaded(localInfo) {
                        appLog("No API key for \(modelID) — falling back to local model")
                        LLMCleanupService.useLocalModel = true
                        applyTextCleanupMode(.llm)
                    } else {
                        appLog("No API key for \(modelID) and no local model — falling back to regex cleanup")
                        applyTextCleanupMode(.regex)
                    }
                    return
                }
                LLMCleanupService.preferredAPIModelID = modelID
                LLMCleanupService.modelID = modelID
                LLMCleanupService.isEnabled = true
                LLMCleanupService.shared.loadModel(force: !modelInfo.isAPI)
                viewModel.selectedLLMProviderModelID = modelID
            }
        }
        viewModel.textCleanupMode = effectiveMode
        // Cancel menu tracking so the rebuild isn't deferred while the submenu is still visible
        statusItem?.menu?.cancelTracking()
        rebuildMenu()
    }

    /// Cleanup failures used to be swallowed silently — the user just got raw
    /// text and no way to tell why. Show a non-fatal overlay notice, debounced
    /// so a dead key doesn't nag on every utterance, and delayed past the
    /// result flash so it doesn't fight the transcription HUD.
    private var lastCleanupFallbackWarningAt: Date = .distantPast

    private func handleCleanupFallback(_ reason: LLMCleanupService.CleanupFallbackReason) {
        appLog("Cleanup fallback: \(reason.userMessage)")
        let now = Date()
        guard now.timeIntervalSince(lastCleanupFallbackWarningAt) > 120 else { return }
        lastCleanupFallbackWarningAt = now

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self else { return }
            guard !self.appState.isRecording, !self.isTranscriptionInProgress else { return }
            self.overlayPanel.show(status: .warning(reason.userMessage))
        }
    }

    private func canUseLLMCleanupModel(_ modelInfo: LLMCleanupService.ModelInfo, showAlert: Bool) -> Bool {
        guard modelInfo.isAPI, !LLMCleanupService.hasAPIKey(for: modelInfo.apiProvider) else {
            return true
        }

        if showAlert {
            let alert = NSAlert()
            alert.messageText = "\(modelInfo.label.replacingOccurrences(of: "☁ ", with: "")) needs an API key"
            alert.informativeText = "Enter your own API key in the AI Cleanup section of the main window to use this cloud provider. The local model and Filler Removal work without a key."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        return false
    }

    private func setPreferredLLMProviderModel(_ modelID: String) {
        guard let modelInfo = LLMCleanupService.availableModels.first(where: { $0.id == modelID && $0.isAPI }) else { return }

        if viewModel.textCleanupMode == .llm && !canUseLLMCleanupModel(modelInfo, showAlert: true) {
            return
        }

        LLMCleanupService.preferredAPIModelID = modelID
        viewModel.selectedLLMProviderModelID = modelID

        if viewModel.textCleanupMode == .llm {
            applyTextCleanupMode(.llm)
        } else {
            rebuildMenu()
        }
    }

    private func setUseLocalLLM(_ useLocal: Bool, localModelID: String? = nil) {
        if let localModelID {
            LLMCleanupService.preferredLocalModelID = localModelID
        }
        LLMCleanupService.useLocalModel = useLocal
        viewModel.useLocalLLM = useLocal

        if useLocal {
            let modelID = LLMCleanupService.preferredLocalModelID
            if let modelInfo = LLMCleanupService.availableModels.first(where: { $0.id == modelID }) {
                viewModel.isLocalModelDownloaded = LLMCleanupService.isModelDownloaded(modelInfo)
            }
        }

        if viewModel.textCleanupMode == .llm {
            applyTextCleanupMode(.llm)
        }
    }

    private func downloadAndActivateLocalModel(_ modelInfo: LLMCleanupService.ModelInfo) {
        viewModel.localModelDownloadProgress = 0
        LLMCleanupService.shared.downloadModel(modelInfo, progress: { [weak self] pct in
            DispatchQueue.main.async {
                self?.viewModel.localModelDownloadProgress = pct
            }
        }, completion: { [weak self] result in
            DispatchQueue.main.async {
                self?.viewModel.localModelDownloadProgress = nil
                switch result {
                case .success:
                    self?.viewModel.isLocalModelDownloaded = true
                    LLMCleanupService.modelID = modelInfo.id
                    LLMCleanupService.isEnabled = true
                    LLMCleanupService.shared.loadModel()
                    self?.rebuildMenu()
                case .failure(let error):
                    print("[LLMCleanup] Local model download failed: \(error.localizedDescription)")
                }
            }
        })
    }

    @objc private func setLLMCleanupModel(_ sender: NSMenuItem) {
        guard let modelID = sender.representedObject as? String else { return }
        if modelID == "off" {
            applyTextCleanupMode(.off)
        } else if modelID == "regex" {
            applyTextCleanupMode(.regex)
        } else {
            // Check if model is downloaded
            guard let modelInfo = LLMCleanupService.availableModels.first(where: { $0.id == modelID }) else { return }

            if LLMCleanupService.isModelDownloaded(modelInfo) {
                if modelInfo.isAPI {
                    LLMCleanupService.preferredAPIModelID = modelID
                    viewModel.selectedLLMProviderModelID = modelID
                } else {
                    LLMCleanupService.modelID = modelID
                }
                applyTextCleanupMode(.llm)
            } else if !modelInfo.canDownload {
                let alert = NSAlert()
                alert.messageText = "\(modelInfo.label) is a local candidate model"
                alert.informativeText = "Place the GGUF at:\n\(LLMCleanupService.modelPath(for: modelInfo))"
                alert.addButton(withTitle: "OK")
                alert.runModal()
            } else {
                // Download the model first
                let alert = NSAlert()
                alert.messageText = "Download \(modelInfo.label)?"
                let sizeMB = modelInfo.sizeBytes / 1_000_000
                alert.informativeText = "This will download ~\(sizeMB) MB. The model runs locally on your Mac for text cleanup."
                alert.addButton(withTitle: "Download")
                alert.addButton(withTitle: "Cancel")

                if alert.runModal() == .alertFirstButtonReturn {
                    print("[LLMCleanup] Downloading \(modelInfo.label)...")
                    LLMCleanupService.shared.downloadModel(modelInfo, progress: { pct in
                        print("[LLMCleanup] Download progress: \(Int(pct * 100))%")
                    }, completion: { [weak self] result in
                        switch result {
                        case .success:
                            print("[LLMCleanup] Download complete")
                            if modelInfo.isAPI {
                                LLMCleanupService.preferredAPIModelID = modelID
                                self?.viewModel.selectedLLMProviderModelID = modelID
                            }
                            LLMCleanupService.modelID = modelID
                            self?.applyTextCleanupMode(.llm)
                        case .failure(let error):
                            print("[LLMCleanup] Download failed: \(error.localizedDescription)")
                        }
                    })
                }
            }
        }
    }

    @objc private func setLLMPromptPreset(_ sender: NSMenuItem) {
        guard let presetID = sender.representedObject as? String else { return }
        LLMCleanupService.promptPresetID = presetID
        if presetID == "cleanup" {
            LLMCleanupService.customPromptInstruction = ""
            viewModel.customPromptInstruction = ""
            viewModel.isCustomPromptEnabled = false
        }
        rebuildMenu()
    }

    @objc private func setCustomLLMPrompt() {
        let alert = NSAlert()
        alert.messageText = "Custom Voice"
        alert.informativeText = "Describe how cleanup should shape the transcript.\n\nExample: \"Use a formal, concise tone.\""
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 110))

        let field = NSTextField(frame: NSRect(x: 0, y: 30, width: 380, height: 80))
        field.placeholderString = "e.g. Use a professional LinkedIn tone."
        field.stringValue = LLMCleanupService.customPromptInstruction
        field.usesSingleLineMode = false
        field.lineBreakMode = .byWordWrapping
        container.addSubview(field)

        let appendCheck = NSButton(checkboxWithTitle: "Add to default prompt (keep cleanup examples)", target: nil, action: nil)
        appendCheck.frame = NSRect(x: 0, y: 0, width: 380, height: 22)
        appendCheck.state = LLMCleanupService.customPromptAppendsToV20 ? .on : .off
        container.addSubview(appendCheck)

        alert.accessoryView = container

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            LLMCleanupService.customPromptInstruction = text
            LLMCleanupService.customPromptAppendsToV20 = appendCheck.state == .on
            LLMCleanupService.promptPresetID = text.isEmpty ? "cleanup" : "custom"
            viewModel.customPromptInstruction = text
            viewModel.isCustomPromptEnabled = !text.isEmpty
            rebuildMenu()
        }
    }

    private func warmUpLLMCleanup() {
        guard LLMCleanupService.isEnabled else { return }
        guard LLMCleanupService.modelID != "regex" else { return }
        LLMCleanupService.shared.loadModel()
    }

    // MARK: - ITN (Inverse Text Normalization)

    static var isITNEnabled: Bool {
        UserDefaults.standard.bool(forKey: "itnEnabled")
    }

    @objc private func toggleITN() {
        let newValue = !Self.isITNEnabled
        UserDefaults.standard.set(newValue, forKey: "itnEnabled")
        if newValue, let version = TextNormalizer.shared.version {
            print("[ITN] Enabled (text-processing-rs v\(version))")
        } else {
            print("[ITN] Disabled")
        }
        rebuildMenu()
    }

    /// Apply ITN to finalized text if enabled. Synchronous, <1ms.
    /// Includes post-ITN fixups for cases where the normalizer over-converts
    /// (e.g., "one more time" → "1 more time").
    private func applyITNIfEnabled(_ text: String) -> String {
        guard Self.isITNEnabled else { return text }
        var result = TextNormalizer.shared.normalizeSentence(text)
        result = Self.fixITNOverConversions(result)
        return result
    }

    /// Fix cases where ITN converts "one" to "1" in non-numeric contexts.
    /// "1 more time" → "one more time", "1 of the" → "one of the", etc.
    private static func fixITNOverConversions(_ text: String) -> String {
        // Patterns where "1" should revert to "one" — determiner/pronoun usage
        let patterns: [(pattern: String, replacement: String)] = [
            ("\\b1 more\\b", "one more"),
            ("\\b1 of\\b", "one of"),
            ("\\b1 thing\\b", "one thing"),
            ("\\b1 way\\b", "one way"),
            ("\\b1 last\\b", "one last"),
            ("\\b1 final\\b", "one final"),
            ("\\b1 quick\\b", "one quick"),
            ("\\b1 small\\b", "one small"),
            ("\\b1 big\\b", "one big"),
            ("\\bno 1\\b", "no one"),
            ("\\bany1\\b", "anyone"),
            ("\\bevery1\\b", "everyone"),
            ("\\bsome1\\b", "someone"),
        ]
        var result = text
        for (pattern, replacement) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: replacement
                )
            }
        }
        return result
    }

    // MARK: - Custom Dictionary

    @objc private func editCustomDictionary() {
        showMainWindow()
        NotificationCenter.default.post(name: .showCustomDictionaryTab, object: nil)
    }

    private func registerITNCustomRules() {
        let normalizer = TextNormalizer.shared
        guard normalizer.isNativeAvailable else { return }
        normalizer.clearRules()

        // Core dev terms — exact spoken-form matches, zero false positive risk
        normalizer.addRule(spoken: "clawed code", written: "Claude Code")
        normalizer.addRule(spoken: "clawed", written: "Claude")
        normalizer.addRule(spoken: "for sale", written: "Vercel")
        normalizer.addRule(spoken: "for sell", written: "Vercel")
        normalizer.addRule(spoken: "zoo stand", written: "Zustand")
        normalizer.addRule(spoken: "super base", written: "Supabase")
        normalizer.addRule(spoken: "supa base", written: "Supabase")

        // Also register user custom terms as ITN rules
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let customFile = appSupport.appendingPathComponent("BlazingFastTranscription/custom-vocabulary.txt")
        if let content = try? String(contentsOf: customFile, encoding: .utf8) {
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let colonIdx = trimmed.firstIndex(of: ":") else { continue }
                let canonical = String(trimmed[trimmed.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let aliasStr = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                for alias in aliasStr.components(separatedBy: ",") {
                    let a = alias.trimmingCharacters(in: .whitespaces)
                    guard !a.isEmpty else { continue }
                    normalizer.addRule(spoken: a, written: canonical)
                }
            }
        }

        print("[ITN] Registered \(normalizer.ruleCount) custom rules")
    }

    private func refreshCustomVocabularyIntegrations() {
        reloadUserCustomTerms()
        registerITNCustomRules()
        scheduleMenuRebuild()
    }

    // MARK: - Realtime LLM Cleanup Mode

    @objc private func setRealtimeLLMCleanupMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = RealtimeLLMCleanupMode(rawValue: rawValue) else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: "realtimeLLMCleanupMode")
        realtimeLLMShadowRunner = nil
        realtimeSentenceChunker = nil
        appLog("Realtime LLM cleanup mode: \(mode.displayName)")
        scheduleMenuRebuild()
    }

    private func setupRealtimeLLMRunners() {
        // Don't nil out — just reset state. The old runner may have an async
        // finalCleanup in flight that would crash if we deallocate it.
        realtimeLLMShadowRunner?.reset()
        realtimeSentenceChunker?.reset()

        let mode = realtimeLLMCleanupMode
        guard LLMCleanupService.isEnabled, LLMCleanupService.modelID != "regex" else {
            if mode != .off && mode != .regexOnly {
                print("[RealtimeLLM] Mode \(mode.rawValue) requires LLM model — falling back to off")
            }
            return
        }
        print("[RealtimeLLM] Setting up mode: \(mode.displayName)")

        switch mode {
        case .shadowLLM:
            // Reuse existing runner if available (avoids killing in-flight async work)
            if realtimeLLMShadowRunner != nil { return }
            let runner = RealtimeLLMShadowRunner()
            runner.onCleanedText = { [weak self] cleanedPrefix, rawPrefix in
                guard let self else { return }
                let currentDisplayed = self.realtimeDisplayedText

                // Mid-stream safety: only accept corrections that preserve the exact
                // words. The LLM may only change capitalization, punctuation, spacing,
                // and contractions (dont→don't). Any word changes (models→model) are
                // rejected because the trailing raw suffix depends on the original words.
                let rawWords = rawPrefix.lowercased()
                    .split(separator: " ")
                    .map { $0.trimmingCharacters(in: .punctuationCharacters) }
                // Strip trailing sentence punctuation the LLM adds
                var cleanedStripped = cleanedPrefix
                while cleanedStripped.hasSuffix(".") || cleanedStripped.hasSuffix("?") || cleanedStripped.hasSuffix("!") {
                    cleanedStripped = String(cleanedStripped.dropLast())
                }
                cleanedStripped = cleanedStripped.trimmingCharacters(in: .whitespaces)
                let cleanedWords = cleanedStripped.lowercased()
                    .split(separator: " ")
                    .map { $0.trimmingCharacters(in: .punctuationCharacters) }

                guard rawWords == cleanedWords else {
                    print("[LLMShadow] Skipped mid-stream: words changed (\(rawWords) → \(cleanedWords))")
                    return
                }

                // Words match — safe to merge. Apply the cleaned prefix (with better
                // capitalization/punctuation) + raw trailing words.
                let mergedText: String
                if currentDisplayed.hasPrefix(rawPrefix) {
                    let trailingSuffix = String(currentDisplayed.dropFirst(rawPrefix.count))
                    mergedText = cleanedStripped + trailingSuffix
                } else if currentDisplayed.lowercased().hasPrefix(rawPrefix.lowercased()) {
                    let trailingSuffix = String(currentDisplayed.dropFirst(rawPrefix.count))
                    mergedText = cleanedStripped + trailingSuffix
                } else {
                    print("[LLMShadow] Skipped: displayed text diverged from prefix")
                    return
                }

                guard mergedText != currentDisplayed else { return }
                print("[LLMShadow] Applying: \"\(mergedText.prefix(60))\"")
                if let session = self.realtimeProvisionalSession {
                    _ = self.keyboardInjector.updateProvisionalText(mergedText, session: session)
                    self.realtimeDisplayedText = mergedText
                } else if self.realtimeTargetIsTerminal {
                    _ = self.keyboardInjector.applyStreamingDelta(from: currentDisplayed, to: mergedText)
                    self.realtimeDisplayedText = mergedText
                    self.realtimeTerminalTypedText = mergedText
                }
            }
            realtimeLLMShadowRunner = runner

        case .sentenceLLM:
            if realtimeSentenceChunker != nil { return }
            let chunker = RealtimeSentenceChunker()
            chunker.onSentenceCleaned = { [weak self] cleanedText, rawText in
                guard let self else { return }
                let inWords = rawText.split(separator: " ").count
                let outWords = cleanedText.split(separator: " ").count
                guard outWords <= inWords + 2 else {
                    print("[SentenceChunker] Rejected: output too long (\(outWords) vs \(inWords) words)")
                    return
                }
                // Sentence chunker already merges cleaned prefix + raw suffix internally
                print("[SentenceChunker] Applying: \"\(cleanedText.prefix(50))...\"")
                if let session = self.realtimeProvisionalSession {
                    _ = self.keyboardInjector.updateProvisionalText(cleanedText, session: session)
                    self.realtimeDisplayedText = cleanedText
                } else if self.realtimeTargetIsTerminal {
                    _ = self.keyboardInjector.applyStreamingDelta(from: rawText, to: cleanedText)
                    self.realtimeDisplayedText = cleanedText
                    self.realtimeTerminalTypedText = cleanedText
                }
            }
            realtimeSentenceChunker = chunker

        case .off, .regexOnly, .deferredLLM:
            break
        }
    }

    // MARK: - Dev Low-Latency Tuning & Terminal Cleanup Toggles

    @objc private func toggleTurboMode() {
        setLowLatencyTuningEnabled(!turboModeEnabled)
    }

    #if DEBUG
    @objc private func toggleForceNextManualTranscriptionFailure() {
        let nextValue = !isForcedManualTranscriptionFailureArmed
        UserDefaults.standard.set(nextValue, forKey: forcedManualTranscriptionFailureDefaultsKey)
        appLog("Debug manual transcription failure \(nextValue ? "armed" : "disarmed")")
        if shouldShowPresetOverlay {
            overlayPanel.show(status: .error(nextValue ? "Next manual transcription will fail" : "Forced failure disabled"))
        }
        scheduleMenuRebuild()
    }

    @objc private func toggleDebugShortToggleTimers() {
        let nextValue = !isDebugShortToggleTimersEnabled
        UserDefaults.standard.set(nextValue, forKey: debugShortToggleTimersKey)
        appLog("Debug short toggle timers \(nextValue ? "enabled (15s/30s)" : "disabled (9m/10m)")")
        if shouldShowPresetOverlay {
            overlayPanel.show(status: .error(nextValue ? "Toggle timers: 15s warn / 30s limit" : "Toggle timers: normal (9m/10m)"))
        }
        scheduleMenuRebuild()
    }
    #endif

    private func setLowLatencyTuningEnabled(_ isEnabled: Bool) {
        guard turboModeEnabled != isEnabled else { return }
        UserDefaults.standard.set(isEnabled, forKey: "turboMode")
        audioCapture.turboSilenceGate = isEnabled
        realtimeEouService?.setEouDebounceMs(isEnabled ? 140 : 240)
        viewModel.isTurboModeEnabled = isEnabled
        appLog("Low-latency tuning \(isEnabled ? "enabled" : "disabled") (preroll=\(isEnabled ? 300 : 150)ms, silence=\(isEnabled ? "55-120" : "80-180")ms, debounce=\(isEnabled ? 140 : 240)ms)")
        scheduleMenuRebuild()
    }

    @objc private func setTerminalCleanupMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let newMode = TerminalInlineCleanupMode(rawValue: rawValue) else { return }

        let oldFinalization = realtimeFinalizationMode
        let oldShadow = realtimeShadowCleanupMode

        UserDefaults.standard.set(newMode.rawValue, forKey: "terminalInlineCleanupMode")
        appLog("Dev terminal cleanup mode: \(newMode.rawValue)")

        // Check if engine needs recreation due to mode changes
        let newFinalization = realtimeFinalizationMode
        let newShadow = realtimeShadowCleanupMode
        if oldFinalization != newFinalization || oldShadow != newShadow {
            // Invalidate cached EOU service so it gets recreated with new modes
            cachedRealtimeEouPreset = nil
            cachedRealtimeEouService = nil
            cachedRealtimeEouContext = nil

            // Don't recreate engine mid-session — it kills active streaming.
            // If no session is active, recreate now. Otherwise the invalidated cache
            // ensures the next session start creates a properly configured engine.
            if realtimeSessionID == nil, !realtimeStreamingArmed {
                appLog("Dev terminal cleanup: engine mode changed finalization=\(newFinalization.rawValue) shadow=\(newShadow.rawValue) — recreating engine")
                switchEngine(to: activeTranscriptionEngine)
            } else {
                pendingEngineRecreation = true
                appLog("Dev terminal cleanup: engine mode changed finalization=\(newFinalization.rawValue) shadow=\(newShadow.rawValue) — deferred (session active)")
            }
        }

        scheduleMenuRebuild()
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showTestingAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func resetVoiceModelsForOnboardingTesting() {
        let fileManager = FileManager.default
        let candidateURLs: [URL] = [
            AsrModels.defaultCacheDirectory(for: .v3),
            FluidAudioModelStore.realtimeEou160ModelDirectory,
            URL(fileURLWithPath: ModelManager.vadModelPath),
        ]

        for url in candidateURLs where fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }

        cachedFluidAudioContext = nil
        cachedRealtimeEouPreset = nil
        cachedRealtimeEouContext = nil
        cachedRealtimeEouService = nil
        teardownRealtimeEouService()
        teardownRealtimeParakeetService()
        transcriptionService.clearEngine()
        resetEngineDownloadProgress()
        viewModel.isEngineLoading = true

        showTestingAlert(
            title: "Voice Models Removed",
            message: "The ASR and VAD caches were cleared. Models will re-download when you next go through onboarding or restart the app."
        )
    }

    private func resetSystemPermissionForTesting(service: String, settingsURL: URL?) {
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else {
            showTestingAlert(
                title: "Permission Reset Unavailable",
                message: "This build does not expose a bundle identifier at runtime, so macOS can't target it with tccutil."
            )
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", service, bundleID]

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            showTestingAlert(
                title: "Permission Reset Failed",
                message: error.localizedDescription
            )
            return
        }

        guard task.terminationStatus == 0 else {
            showTestingAlert(
                title: "Permission Reset Failed",
                message: "tccutil exited with status \(task.terminationStatus)."
            )
            return
        }

        viewModel.refreshPermissionState()
        if let settingsURL {
            NSWorkspace.shared.open(settingsURL)
        }

        showTestingAlert(
            title: "\(service) Reset",
            message: "macOS cleared \(service.lowercased()) access for \(bundleID). If the old grant still appears briefly, relaunch the app and re-open onboarding."
        )
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // Retain a replacement when SwiftUI has released its original window.
    private var restoredMainWindow: NSWindow?
    private var practicePreviousPreferences: (RecordingMode, TranscriptionPreset)?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    @objc func showMainWindow() {
        syncActivationPolicyToWindowVisibility()
        let existing = NSApp.windows.first {
            $0.identifier?.rawValue == "main" || $0.title == "Blazing Transcribe"
        }
        let window: NSWindow
        if let existing {
            window = existing
        } else {
            let content = MainWindowView().environment(viewModel)
            window = NSWindow(contentViewController: NSHostingController(rootView: content))
            window.identifier = NSUserInterfaceItemIdentifier("main")
            window.title = "Blazing Transcribe"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.setContentSize(NSSize(width: 880, height: 620))
            window.center()
            window.isReleasedWhenClosed = false
            restoredMainWindow = window
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var windowVisibilityObservers: [NSObjectProtocol] = []

    private func setupWindowVisibilityObservers() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didBecomeMainNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification,
        ]

        windowVisibilityObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.syncActivationPolicyToWindowVisibility()
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.syncActivationPolicyToWindowVisibility()
        }
    }

    /// User preference: show the Dock icon (default), or run menu-bar-only.
    /// When off, the app stays a background/accessory app and the window is
    /// opened from the menu bar ("Show Window").
    private var userWantsDockIcon: Bool {
        UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true
    }

    private func syncActivationPolicyToWindowVisibility() {
        let targetPolicy: NSApplication.ActivationPolicy = userWantsDockIcon ? .regular : .accessory

        guard NSApp.activationPolicy() != targetPolicy else { return }
        NSApp.setActivationPolicy(targetPolicy)
    }

    @objc private func dockIconPreferenceDidChange() {
        syncActivationPolicyToWindowVisibility()
    }

    // MARK: - Helpers

    private func updateMenuBarIcon(listening: Bool = false, recording: Bool = false) {
        guard let statusItem else { return }
        let image = BlazingMark.menuBarImage()
        image.isTemplate = true
        statusItem.button?.image = image
        let captureDescription = isEngineLoading ? "Preparing dictation" : (audioCapture.isRunning ? "Microphone active" : "Microphone off")
        statusItem.button?.toolTip = "Blazing · \(recording ? "Recording" : captureDescription)"
        // Red tint only for active recording — matches macOS screen recording convention
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
    }

    private enum RealtimeDiagnosticsLevel {
        case info
        case warning
        case error
    }

    private var realtimeDiagnosticsEnabled: Bool {
        if UserDefaults.standard.object(forKey: "realtimeDiagnosticsEnabled") != nil {
            return UserDefaults.standard.bool(forKey: "realtimeDiagnosticsEnabled")
        }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private func logRealtimeDiagnostics(_ message: String, level: RealtimeDiagnosticsLevel = .info) {
        let prefixed = "RTDiag: \(message)"
        switch level {
        case .info:
            appLog(prefixed)
        case .warning:
            appWarn(prefixed)
        case .error:
            appError(prefixed)
        }

        guard realtimeDiagnosticsEnabled else { return }
        print("[RTDiag] \(message)")
    }

    private func logRealtimeDiagnosticsOnce(_ key: String, _ message: String, level: RealtimeDiagnosticsLevel = .warning) {
        guard !realtimeDiagnosticsEmittedWarnings.contains(key) else { return }
        realtimeDiagnosticsEmittedWarnings.insert(key)
        logRealtimeDiagnostics(message, level: level)
    }

    private func resetRealtimeDiagnosticsState() {
        realtimeDiagnosticsSessionStartedAt = nil
        realtimeDiagnosticsLastPartialAt = nil
        realtimeDiagnosticsLastSummaryAt = nil
        realtimeDiagnosticsLivePartialCount = 0
        realtimeDiagnosticsShadowPartialCount = 0
        realtimeDiagnosticsShadowPromotionCount = 0
        realtimeDiagnosticsLargeRollbackCount = 0
        realtimeDiagnosticsFreezeAppliedCount = 0
        realtimeDiagnosticsEmittedWarnings.removeAll(keepingCapacity: false)
    }

    private func normalizedRealtimeOverlayPartialText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func logRealtimeOverlayPartialSuppressed(
        sessionID: Int,
        source: RealtimePartialSource,
        confirmed: Bool,
        text: String,
        reason: String
    ) {
        let normalizedText = normalizedRealtimeOverlayPartialText(text)
        let skipState = RealtimeOverlayPartialSkipState(
            sessionID: sessionID,
            normalizedText: normalizedText,
            confirmed: confirmed,
            reason: reason
        )
        guard realtimeLastOverlayPartialSkipState != skipState else { return }
        realtimeLastOverlayPartialSkipState = skipState
        appLog(
            "Timing: overlay-partial-\(reason) session=\(sessionID) source=\(source.rawValue) " +
            "chars=\(normalizedText.count) confirmed=\(confirmed)"
        )
    }

    private func showRealtimeOverlayPartial(
        text: String,
        confirmed: Bool,
        source: RealtimePartialSource,
        sessionID: Int
    ) {
        guard Self.shouldAllowRealtimeOverlayPartialDisplay(
            recordingMode: ShortcutConfig.shared.recordingMode,
            isManualRecording: isManualRecording,
            isToggleRecording: isToggleRecording
        ) else {
            logRealtimeOverlayPartialSuppressed(
                sessionID: sessionID,
                source: source,
                confirmed: confirmed,
                text: text,
                reason: "skipped-manual-finished"
            )
            return
        }

        let normalizedText = normalizedRealtimeOverlayPartialText(text)
        guard !normalizedText.isEmpty else {
            logRealtimeOverlayPartialSuppressed(
                sessionID: sessionID,
                source: source,
                confirmed: confirmed,
                text: text,
                reason: "skipped-empty"
            )
            return
        }

        if let lastShown = realtimeLastShownOverlayPartial,
           lastShown.sessionID == sessionID,
           lastShown.normalizedText == normalizedText,
           lastShown.confirmed == confirmed {
            let reason = lastShown.rawText == text && lastShown.source == source.rawValue
                ? "skipped-duplicate"
                : "coalesced"
            logRealtimeOverlayPartialSuppressed(
                sessionID: sessionID,
                source: source,
                confirmed: confirmed,
                text: text,
                reason: reason
            )
            return
        }

        if !confirmed && !shouldRenderLiveOverlayPartial(text) {
            logRealtimeOverlayPartialSuppressed(
                sessionID: sessionID,
                source: source,
                confirmed: confirmed,
                text: text,
                reason: "skipped-stable"
            )
            return
        }

        overlayPanel.show(status: .partial(text, confirmed: confirmed))
        realtimeLastShownOverlayPartial = RealtimeOverlayPartialState(
            sessionID: sessionID,
            rawText: text,
            normalizedText: normalizedText,
            confirmed: confirmed,
            source: source.rawValue
        )
        realtimeLastOverlayPartialSkipState = nil
    }

    private func mergeOverlayOnlyFinalText(existing: String, incoming: String) -> String {
        let trimmedIncoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIncoming.isEmpty else { return existing }
        guard !existing.isEmpty else { return trimmedIncoming }
        guard existing != trimmedIncoming else { return existing }
        guard !existing.hasSuffix(trimmedIncoming) else { return existing }

        let needsSpace =
            !(existing.last.map { CharacterSet.whitespacesAndNewlines.contains($0.unicodeScalars.first!) } ?? false) &&
            !(trimmedIncoming.first.map { ",.!?:;)]}".contains($0) } ?? false)

        return needsSpace ? "\(existing) \(trimmedIncoming)" : existing + trimmedIncoming
    }

    private func scheduleOverlayOnlyFinalCommit(_ text: String) {
        realtimeOverlayOnlyBufferedFinalText = mergeOverlayOnlyFinalText(
            existing: realtimeOverlayOnlyBufferedFinalText,
            incoming: text
        )
        guard !realtimeOverlayOnlyBufferedFinalText.isEmpty else { return }

        realtimeOverlayOnlyCommitWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.realtimeUsesOverlayOnlyMode else { return }
            guard self.realtimeSessionID == nil, !self.realtimeStartInFlight else {
                appLog("Timing: overlay-only-commit-deferred reason=session-active")
                return
            }

            let finalText = self.realtimeOverlayOnlyBufferedFinalText
            self.realtimeOverlayOnlyBufferedFinalText = ""
            guard !finalText.isEmpty else { return }

            let delivered = self.deliverText(finalText)
            if delivered {
                appLog("Timing: overlay-only-commit chars=\(finalText.count)")
            }
        }

        realtimeOverlayOnlyCommitWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + realtimeOverlayOnlyCommitDelay, execute: workItem)
    }

    private func cancelOverlayOnlyPendingCommit() {
        realtimeOverlayOnlyCommitWorkItem?.cancel()
        realtimeOverlayOnlyCommitWorkItem = nil
    }

    private func stabilizedFieldPartialText(_ candidate: String, source: RealtimePartialSource, sessionID: Int) -> String {
        let baseline = realtimeProvisionalSession?.currentText ?? realtimeDisplayedText
        guard !baseline.isEmpty else { return candidate }

        let stabilizer = RealtimeFreezeWindowStabilizer(freezeTailWords: realtimeFreezeTailWords)
        let stabilized = stabilizer.stabilize(baseline: baseline, candidate: candidate)
        if stabilized != candidate {
            realtimeDiagnosticsFreezeAppliedCount += 1
            logRealtimeDiagnosticsOnce(
                "freeze-window-applied-\(sessionID)",
                "freeze-window-active session=\(sessionID) source=\(source.rawValue) tail_words=\(realtimeFreezeTailWords)",
                level: .info
            )
        }
        return stabilized
    }

    private func trackRealtimeRollbackIfNeeded(newText: String, source: RealtimePartialSource, sessionID: Int) {
        let baseline = realtimeProvisionalSession?.currentText ?? realtimeDisplayedText
        guard !baseline.isEmpty else { return }

        let rollbackChars = baseline.count - newText.count
        guard rollbackChars >= 12 else { return }

        realtimeDiagnosticsLargeRollbackCount += 1
        logRealtimeDiagnostics(
            "rollback session=\(sessionID) source=\(source.rawValue) chars=\(rollbackChars) baseline=\(baseline.count) new=\(newText.count)",
            level: .warning
        )
    }

    private func maybeLogRealtimePartialSummary(_ update: RealtimePartialUpdate) {
        let now = Date()
        if let lastSummary = realtimeDiagnosticsLastSummaryAt,
           now.timeIntervalSince(lastSummary) < 1.2 {
            return
        }
        realtimeDiagnosticsLastSummaryAt = now

        let sessionMs: Int
        if let startedAt = realtimeDiagnosticsSessionStartedAt {
            sessionMs = Int(now.timeIntervalSince(startedAt) * 1000)
        } else {
            sessionMs = -1
        }

        logRealtimeDiagnostics(
            "partial-summary session=\(update.sessionID) source=\(update.source.rawValue) chars=\(update.text.count) " +
            "live=\(realtimeDiagnosticsLivePartialCount) shadow=\(realtimeDiagnosticsShadowPartialCount) " +
            "promoted=\(realtimeDiagnosticsShadowPromotionCount) freeze=\(realtimeDiagnosticsFreezeAppliedCount) " +
            "large_rollbacks=\(realtimeDiagnosticsLargeRollbackCount) " +
            "session_ms=\(sessionMs)"
        )
    }

    private func logRealtimeSessionSummary(
        outcome: String,
        engine: String,
        sessionID: Int,
        finalTextChars: Int,
        usedCleanup: Bool? = nil,
        modelEndpoint: Bool? = nil,
        error: String? = nil
    ) {
        let now = Date()
        let sessionMs: Int
        if let startedAt = realtimeDiagnosticsSessionStartedAt {
            sessionMs = Int(now.timeIntervalSince(startedAt) * 1000)
        } else {
            sessionMs = -1
        }

        let speechToFirstPartialMs: Int
        if let speechStart = realtimeSpeechStartDetectedAt,
           let firstPartial = realtimeFirstPartialAt {
            speechToFirstPartialMs = Int(firstPartial.timeIntervalSince(speechStart) * 1000)
        } else {
            speechToFirstPartialMs = -1
        }

        var parts = [
            "session-summary outcome=\(outcome)",
            "engine=\(engine)",
            "session=\(sessionID)",
            "session_ms=\(sessionMs)",
            "speech_to_first_partial_ms=\(speechToFirstPartialMs)",
            "live=\(realtimeDiagnosticsLivePartialCount)",
            "shadow=\(realtimeDiagnosticsShadowPartialCount)",
            "promoted=\(realtimeDiagnosticsShadowPromotionCount)",
            "freeze=\(realtimeDiagnosticsFreezeAppliedCount)",
            "large_rollbacks=\(realtimeDiagnosticsLargeRollbackCount)",
            "final_chars=\(finalTextChars)",
            "fallback=\(realtimeUsingOverlayFallback)",
            "overlay_only=\(realtimeUsesOverlayOnlyMode)",
        ]

        if let usedCleanup {
            parts.append("used_cleanup=\(usedCleanup)")
        }
        if let modelEndpoint {
            parts.append("model_endpoint=\(modelEndpoint)")
        }
        if let error {
            parts.append("error=\(error)")
        }

        logRealtimeDiagnostics(
            parts.joined(separator: " "),
            level: outcome == "error" ? .error : .info
        )
    }

    private func makeManualRealtimeSpeechStartTiming() -> SpeechStartTiming {
        SpeechStartTiming(
            detectedAt: Date(),
            detector: "manual",
            profile: .realtimeParakeet,
            peakProbability: nil,
            trailingAverageProbability: nil
        )
    }

    private func makeManualRealtimeSegmentTiming(duration: TimeInterval) -> SpeechSegmentTiming {
        let now = Date()
        return SpeechSegmentTiming(
            speechDetectedAt: realtimeSpeechStartDetectedAt,
            lastVoiceActivityAt: now,
            endpointDetectedAt: now,
            endpointLatency: 0,
            silenceTimeoutUsed: 0,
            speechDuration: duration,
            detector: "manual",
            profile: .realtimeParakeet,
            peakProbability: nil,
            trailingMaxProbability: nil,
            trailingAverageProbability: nil
        )
    }

    private var realtimeEouTransportReady: Bool {
        realtimeEouService != nil
    }

    private func startRealtimeEouTransport(prerollSamples: [Float]) async throws -> Int {
        guard let realtimeEouService else {
            throw RealtimeParakeetServiceError.noActiveUtterance
        }
        return try await realtimeEouService.startUtterance(prerollSamples: prerollSamples)
    }

    private func appendRealtimeEouTransport(samples: [Float]) async {
        await realtimeEouService?.appendAudio(samples: samples)
    }

    private func finishRealtimeEouTransport(segment: AudioSegment, tailSamples: [Float] = []) async {
        if !tailSamples.isEmpty {
            await realtimeEouService?.appendAudio(samples: tailSamples)
        }
        await realtimeEouService?.finishUtterance(
            endpointSegment: segment.samples,
            speechDuration: segment.duration
        )
    }

    private func cancelRealtimeEouTransport() async {
        await realtimeEouService?.cancelUtterance()
    }

    private func cancelRealtimeStreamingUtterances() async {
        await realtimeParakeetService?.cancelUtterance()
        await cancelRealtimeEouTransport()
    }

    private func handleRealtimeAudioBlock(_ samples: [Float]) {
        guard activeTranscriptionEngine == .parakeetRealtimeTdt || activeTranscriptionEngine == .parakeetEou,
              shouldUseRealtimeEngineForCurrentMode else { return }
        if activeTranscriptionEngine == .parakeetRealtimeTdt, realtimeParakeetService == nil { return }
        if activeTranscriptionEngine == .parakeetEou, !realtimeEouTransportReady { return }

        let queuedSamples: [Float]?
        realtimeAudioLock.lock()
        if realtimeStreamingArmed {
            if ShortcutConfig.shared.recordingMode == .manual, isManualRecording {
                manualRealtimeCapturedSampleCount += samples.count
            }
            if realtimeSessionID == nil {
                realtimePendingAudioBlocks.append(samples)
                if realtimePendingAudioBlocks.count > 24 {
                    realtimePendingAudioBlocks.removeFirst(realtimePendingAudioBlocks.count - 24)
                }
                queuedSamples = nil
            } else {
                queuedSamples = samples
            }
        } else {
            queuedSamples = nil
        }
        realtimeAudioLock.unlock()

        guard let queuedSamples else { return }
        Task {
            await self.realtimeOperationQueue.enqueue { [weak self] in
                guard let self else { return }
                if self.activeTranscriptionEngine == .parakeetRealtimeTdt {
                    await self.realtimeParakeetService?.appendAudio(samples: queuedSamples)
                } else if self.activeTranscriptionEngine == .parakeetEou {
                    await self.appendRealtimeEouTransport(samples: queuedSamples)
                }
            }
        }
    }

    private func queueDeferredRealtimeUtteranceStart(_ timing: SpeechStartTiming) {
        guard realtimeDeferredStartTiming == nil else {
            appLog("Timing: realtime-start-deferred reason=already-queued")
            return
        }

        let prerollSampleCount = turboModeEnabled ? 4_800 : 2_400
        let prerollSamples = audioCapture.ringBuffer.readLast(sampleCount: prerollSampleCount)

        realtimeAudioLock.lock()
        realtimeStreamingArmed = true
        realtimeAudioLock.unlock()

        realtimeDeferredStartTiming = timing
        realtimeDeferredStartPrerollSamples = prerollSamples

        appLog(
            "Timing: realtime-start-deferred reason=session-finalizing session=\(realtimeFinishingSessionID.map(String.init) ?? "unknown") " +
            "preroll_ms=\(Int(Double(prerollSamples.count) / 16.0))"
        )
    }

    @discardableResult
    private func startDeferredRealtimeUtteranceIfNeeded() -> Bool {
        guard let timing = realtimeDeferredStartTiming else { return false }

        let prerollSamples = realtimeDeferredStartPrerollSamples
        realtimeDeferredStartTiming = nil
        realtimeDeferredStartPrerollSamples.removeAll(keepingCapacity: false)

        appLog(
            "Timing: realtime-start-resumed engine=\(activeTranscriptionEngine.rawValue) " +
            "buffered_blocks=\(realtimePendingAudioBlocks.count) pending_finish=\(realtimePendingFinish != nil)"
        )
        beginRealtimeUtterance(
            timing: timing,
            prerollOverride: prerollSamples,
            preserveBufferedBlocks: true,
            preservePendingFinish: true
        )
        return true
    }

    private func beginRealtimeUtterance(
        timing: SpeechStartTiming,
        prerollOverride: [Float]? = nil,
        preserveBufferedBlocks: Bool = false,
        preservePendingFinish: Bool = false
    ) {
        guard (activeTranscriptionEngine == .parakeetRealtimeTdt || activeTranscriptionEngine == .parakeetEou),
              shouldUseRealtimeEngineForCurrentMode else { return }
        if activeTranscriptionEngine == .parakeetRealtimeTdt, realtimeParakeetService == nil {
            appLog("Timing: realtime-start-skipped reason=service-not-ready engine=parakeet-realtime-tdt")
            return
        }
        if activeTranscriptionEngine == .parakeetEou, !realtimeEouTransportReady {
            appLog("Timing: realtime-start-skipped reason=service-not-ready engine=parakeet-eou")
            return
        }
        guard !realtimeStartInFlight else {
            appLog("Timing: realtime-start-skipped reason=start-in-flight")
            return
        }
        if realtimeFinishingSessionID != nil {
            queueDeferredRealtimeUtteranceStart(timing)
            return
        }
        guard realtimeSessionID == nil else {
            appLog("Timing: realtime-start-skipped reason=session-active")
            return
        }

        let prerollSampleCount = turboModeEnabled ? 4_800 : 2_400
        let prerollSamples = prerollOverride ?? audioCapture.ringBuffer.readLast(sampleCount: prerollSampleCount)

        realtimeAudioLock.lock()
        realtimeStreamingArmed = true
        if !preserveBufferedBlocks {
            realtimePendingAudioBlocks.removeAll(keepingCapacity: false)
        }
        realtimeSessionID = nil
        realtimeAudioLock.unlock()

        realtimeSpeechStartDetectedAt = timing.detectedAt
        realtimeFirstPartialAt = nil
        realtimeEndpointDetectedAt = nil
        if !preserveBufferedBlocks {
            manualRealtimeCapturedSampleCount = 0
        }
        if !preservePendingFinish {
            realtimePendingFinish = nil
        }
        realtimeShouldSuppressFinalCommit = false
        realtimeTerminalTypedText = ""
        realtimeTerminalDeferredStreamText = nil
        if realtimeUsesOverlayOnlyMode {
            cancelOverlayOnlyPendingCommit()
            realtimeProvisionalSession = nil
            realtimeUsingOverlayFallback = false
            realtimeUsingDirectTypingFallback = false
            overlayPanel.show(status: .hearing)
            appLog("Timing: overlay-only session=\(activeTranscriptionEngine.rawValue) finalization=\(realtimeFinalizationMode.rawValue)")
        } else {
            let frontApp = NSWorkspace.shared.frontmostApplication
            let prefersDirectRealtimeTyping = Self.shouldPreferDirectRealtimeTyping(
                preset: selectedTranscriptionPreset,
                bundleIdentifier: frontApp?.bundleIdentifier,
                appName: frontApp?.localizedName
            )
            let provisionalSession = prefersDirectRealtimeTyping ? nil : keyboardInjector.beginProvisionalSession()
            realtimeProvisionalSession = provisionalSession
            realtimeUsingDirectTypingFallback = false

            if provisionalSession != nil {
                realtimeTargetIsTerminal = false
                realtimeUsingOverlayFallback = false
            } else {
                realtimeTargetIsTerminal = TerminalHostPolicy.isTerminalLike(
                    bundleIdentifier: frontApp?.bundleIdentifier,
                    appName: frontApp?.localizedName
                )
                realtimeUsingOverlayFallback = true
                if realtimeTargetIsTerminal {
                    appLog("Timing: terminal-detected app=\(frontApp?.bundleIdentifier ?? "unknown") — using terminal streaming fallback")
                } else if prefersDirectRealtimeTyping {
                    appLog("Timing: browser-direct-typing-preferred app=\(frontApp?.bundleIdentifier ?? "unknown") — skipping AX provisional session")
                } else {
                    appLog("Timing: provisional-session-unavailable app=\(frontApp?.bundleIdentifier ?? "unknown") — using overlay/delta fallback")
                }
            }
        }
        realtimeDisplayedText = ""
        realtimeOverlayShadowPinned = false
        realtimeOverlayShadowText = ""
        realtimeShadowCandidateText = nil
        realtimeShadowCandidateStreak = 0
        realtimeLastShownOverlayPartial = nil
        realtimeLastOverlayPartialSkipState = nil
        resetRealtimeDiagnosticsState()
        realtimeDiagnosticsSessionStartedAt = Date()
        realtimeStartInFlight = true

        // Set up realtime LLM cleanup runners
        setupRealtimeLLMRunners()

        logRealtimeDiagnostics(
            "session-arming engine=\(activeTranscriptionEngine.rawValue) finalization=\(realtimeFinalizationMode.rawValue) " +
            "shadow=\(realtimeShadowCleanupMode.rawValue) preroll_ms=\(Int(Double(prerollSamples.count) / 16.0))"
        )

        Task {
            await self.realtimeOperationQueue.enqueue { [weak self] in
                guard let self else { return }
                do {
                    if self.activeTranscriptionEngine == .parakeetRealtimeTdt {
                        guard let realtimeParakeetService = self.realtimeParakeetService else {
                            await MainActor.run {
                                self.resetRealtimeDeliveryState()
                            }
                            return
                        }
                        _ = try await realtimeParakeetService.startUtterance(prerollSamples: prerollSamples)
                    } else {
                        guard self.realtimeEouTransportReady else {
                            await MainActor.run {
                                self.resetRealtimeDeliveryState()
                            }
                            return
                        }
                        _ = try await self.startRealtimeEouTransport(prerollSamples: prerollSamples)
                    }
                } catch {
                    await MainActor.run {
                        self.realtimeStartInFlight = false
                        self.realtimeUsingOverlayFallback = true
                        self.realtimeShouldSuppressFinalCommit = false
                        appError("Realtime utterance failed to start: \(error.localizedDescription)")
                        self.logRealtimeDiagnostics(
                            "session-start-failed engine=\(self.activeTranscriptionEngine.rawValue) error=\(error.localizedDescription)",
                            level: .error
                        )
                    }
                }
            }
        }
    }

    private func finishRealtimeUtterance(segment: AudioSegment, timing: SpeechSegmentTiming) {
        guard (activeTranscriptionEngine == .parakeetRealtimeTdt || activeTranscriptionEngine == .parakeetEou),
              (ShortcutConfig.shared.recordingMode == .alwaysOn ||
               ShortcutConfig.shared.recordingMode == .manual) else { return }
        if activeTranscriptionEngine == .parakeetRealtimeTdt, realtimeParakeetService == nil {
            appLog("Timing: realtime-finish-skipped reason=service-not-ready engine=parakeet-realtime-tdt")
            return
        }
        if activeTranscriptionEngine == .parakeetEou, !realtimeEouTransportReady {
            appLog("Timing: realtime-finish-skipped reason=service-not-ready engine=parakeet-eou")
            return
        }

        realtimeEndpointDetectedAt = timing.endpointDetectedAt
        let activeSessionID: Int?
        let manualTailSamples: [Float]
        let capturedSampleCountBeforeFinish: Int
        realtimeAudioLock.lock()
        activeSessionID = realtimeSessionID
        realtimeStreamingArmed = false
        if ShortcutConfig.shared.recordingMode == .manual {
            capturedSampleCountBeforeFinish = manualRealtimeCapturedSampleCount
            let missingTailSampleCount = max(0, segment.samples.count - manualRealtimeCapturedSampleCount)
            if missingTailSampleCount > 0, missingTailSampleCount <= segment.samples.count {
                manualTailSamples = Array(segment.samples.suffix(missingTailSampleCount))
            } else {
                manualTailSamples = []
            }
            manualRealtimeCapturedSampleCount = 0
        } else {
            capturedSampleCountBeforeFinish = 0
            manualTailSamples = []
        }
        if let activeSessionID {
            realtimeFinishingSessionID = activeSessionID
            realtimeSessionID = nil
        }
        realtimeAudioLock.unlock()

        guard activeSessionID != nil else {
            if realtimeStartInFlight || realtimeDeferredStartTiming != nil {
                realtimePendingFinish = (
                    samples: segment.samples,
                    duration: segment.duration,
                    endpointDetectedAt: timing.endpointDetectedAt
                )
                let reason = realtimeDeferredStartTiming != nil ? "deferred-start" : "start-in-flight"
                appLog("Timing: realtime-finish-deferred reason=\(reason)")
            } else {
                realtimeAudioLock.lock()
                realtimePendingAudioBlocks.removeAll(keepingCapacity: false)
                realtimeAudioLock.unlock()
                appLog("Timing: realtime-finish-skipped reason=no-active-session")
            }
            return
        }

        realtimeAudioLock.lock()
        realtimePendingAudioBlocks.removeAll(keepingCapacity: false)
        realtimeAudioLock.unlock()

        if !manualTailSamples.isEmpty {
            logRealtimeDiagnostics(
                "manual-tail-append engine=\(activeTranscriptionEngine.rawValue) " +
                "samples=\(manualTailSamples.count) captured=\(capturedSampleCountBeforeFinish) " +
                "segment=\(segment.samples.count) tail_ms=\(Int(Double(manualTailSamples.count) / 16.0))"
            )
        }

        Task {
            await self.realtimeOperationQueue.enqueue { [weak self] in
                guard let self else { return }
                if self.activeTranscriptionEngine == .parakeetRealtimeTdt {
                    if !manualTailSamples.isEmpty {
                        await self.realtimeParakeetService?.appendAudio(samples: manualTailSamples)
                    }
                    await self.realtimeParakeetService?.finishUtterance(
                        endpointSegment: segment.samples,
                        speechDuration: segment.duration
                    )
                } else {
                    await self.finishRealtimeEouTransport(segment: segment, tailSamples: manualTailSamples)
                }
            }
        }
    }

    private func resetRealtimeDeliveryState() {
        realtimeAudioLock.lock()
        realtimeStreamingArmed = false
        realtimePendingAudioBlocks.removeAll(keepingCapacity: false)
        realtimeSessionID = nil
        realtimeAudioLock.unlock()
        realtimeFinishingSessionID = nil
        manualRealtimeCapturedSampleCount = 0
        realtimeStartInFlight = false

        if let realtimeProvisionalSession {
            keyboardInjector.cancelProvisionalSession(realtimeProvisionalSession)
        }

        realtimeDeferredStartTiming = nil
        realtimeDeferredStartPrerollSamples.removeAll(keepingCapacity: false)
        realtimeSpeechStartDetectedAt = nil
        realtimeFirstPartialAt = nil
        realtimeEndpointDetectedAt = nil
        realtimePendingFinish = nil
        realtimeProvisionalSession = nil
        realtimeShouldSuppressFinalCommit = false
        realtimeUsingOverlayFallback = false
        realtimeUsingDirectTypingFallback = false
        realtimeTargetIsTerminal = false
        realtimeTerminalTypedText = ""
        realtimeTerminalDeferredStreamText = nil
        realtimeDisplayedText = ""
        realtimeOverlayShadowPinned = false
        realtimeOverlayShadowText = ""
        realtimeShadowCandidateText = nil
        realtimeShadowCandidateStreak = 0
        realtimeLastShownOverlayPartial = nil
        realtimeLastOverlayPartialSkipState = nil
        resetRealtimeDiagnosticsState()
        Task {
            await self.realtimeOperationQueue.reset()
        }

        // If engine recreation was deferred (cleanup mode changed mid-session), do it now
        if pendingEngineRecreation {
            pendingEngineRecreation = false
            appLog("Dev terminal cleanup: applying deferred engine recreation")
            switchEngine(to: activeTranscriptionEngine)
        }
    }

    private func deliverRealtimePartial(_ update: RealtimePartialUpdate) {
        guard let activeSessionID = realtimeSessionID else {
            appLog("Timing: partial-dropped session=\(update.sessionID) reason=no-active-session")
            return
        }

        if update.sessionID != activeSessionID {
            appLog("Timing: partial-dropped session=\(update.sessionID) reason=stale-session active=\(activeSessionID)")
            return
        }

        if update.source == .eouLive,
           realtimeFirstPartialAt == nil,
           let speechStart = realtimeSpeechStartDetectedAt {
            realtimeFirstPartialAt = Date()
            let firstVisibleMs = Int(Date().timeIntervalSince(speechStart) * 1000)
            appLog("Timing: partial-first-visible session=\(update.sessionID) first_visible_ms=\(firstVisibleMs)")
        }

        let now = Date()
        if let lastPartialAt = realtimeDiagnosticsLastPartialAt {
            let gapMs = Int(now.timeIntervalSince(lastPartialAt) * 1000)
            if gapMs >= 1_400 {
                logRealtimeDiagnostics(
                    "partial-gap session=\(update.sessionID) source=\(update.source.rawValue) gap_ms=\(gapMs)",
                    level: .warning
                )
            }
        }
        realtimeDiagnosticsLastPartialAt = now

        switch update.source {
        case .eouLive:
            realtimeDiagnosticsLivePartialCount += 1
        case .shadowCleanup:
            realtimeDiagnosticsShadowPartialCount += 1
        }
        maybeLogRealtimePartialSummary(update)

        switch update.source {
        case .eouLive:
            applyLiveRealtimePartial(update)
        case .shadowCleanup:
            applyShadowCleanupPartial(update)
        }
    }

    private func applyLiveRealtimePartial(_ update: RealtimePartialUpdate) {
        let shouldMirrorOverlay = shouldShowPresetOverlay
        let shouldUseOverlayOnly = realtimeUsesOverlayOnlyMode
        let fieldText = stabilizedFieldPartialText(update.text, source: update.source, sessionID: update.sessionID)
        let previousDisplayedText = realtimeDisplayedText
        trackRealtimeRollbackIfNeeded(newText: fieldText, source: update.source, sessionID: update.sessionID)
        realtimeDisplayedText = fieldText
        realtimeShadowCandidateText = nil
        realtimeShadowCandidateStreak = 0

        // Feed realtime LLM runners with latest streamed text
        realtimeLLMShadowRunner?.update(streamedText: fieldText)
        realtimeSentenceChunker?.trackStreamedText(fieldText)
        realtimeSentenceChunker?.update(streamedText: fieldText)

        if !shouldUseOverlayOnly, let provisionalSession = realtimeProvisionalSession {
            let outcome = keyboardInjector.updateProvisionalText(fieldText, session: provisionalSession)
            switch outcome {
            case .updated:
                if shouldMirrorOverlay {
                    showRealtimeOverlayPartial(
                        text: fieldText,
                        confirmed: update.isConfirmed,
                        source: update.source,
                        sessionID: update.sessionID
                    )
                }
                return
            case .unchanged:
                if shouldMirrorOverlay {
                    showRealtimeOverlayPartial(
                        text: fieldText,
                        confirmed: update.isConfirmed,
                        source: update.source,
                        sessionID: update.sessionID
                    )
                }
                return
            case .fallback(let reason, let suppressFinalCommit):
                if !reason.hasSuffix("-retry") {
                    realtimeUsingOverlayFallback = true
                    realtimeProvisionalSession = nil
                    realtimeShouldSuppressFinalCommit = realtimeShouldSuppressFinalCommit || suppressFinalCommit
                    appLog("Timing: partial-fallback session=\(update.sessionID) reason=\(reason)")
                }
            }
        }

        if !shouldUseOverlayOnly,
           !realtimeTargetIsTerminal,
           realtimeProvisionalSession == nil,
           selectedTranscriptionPreset == .powerUserFastest,
           applyDirectRealtimeDelta(from: previousDisplayedText, to: fieldText) {
            realtimeDisplayedText = fieldText
            return
        }

        if realtimeTargetIsTerminal {
            streamCompleteWordsToTerminal(fieldText)
            return
        }

        if shouldMirrorOverlay || realtimeUsingOverlayFallback || shouldUseOverlayOnly {
            showRealtimeOverlayPartial(
                text: fieldText,
                confirmed: update.isConfirmed,
                source: update.source,
                sessionID: update.sessionID
            )
        }
    }

    /// Stream text into the terminal as partials arrive.
    /// First partial: typed immediately for instant feedback.
    /// Subsequent partials: only complete words (up to last space) to avoid
    /// typing a half-word that gets revised. The `hasPrefix` check is the
    /// safety net — if text diverges from what we typed, we stop and let
    /// the final commit handle it.
    private func streamCompleteWordsToTerminal(_ stabilizedText: String) {
        let safeText: String
        if realtimeTerminalTypedText.isEmpty {
            // First chunk: type immediately for instant feedback
            safeText = stabilizedText
        } else if let lastSpace = stabilizedText.lastIndex(of: " ") {
            // Subsequent chunks: only complete words
            safeText = String(stabilizedText[stabilizedText.startIndex..<lastSpace])
        } else {
            return
        }

        guard !safeText.isEmpty,
              safeText.count > realtimeTerminalTypedText.count,
              safeText.hasPrefix(realtimeTerminalTypedText) else {
            return
        }

        let newChars = String(safeText.dropFirst(realtimeTerminalTypedText.count))
        guard !newChars.isEmpty else { return }

        keyboardInjector.typeText(newChars)
        realtimeTerminalTypedText = safeText
    }

    private func applyShadowCleanupPartial(_ update: RealtimePartialUpdate) {
        guard realtimeShadowCleanupMode != .off else { return }

        // Terminal inline cleanup handles corrections inline — no overlay needed
        let isTerminalInlineCleanup = realtimeTargetIsTerminal && terminalInlineCleanupMode == .inlineCleanup

        let shouldShowOverlay: Bool
        if isTerminalInlineCleanup {
            shouldShowOverlay = false
        } else {
            switch realtimeShadowCleanupMode {
            case .off:
                shouldShowOverlay = false
            case .overlay:
                shouldShowOverlay = true
            case .field:
                // In field mode, shadow cleanup should update the owned text range, not compete
                // with the live overlay unless we've already fallen back out of owned-session edits.
                shouldShowOverlay = realtimeUsingOverlayFallback
            }
        }
        if shouldShowOverlay {
            if realtimeShadowCleanupMode == .overlay {
                let liveText = realtimeDisplayedText
                // Avoid snapping overlay backward to much shorter shadow hypotheses.
                if !liveText.isEmpty, update.text.count + 12 < liveText.count {
                    appLog(
                        "Timing: shadow-overlay-drop session=\(update.sessionID) reason=regressive " +
                        "live_chars=\(liveText.count) shadow_chars=\(update.text.count)"
                    )
                    return
                }
                if update.text == realtimeOverlayShadowText {
                    return
                }
                realtimeOverlayShadowPinned = true
                realtimeOverlayShadowText = update.text
            }
            showRealtimeOverlayPartial(
                text: update.text,
                confirmed: true,
                source: update.source,
                sessionID: update.sessionID
            )
        }

        guard realtimeShadowCleanupMode == .field else { return }

        // Terminal inline cleanup path: apply shadow corrections directly in the terminal
        if realtimeTargetIsTerminal, terminalInlineCleanupMode == .inlineCleanup {
            applyTerminalShadowCleanup(update)
            return
        }

        let fieldText = stabilizedFieldPartialText(update.text, source: update.source, sessionID: update.sessionID)
        guard shouldPromoteShadowCleanupCandidate(fieldText) else { return }
        guard isMaterialShadowCleanupChange(fieldText) else { return }
        guard let provisionalSession = realtimeProvisionalSession else { return }

        trackRealtimeRollbackIfNeeded(newText: fieldText, source: update.source, sessionID: update.sessionID)
        let outcome = keyboardInjector.updateProvisionalText(fieldText, session: provisionalSession)
        switch outcome {
        case .updated, .unchanged:
            realtimeDisplayedText = fieldText
            realtimeDiagnosticsShadowPromotionCount += 1
            appLog(
                "Timing: cleanup-promotion session=\(update.sessionID) source=\(update.source.rawValue) chars=\(fieldText.count)"
            )
        case .fallback(let reason, let suppressFinalCommit):
            if !reason.hasSuffix("-retry") {
                realtimeUsingOverlayFallback = true
                realtimeProvisionalSession = nil
                realtimeShouldSuppressFinalCommit = realtimeShouldSuppressFinalCommit || suppressFinalCommit
                appLog("Timing: partial-fallback session=\(update.sessionID) reason=\(reason)")
            }
        }
    }

    /// Apply shadow cleanup corrections inline in the terminal during streaming.
    /// If shadow text matches what we've typed, no action needed.
    /// If it differs, use applyStreamingDelta to fix just the diff (backspace+retype only).
    /// Large diffs (>15 chars to delete) are skipped — the final commit handles those.
    private func applyTerminalShadowCleanup(_ update: RealtimePartialUpdate) {
        let shadowText = update.text
        let typedText = realtimeTerminalTypedText

        guard !typedText.isEmpty else { return }

        // Shadow text extends what we've typed — no correction needed, streaming will catch up
        if shadowText.hasPrefix(typedText) {
            realtimeDisplayedText = shadowText
            return
        }

        // Shadow text matches — nothing to do
        if shadowText == typedText { return }

        // Shadow text differs — apply the minimal correction
        // Only correct the portion up to what we've typed (don't extend beyond typed range)
        let correctedPrefix: String
        if shadowText.count >= typedText.count {
            correctedPrefix = String(shadowText.prefix(typedText.count))
            // If correction is just extending/appending within same length, skip
            if correctedPrefix == typedText {
                realtimeDisplayedText = shadowText
                return
            }
        } else {
            correctedPrefix = shadowText
        }

        let currentChars = Array(typedText)
        let newChars = Array(correctedPrefix)
        let prefixCount = keyboardInjector.sharedPrefixCount(currentChars, newChars)
        let deleteCount = currentChars.count - prefixCount

        // Only apply small corrections (≤ 15 chars to delete) during streaming.
        // Large diffs are too disruptive mid-speech — let final commit handle them.
        guard deleteCount <= 15 else {
            appLog(
                "Timing: terminal-shadow-correction-skipped session=\(update.sessionID) " +
                "reason=too-large delete=\(deleteCount) typed=\(typedText.count)"
            )
            return
        }

        let applied = keyboardInjector.applyStreamingDelta(from: typedText, to: correctedPrefix)
        if applied {
            realtimeTerminalTypedText = correctedPrefix
            realtimeDisplayedText = correctedPrefix
            realtimeDiagnosticsShadowPromotionCount += 1
            appLog(
                "Timing: terminal-shadow-correction session=\(update.sessionID) " +
                "delete=\(deleteCount) typed=\(typedText.count) corrected=\(correctedPrefix.count)"
            )
        } else {
            appLog("Timing: terminal-shadow-correction-failed session=\(update.sessionID) delete=\(deleteCount)")
        }
    }

    private func shouldPromoteShadowCleanupCandidate(_ text: String) -> Bool {
        if realtimeShadowCandidateText == text {
            realtimeShadowCandidateStreak += 1
        } else {
            realtimeShadowCandidateText = text
            realtimeShadowCandidateStreak = 1
        }
        return realtimeShadowCandidateStreak >= 2
    }

    private func isMaterialShadowCleanupChange(_ newText: String) -> Bool {
        let baseline = realtimeProvisionalSession?.currentText ?? realtimeDisplayedText
        guard !baseline.isEmpty else { return true }

        let mutation = ProvisionalTextMutationPlan.build(from: baseline, to: newText)
        let changedUTF16 = mutation.replacedUTF16Count + mutation.replacementSuffix.utf16.count
        if changedUTF16 >= 2 { return true }

        if let lastChar = newText.last {
            return ".!?,".contains(lastChar)
        }
        return false
    }

    private func shouldRenderLiveOverlayPartial(_ text: String) -> Bool {
        guard realtimeShadowCleanupMode == .overlay else { return true }
        guard realtimeOverlayShadowPinned else { return true }

        // Keep shadow text visually stable unless live stream has clearly advanced.
        if text.count >= realtimeOverlayShadowText.count + 14 {
            realtimeOverlayShadowPinned = false
            realtimeOverlayShadowText = ""
            return true
        }
        return false
    }

    @discardableResult
    private func commitRealtimeResult(_ result: RealtimeUtteranceResult) -> Bool {
        commitLiveText(result.text, sessionID: result.sessionID)
    }

    private var shouldRouteTranscriptionToOnboarding: Bool {
        let isInOnboarding = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") || viewModel.isOnboardingPreviewActive
        return isInOnboarding && viewModel.isOnboardingTextFieldFocused
            && NSApp.isActive && NSApp.keyWindow != nil
    }

    private func onboardingDeliveryText(for text: String) -> String? {
        guard shouldRouteTranscriptionToOnboarding else { return nil }
        return TextDeliveryPolicy.normalizedText(text)
    }

    @discardableResult
    private func commitLiveText(_ text: String, sessionID: Int) -> Bool {
        if let onboardingText = onboardingDeliveryText(for: text) {
            realtimeDisplayedText = onboardingText
            viewModel.onboardingTranscriptionResult = onboardingText
            appLog("Onboarding transcript updated: \"\(onboardingText)\"")
            return true
        }

        if realtimeUsesOverlayOnlyMode {
            scheduleOverlayOnlyFinalCommit(text)
            realtimeDisplayedText = text
            return true
        }

        if let provisionalSession = realtimeProvisionalSession, !realtimeShouldSuppressFinalCommit {
            let finalTextWithTrailingSpace = text + " "
            var outcome = keyboardInjector.commitFinalText(finalTextWithTrailingSpace, session: provisionalSession)
            if case .fallback(let reason, _) = outcome, reason.hasSuffix("-retry") {
                appLog("Timing: final-commit-retry session=\(sessionID) reason=\(reason)")
                outcome = keyboardInjector.commitFinalText(finalTextWithTrailingSpace, session: provisionalSession)
            }
            switch outcome {
            case .updated, .unchanged:
                realtimeDisplayedText = text
                appLog("Typed realtime final via owned session: \"\(text)\"")
                return true
            case .fallback(let reason, let suppressFinalCommit):
                appLog("Timing: partial-fallback session=\(sessionID) reason=\(reason)")
                let ownedTrimmedText = provisionalSession.currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if provisionalSession.typedText, ownedTrimmedText == text {
                    realtimeDisplayedText = text
                    appLog("Timing: final-commit-suppressed-duplicate session=\(sessionID)")
                    return true
                }
                if suppressFinalCommit {
                    return false
                }
            }
        }

        if realtimeUsingDirectTypingFallback {
            let delivered: Bool
            if realtimeDisplayedText == text {
                delivered = prepareTextDeliveryTarget()
            } else {
                delivered = applyDirectRealtimeDelta(from: realtimeDisplayedText, to: text)
            }
            guard delivered else { return false }
            guard prepareTextDeliveryTarget(), keyboardInjector.typeTrailingSpace() else { return false }
            realtimeDisplayedText = text
            appLog("Typed realtime final via direct streaming fallback: \"\(text)\"")
            return true
        }

        guard !realtimeShouldSuppressFinalCommit else { return false }

        if realtimeTargetIsTerminal, !realtimeTerminalTypedText.isEmpty {
            guard prepareTextDeliveryTarget() else { return false }

            let cleanupMode = terminalInlineCleanupMode
            let streamedText = realtimeTerminalTypedText

            // Check if cleanup produced a different result than what we streamed
            if cleanupMode != .off, text != streamedText {
                switch cleanupMode {
                case .off:
                    break
                case .backspaceRewrite:
                    let applied = keyboardInjector.applyStreamingDelta(from: streamedText, to: text)
                    if applied {
                        keyboardInjector.typeTrailingSpace()
                        realtimeDisplayedText = text
                        appLog("Typed realtime final via terminal backspace-rewrite: \"\(text)\" (streamed \(streamedText.count) chars)")
                        return true
                    }
                    // Fallback to append-only if backspace failed
                    appLog("Terminal backspace-rewrite failed, falling back to append-only")
                case .clipboardPaste:
                    applyClipboardPasteCorrection(finalText: text)
                    realtimeDisplayedText = text
                    appLog("Typed realtime final via terminal clipboard-paste: \"\(text)\" (streamed \(streamedText.count) chars)")
                    return true
                case .deferredCleanup:
                    // Deferred cleanup commits stream text now, correction happens later
                    break
                case .inlineCleanup:
                    // Shadow corrections applied during streaming. Commit uses stream text
                    // (not cleanup text) so the append path below works. But if we still
                    // get here with divergent text, just accept what's typed — no correction.
                    keyboardInjector.typeTrailingSpace()
                    realtimeDisplayedText = text
                    appLog("Typed realtime final via terminal inline-cleanup (no correction): \"\(text)\" (streamed \(streamedText.count) chars)")
                    return true
                }
            }

            // Default: append remaining text
            let remaining: String
            if text.hasPrefix(realtimeTerminalTypedText) {
                remaining = String(text.dropFirst(realtimeTerminalTypedText.count))
            } else {
                remaining = text
            }
            if !remaining.isEmpty {
                keyboardInjector.typeText(remaining)
            }
            keyboardInjector.typeTrailingSpace()
            realtimeDisplayedText = text
            appLog("Typed realtime final via terminal streaming: \"\(text)\" (pre-typed \(realtimeTerminalTypedText.count) chars)")
            return true
        }

        realtimeDisplayedText = text
        return deliverText(text)
    }

    private func activeRealtimeSessionLabel() -> String {
        realtimeSessionID.map(String.init) ?? realtimeFinishingSessionID.map(String.init) ?? "none"
    }

    private func matchesRealtimeCallbackSession(_ sessionID: Int?) -> Bool {
        guard let sessionID else {
            return realtimeSessionID == nil || realtimeFinishingSessionID == nil
        }
        return realtimeSessionID == sessionID || realtimeFinishingSessionID == sessionID
    }

    private func clearRealtimeCallbackSession(_ sessionID: Int?) {
        if let sessionID {
            if realtimeSessionID == sessionID {
                realtimeSessionID = nil
            }
            if realtimeFinishingSessionID == sessionID {
                realtimeFinishingSessionID = nil
            }
            return
        }

        realtimeSessionID = nil
        realtimeFinishingSessionID = nil
    }
}

// MARK: - AudioCaptureDelegate

extension AppDelegate: AudioCaptureDelegate {
    func audioCaptureDidStart() {
        // Only show "listening" state in always-on mode.
        // In manual mode, the engine runs warm but we're not actively listening.
        if ShortcutConfig.shared.recordingMode == .alwaysOn {
            appState.currentState = .listening
        }
        if hadAudioFailure {
            hadAudioFailure = false
            appLog("Audio capture recovered after failure")
            if currentInputDeviceState?.userInitiated != true {
                trackEvent("deviceSwitchRecovered", parameters: [
                    "device": currentInputDeviceState?.deviceName ?? "unknown",
                ])
            }
        }
        appLog("Audio capture started")
    }

    func audioCaptureInputDeviceStateDidChange(_ state: AudioInputDeviceState) {
        currentInputDeviceState = state

        switch state.phase {
        case .switching:
            // If toggle recording is active, keep the toggle buffer running across device switch
            // (brief audio gap but recording preserved). Only clear non-toggle state.
            if !isToggleRecording {
                pendingSpeechQueue.removeAll()
            }
            transcriptionService.invalidateSession()
            isTranscriptionInProgress = false
            lastSpeechDuration = 0
            resetRealtimeDeliveryState()
            Task { [weak self] in
                await self?.cancelRealtimeStreamingUtterances()
            }
            appLog("Switching input to \(state.deviceName)\(isToggleRecording ? " (toggle recording preserved)" : "")")
        case .failed:
            hadAudioFailure = true
            appLog("Input device failed: \(state.deviceName) — \(state.detail ?? "Unknown failure")")
            trackEvent("deviceSwitchFailed", parameters: [
                "reason": "deviceFailed",
                "device": state.deviceName,
                "detail": state.detail ?? "unknown",
            ])
            if !isManualRecording {
                appState.currentState = .idle
            }
        case .ready:
            if state.userInitiated {
                appLog("Input device ready: \(state.deviceName)")
                trackEvent("deviceSwitchRecovered", parameters: ["device": state.deviceName])
            }
        case .startedAwaitingCallbacks, .awaitingSignal, .idle:
            break
        }
    }

    func audioCaptureDidStop() {
        resetRealtimeDeliveryState()
        Task { [weak self] in
            await self?.cancelRealtimeStreamingUtterances()
        }
        appState.currentState = .idle
        statusItem?.button?.title = ""
    }

    func audioCaptureDidFail(error: Error) {
        let isExpectedDeviceFailure = currentInputDeviceState?.phase == .failed
        if isExpectedDeviceFailure {
            appLog("Audio capture failed for selected device: \(error.localizedDescription)")
        } else {
            appError("Audio capture failed: \(error.localizedDescription)")
            trackEvent("errorOccurred", parameters: ["source": "audioCapture", "error": error.localizedDescription])
        }

        // Detect device-switch-related failures for specific telemetry
        if let captureError = error as? AudioCaptureError {
            switch captureError {
            case .noInputDevice:
                hadAudioFailure = true
                if currentInputDeviceState?.phase == .failed {
                    appState.currentState = .idle
                    return
                }
                trackEvent("deviceSwitchFailed", parameters: [
                    "reason": "noInputDevice",
                    "device": "none",
                    "detail": "no input device available",
                ])
            case .engineStartFailed(let underlying):
                hadAudioFailure = true
                if currentInputDeviceState?.phase == .failed {
                    appState.currentState = .idle
                    return
                }
                trackEvent("deviceSwitchFailed", parameters: [
                    "reason": "engineStartFailed",
                    "device": "unknown",
                    "detail": underlying.localizedDescription,
                ])
            case .microphonePermissionDenied:
                showMicPermissionAlert()
                appState.currentState = .error(error.localizedDescription)
            }
        }
    }

    func audioCaptureDidDetectSpeechStart(timing: SpeechStartTiming) {
        var parts = [
            "Timing: speech-start",
            "detector=\(timing.detector)",
            "profile=\(timing.profile.rawValue)",
        ]
        if let peak = timing.peakProbability {
            parts.append("peak=\(String(format: "%.2f", peak))")
        }
        if let trailingAverage = timing.trailingAverageProbability {
            parts.append("trailing_avg=\(String(format: "%.2f", trailingAverage))")
        }
        appLog(parts.joined(separator: " "))

        if (activeTranscriptionEngine == .parakeetRealtimeTdt || activeTranscriptionEngine == .parakeetEou),
           ShortcutConfig.shared.recordingMode == .alwaysOn {
            beginRealtimeUtterance(timing: timing)
        }
    }

    func audioCaptureDidDetectSpeechEnd(segment: AudioSegment, timing: SpeechSegmentTiming) {
        lastSpeechDuration = segment.duration
        appLog(
            "Timing: speech-end detector=\(timing.detector) profile=\(timing.profile.rawValue) " +
            "speech_ms=\(Int(timing.speechDuration * 1000)) endpoint_wait_ms=\(Int(timing.endpointLatency * 1000)) " +
            "silence_gate_ms=\(Int(timing.silenceTimeoutUsed * 1000))"
        )
        #if DEBUG
        print("[App] VAD speech ended — \(String(format: "%.1f", segment.duration))s")
        #endif

        if (activeTranscriptionEngine == .parakeetRealtimeTdt || activeTranscriptionEngine == .parakeetEou),
           ShortcutConfig.shared.recordingMode == .alwaysOn {
            if realtimeFirstPartialAt == nil, timing.speechDuration >= 0.35 {
                logRealtimeDiagnosticsOnce(
                    "no-visible-partial-before-end",
                    "no-visible-partial-before-end engine=\(activeTranscriptionEngine.rawValue) " +
                    "speech_ms=\(Int(timing.speechDuration * 1000)) endpoint_wait_ms=\(Int(timing.endpointLatency * 1000))",
                    level: .warning
                )
            }
            finishRealtimeUtterance(segment: segment, timing: timing)
            return
        }

        enqueueTranscription(
            makePendingTranscriptionRequest(
                samples: segment.samples,
                duration: segment.duration,
                source: "always-on",
                speechTiming: timing,
                enqueuedAt: Date()
            )
        )
    }

    func audioCaptureDidDiscardSpeechSegment(timing: SpeechSegmentTiming) {
        appLog(
            "Timing: dropped source=vad reason=speech-too-short detector=\(timing.detector) " +
            "profile=\(timing.profile.rawValue) speech_ms=\(Int(timing.speechDuration * 1000))"
        )

        guard activeTranscriptionEngine == .parakeetRealtimeTdt || activeTranscriptionEngine == .parakeetEou,
              ShortcutConfig.shared.recordingMode == .alwaysOn else { return }

        logRealtimeDiagnostics(
            "speech-dropped-too-short detector=\(timing.detector) profile=\(timing.profile.rawValue) " +
            "speech_ms=\(Int(timing.speechDuration * 1000))",
            level: .warning
        )

        let hadArmedRealtimeUtterance: Bool
        realtimeAudioLock.lock()
        hadArmedRealtimeUtterance = realtimeStreamingArmed
        realtimeStreamingArmed = false
        realtimePendingAudioBlocks.removeAll(keepingCapacity: false)
        realtimeAudioLock.unlock()
        realtimePendingFinish = nil

        let shouldCancelActiveSession = hadArmedRealtimeUtterance || realtimeStartInFlight
        guard shouldCancelActiveSession else {
            // Ignore short blips that happen while a previous utterance is already finalizing.
            appLog("Timing: dropped source=vad reason=speech-too-short action=ignored-no-armed-session")
            logRealtimeDiagnostics(
                "speech-dropped-no-active-session action=ignored speech_ms=\(Int(timing.speechDuration * 1000))"
            )
            return
        }

        if realtimeSessionID != nil || realtimeStartInFlight {
            Task { [weak self] in
                await self?.cancelRealtimeStreamingUtterances()
            }
        }
        resetRealtimeDeliveryState()
        appState.currentState = .listening
    }

    private func showMicPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Access Required"
        alert.informativeText = "Please grant microphone access in System Settings → Privacy & Security → Microphone."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "OK")

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func enqueueTranscription(_ request: PendingTranscriptionRequest) {
        lastSpeechDuration = request.duration
        appLog(
            "Timing: enqueue source=\(request.source) id=\(request.id) " +
            "profile=\(request.speechTiming?.profile.rawValue ?? "manual") " +
            "samples=\(request.samples.count) speech_ms=\(Int(request.duration * 1000)) " +
            "carryover_pending=\(pendingAlwaysOnBatchCarryover != nil)"
        )
        if isTranscriptionInProgress {
            pendingSpeechQueue.append(request)
            #if DEBUG
            print("[App] Engine busy — queued (\(pendingSpeechQueue.count) pending)")
            #endif
            appLog("Timing: queued source=\(request.source) id=\(request.id) pending=\(pendingSpeechQueue.count)")
            return
        }

        submitTranscription(request)
    }

    private func makePendingTranscriptionRequest(
        samples: [Float],
        duration: Double,
        source: String,
        speechTiming: SpeechSegmentTiming?,
        enqueuedAt: Date,
        retainedAudio: RetainedAudioReference? = nil,
        historyRetryID: UUID? = nil
    ) -> PendingTranscriptionRequest {
        nextTranscriptionRequestID &+= 1
        return PendingTranscriptionRequest(
            id: nextTranscriptionRequestID,
            samples: samples,
            duration: duration,
            source: source,
            speechTiming: speechTiming,
            enqueuedAt: enqueuedAt,
            retainedAudio: retainedAudio,
            historyRetryID: historyRetryID
        )
    }

    private static func shouldPersistFailedManualAudio(for source: String) -> Bool {
        source == "ptt" || source == "toggle"
    }

    private static func shouldRecordHistoryFailure(for source: String) -> Bool {
        source == "ptt" || source == "toggle" || source == "retry"
    }

    private func cleanupRetainedAudioAfterSuccess(for request: PendingTranscriptionRequest?) {
        guard let retainedAudio = request?.retainedAudio else { return }

        switch retainedAudio {
        case .temporaryFile(let url):
            try? FileManager.default.removeItem(at: url)
        case .cachedFile(let fileName):
            TranscriptionHistoryStore.shared.removeAudioFile(fileName: fileName)
        }
    }

    private func materializeAudioFileNameForFailure(
        request: PendingTranscriptionRequest,
        historyID: UUID
    ) -> String? {
        if let retainedAudio = request.retainedAudio {
            switch retainedAudio {
            case .temporaryFile(let url):
                if let adopted = TranscriptionHistoryStore.shared.adoptAudioFile(from: url, id: historyID) {
                    return adopted
                }
                try? FileManager.default.removeItem(at: url)
            case .cachedFile(let fileName):
                return fileName
            }
        }

        guard Self.shouldPersistFailedManualAudio(for: request.source), !request.samples.isEmpty else {
            return nil
        }

        return TranscriptionHistoryStore.shared.saveAudio(samples: request.samples, id: historyID)
    }

    #if DEBUG
    private func consumeForcedManualTranscriptionFailure(
        for request: PendingTranscriptionRequest
    ) -> ForcedManualTranscriptionError? {
        guard request.source == "ptt" || request.source == "toggle" else {
            print("[App] Forced failure check — skipped (source=\(request.source))")
            return nil
        }
        guard isForcedManualTranscriptionFailureArmed else {
            print("[App] Forced failure check — not armed")
            return nil
        }
        UserDefaults.standard.set(false, forKey: forcedManualTranscriptionFailureDefaultsKey)
        scheduleMenuRebuild()
        print("[App] Forced failure TRIGGERED for source=\(request.source)")
        appLog("Debug manual transcription failure triggered for source=\(request.source)")
        return .requested
    }
    #endif

    /// 0.5s of silence at 16kHz — ~6 encoder frames of decode budget past the last word.
    internal static let manualStopDecoderTailPadSamples = 8_000

    internal static func shouldPadManualStopDecoderTail(source: String) -> Bool {
        source == "ptt" || source == "toggle" || source == "retry"
    }

    internal static func rescueShortAlwaysOnBatchSamples(
        _ samples: [Float],
        minimumASRSamples: Int,
        maximumPaddingSamples: Int = 6_400
    ) -> [Float]? {
        guard samples.count < minimumASRSamples else { return nil }

        let paddingSamples = minimumASRSamples - samples.count
        guard paddingSamples <= maximumPaddingSamples else { return nil }

        var rescued = samples
        rescued.reserveCapacity(minimumASRSamples)
        rescued.append(contentsOf: repeatElement(0, count: paddingSamples))
        return rescued
    }

    internal static func shouldRescueShortBatchSamples(
        source: String,
        profile: EndpointingProfile?
    ) -> Bool {
        switch source {
        case "ptt", "toggle":
            return true
        case "always-on":
            return profile == .standard || profile == .stableExtraQuick
        default:
            return false
        }
    }

    internal static func shouldRetainAlwaysOnBatchCarryover(
        source: String,
        profile: EndpointingProfile?,
        error: TranscriptionError
    ) -> Bool {
        guard source == "always-on",
              profile == .stableExtraQuick else {
            return false
        }

        return error == .audioTooShort || error == .noSpeechDetected
    }

    internal static func mergeAlwaysOnBatchSamples(
        carryover: [Float],
        next: [Float]
    ) -> [Float] {
        guard !carryover.isEmpty else { return next }
        guard !next.isEmpty else { return carryover }

        var merged = carryover
        merged.reserveCapacity(carryover.count + next.count)
        merged.append(contentsOf: next)
        return merged
    }

    private func retainAlwaysOnBatchCarryover(
        from request: PendingTranscriptionRequest,
        reason: TranscriptionError
    ) {
        let expiresAt = Date().addingTimeInterval(1.5)
        pendingAlwaysOnBatchCarryover = AlwaysOnBatchCarryover(
            request: request,
            expiresAt: expiresAt
        )
        appLog(
            "Timing: carryover-retained source=\(request.source) id=\(request.id) " +
            "profile=\(request.speechTiming?.profile.rawValue ?? "unknown") " +
            "reason=\(reason.localizedDescription) samples=\(request.samples.count) " +
            "speech_ms=\(Int(request.duration * 1000)) expires_in_ms=1500"
        )
    }

    private func prepareBatchTranscriptionRequest(_ request: PendingTranscriptionRequest) -> PendingTranscriptionRequest {
        var preparedRequest = request

        if let carryover = pendingAlwaysOnBatchCarryover {
            let carryoverExpired = carryover.expiresAt < Date()
            let preparedProfile = preparedRequest.speechTiming?.profile
            let requestEligibleForMerge = preparedRequest.source == "always-on" && preparedProfile == .stableExtraQuick

            if carryoverExpired || !requestEligibleForMerge {
                let action = carryoverExpired ? "expired" : "cleared"
                appLog(
                    "Timing: carryover-\(action) source=\(carryover.request.source) id=\(carryover.request.id) " +
                    "profile=\(carryover.request.speechTiming?.profile.rawValue ?? "unknown") " +
                    "samples=\(carryover.request.samples.count) " +
                    "next_id=\(preparedRequest.id) next_profile=\(preparedProfile?.rawValue ?? "unknown")"
                )
                pendingAlwaysOnBatchCarryover = nil
            } else {
                let mergedSamples = Self.mergeAlwaysOnBatchSamples(
                    carryover: carryover.request.samples,
                    next: preparedRequest.samples
                )
                appLog(
                    "Timing: carryover-merged source=\(preparedRequest.source) id=\(preparedRequest.id) " +
                    "profile=\(preparedProfile?.rawValue ?? "unknown") " +
                    "carryover_id=\(carryover.request.id) " +
                    "carryover_samples=\(carryover.request.samples.count) " +
                    "next_samples=\(preparedRequest.samples.count) merged_samples=\(mergedSamples.count) " +
                    "carryover_age_ms=\(Int(Date().timeIntervalSince(carryover.request.enqueuedAt) * 1000))"
                )
                preparedRequest = PendingTranscriptionRequest(
                    id: preparedRequest.id,
                    samples: mergedSamples,
                    duration: Double(mergedSamples.count) / 16_000.0,
                    source: preparedRequest.source,
                    speechTiming: preparedRequest.speechTiming,
                    enqueuedAt: carryover.request.enqueuedAt,
                    retainedAudio: preparedRequest.retainedAudio,
                    historyRetryID: preparedRequest.historyRetryID
                )
                pendingAlwaysOnBatchCarryover = nil
            }
        }

        if Self.shouldPadManualStopDecoderTail(source: preparedRequest.source) {
            // Parakeet TDT stops decoding at the last real-audio frame (FluidAudio
            // clamps the decode loop to actualAudioFrames; its own zero-pad to the
            // 15s model window does not extend that clamp), so a word ending flush
            // with the end of capture can lose its final token. Manual stops (fn
            // release) can end capture within ~100ms of the last word — appended
            // silence extends the decoder's frame budget past it. Always-on
            // segments already end in VAD-confirmed silence and don't need this.
            var paddedSamples = preparedRequest.samples
            paddedSamples.append(
                contentsOf: repeatElement(0, count: Self.manualStopDecoderTailPadSamples)
            )
            preparedRequest = PendingTranscriptionRequest(
                id: preparedRequest.id,
                samples: paddedSamples,
                duration: preparedRequest.duration,
                source: preparedRequest.source,
                speechTiming: preparedRequest.speechTiming,
                enqueuedAt: preparedRequest.enqueuedAt,
                retainedAudio: preparedRequest.retainedAudio,
                historyRetryID: preparedRequest.historyRetryID
            )
        }

        let preparedProfile = preparedRequest.speechTiming?.profile

        guard Self.shouldRescueShortBatchSamples(
                  source: preparedRequest.source,
                  profile: preparedProfile
              ),
              let rescuedSamples = Self.rescueShortAlwaysOnBatchSamples(
                  preparedRequest.samples,
                  minimumASRSamples: transcriptionService.minimumASRSamples
              )
        else {
            if preparedRequest.source == "always-on",
               preparedRequest.samples.count < transcriptionService.minimumASRSamples {
                appLog(
                    "Timing: short-segment-unrescued source=\(preparedRequest.source) id=\(preparedRequest.id) " +
                    "profile=\(preparedProfile?.rawValue ?? "unknown") " +
                    "samples=\(preparedRequest.samples.count) minimum=\(transcriptionService.minimumASRSamples)"
                )
            }
            return preparedRequest
        }

        appLog(
            "Timing: short-segment-rescued source=\(preparedRequest.source) id=\(preparedRequest.id) " +
            "profile=\(preparedProfile?.rawValue ?? "manual") " +
            "original_samples=\(preparedRequest.samples.count) padded_samples=\(rescuedSamples.count)"
        )

        return PendingTranscriptionRequest(
            id: preparedRequest.id,
            samples: rescuedSamples,
            duration: preparedRequest.duration,
            source: preparedRequest.source,
            speechTiming: preparedRequest.speechTiming,
            enqueuedAt: preparedRequest.enqueuedAt,
            retainedAudio: preparedRequest.retainedAudio,
            historyRetryID: preparedRequest.historyRetryID
        )
    }

    private func submitTranscription(_ request: PendingTranscriptionRequest) {
        let preparedRequest = prepareBatchTranscriptionRequest(request)
        activeTranscriptionRequest = preparedRequest
        lastSpeechDuration = preparedRequest.duration
        appLog(
            "Timing: submit source=\(preparedRequest.source) id=\(preparedRequest.id) " +
            "profile=\(preparedRequest.speechTiming?.profile.rawValue ?? "manual") " +
            "samples=\(preparedRequest.samples.count) speech_ms=\(Int(preparedRequest.duration * 1000))"
        )
        #if DEBUG
        print("[App] Transcribing...")
        #endif

        #if DEBUG
        if let forcedFailure = consumeForcedManualTranscriptionFailure(for: preparedRequest) {
            isTranscriptionInProgress = true
            DispatchQueue.main.async { [weak self] in
                self?.transcriptionDidFail(error: forcedFailure)
            }
            return
        }
        #endif

        transcriptionService.transcribe(samples: preparedRequest.samples)
    }
}

// MARK: - TranscriptionDelegate

extension AppDelegate: TranscriptionDelegate {
    func transcriptionDidStart() {
        isTranscriptionInProgress = true
        if !isManualRecording {
            appState.currentState = .transcribing
        }
    }

    func transcriptionDidComplete(utterance: Utterance) {
        let completedRequest = activeTranscriptionRequest
        let rawWordCount = WordCounter.countWords(in: utterance.text)
        let batchSource = completedRequest?.source ?? "unknown"
        appLog("Transcription: \"\(utterance.text)\" (\(rawWordCount) words, \(String(format: "%.2f", utterance.duration))s)")
        #if DEBUG
        print("[App] Transcription: \"\(utterance.text)\" (\(rawWordCount) words, took \(String(format: "%.2f", utterance.duration))s)")
        #endif

        if shouldRouteTranscriptionToOnboarding {
            completeBatchTranscription(
                finalText: utterance.text,
                cleanupUsed: false,
                utterance: utterance,
                completedRequest: completedRequest,
                batchSource: batchSource
            )
            return
        }

        if LLMCleanupService.isEnabled && LLMCleanupService.modelID == "regex" {
            self.completeBatchTranscription(
                finalText: applyITNIfEnabled(applyRegexFillerCleanup(utterance.text)),
                cleanupUsed: true,
                utterance: utterance,
                completedRequest: completedRequest,
                batchSource: batchSource
            )
        } else if LLMCleanupService.isEnabled {
            Task { [weak self] in
                guard let self else { return }
                let preClean = applyRegexFillerCleanup(utterance.text)
                let llmCleanedText = await LLMCleanupService.shared.cleanup(preClean)
                let cleanedText = self.applyITNIfEnabled(llmCleanedText)
                #if DEBUG
                if cleanedText != utterance.text {
                    print("[LLMCleanup] \"\(utterance.text)\" → \"\(cleanedText)\"")
                }
                #endif
                await MainActor.run {
                    self.completeBatchTranscription(
                        finalText: cleanedText,
                        cleanupUsed: true,
                        utterance: utterance,
                        completedRequest: completedRequest,
                        batchSource: batchSource
                    )
                }
            }
        } else {
            completeBatchTranscription(
                finalText: applyITNIfEnabled(utterance.text),
                cleanupUsed: false,
                utterance: utterance,
                completedRequest: completedRequest,
                batchSource: batchSource
            )
        }
    }

    @discardableResult
    private func deliverText(_ text: String) -> Bool {
        if let onboardingText = onboardingDeliveryText(for: text) {
            viewModel.onboardingTranscriptionResult = onboardingText
            appLog("Onboarding transcript updated: \"\(onboardingText)\"")
            return true
        }

        guard prepareTextDeliveryTarget() else { return false }
        keyboardInjector.typeText(text + " ")
        appLog("Typed: \"\(text)\"")
        return true
    }

    /// Clipboard-paste correction for terminal inline cleanup:
    /// Backspace what we typed, paste corrected text via Cmd+V, restore clipboard.
    private func applyClipboardPasteCorrection(finalText: String) {
        let typedCount = realtimeTerminalTypedText.count
        keyboardInjector.deleteBackward(count: typedCount)
        usleep(10_000) // 10ms for backspaces to settle
        pasteTextPreservingClipboard(finalText + " ")
    }

    private func pasteTextPreservingClipboard(_ text: String) {
        let savedClipboard = clipboardService.read()
        clipboardService.copy(text)
        usleep(10_000) // Give NSPasteboard a moment to settle before Cmd+V.
        keyboardInjector.sendCommandV()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            guard self.clipboardService.read() == text else { return }
            if let saved = savedClipboard {
                self.clipboardService.copy(saved)
            } else {
                self.clipboardService.clear()
            }
        }
    }

    /// When true, captures and restores the specific input field + window (not just the app).
    private var stickyFieldEnabled: Bool {
        !UserDefaults.standard.bool(forKey: "stickyFieldRestoreDisabled")
    }

    private func captureManualRecordingOrigin() {
        manualRecordingOriginApp = NSWorkspace.shared.frontmostApplication
        if stickyFieldEnabled, let pid = manualRecordingOriginApp?.processIdentifier {
            manualRecordingOriginElement = keyboardInjector.captureOriginElement(for: pid)
            if let element = manualRecordingOriginElement {
                manualRecordingOriginWindow = keyboardInjector.captureOriginWindow(for: element)
            }
        }
    }

    private func clearManualRecordingOrigin() {
        manualRecordingOriginApp = nil
        manualRecordingOriginElement = nil
        manualRecordingOriginWindow = nil
    }

    private func prepareTextDeliveryTarget() -> Bool {
        if !KeyboardInjector.hasAccessibilityPermission {
            appError("Cannot type — Accessibility permission not granted")
            KeyboardInjector.requestAccessibilityPermission()
            return false
        }
        if let originApp = manualRecordingOriginApp, !originApp.isTerminated {
            let currentApp = NSWorkspace.shared.frontmostApplication
            var didSwitchApp = false
            if currentApp?.processIdentifier != originApp.processIdentifier {
                originApp.activate()
                usleep(50_000)
                // Apple Events fallback for when standard activation fails (macOS 14+ with active input fields)
                if stickyFieldEnabled,
                   NSWorkspace.shared.frontmostApplication?.processIdentifier != originApp.processIdentifier,
                   let bundleId = originApp.bundleIdentifier {
                    let script = NSAppleScript(source: "tell application id \"\(bundleId)\" to activate")
                    script?.executeAndReturnError(nil)
                    var waited: UInt32 = 0
                    while NSWorkspace.shared.frontmostApplication?.processIdentifier != originApp.processIdentifier,
                          waited < 250_000 {
                        usleep(10_000)
                        waited += 10_000
                    }
                }
                didSwitchApp = true
                #if DEBUG
                let success = NSWorkspace.shared.frontmostApplication?.processIdentifier == originApp.processIdentifier
                print("[App] Re-activated \(originApp.localizedName ?? "app") for text delivery (success=\(success))")
                #endif
            }
            // Restore focus to the origin window + input field if it changed
            if stickyFieldEnabled, let originElement = manualRecordingOriginElement {
                let shouldRestore: Bool
                if didSwitchApp {
                    shouldRestore = true
                } else if let currentElement = keyboardInjector.captureOriginElement(for: originApp.processIdentifier),
                          !CFEqual(currentElement, originElement) {
                    shouldRestore = true
                } else {
                    shouldRestore = false
                }
                if shouldRestore {
                    if let originWindow = manualRecordingOriginWindow {
                        keyboardInjector.raiseOriginWindow(originWindow)
                    }
                    let restored = keyboardInjector.restoreOriginElement(originElement)
                    if restored {
                        usleep(20_000)
                    }
                    #if DEBUG
                    print("[App] Origin restore: window=\(manualRecordingOriginWindow != nil), element=\(restored ? "success" : "failed")")
                    #endif
                }
            }
        }
        return true
    }

    private func applyDirectRealtimeDelta(from currentText: String, to newText: String) -> Bool {
        guard prepareTextDeliveryTarget() else { return false }
        let applied = keyboardInjector.applyStreamingDelta(from: currentText, to: newText)
        if applied {
            realtimeUsingDirectTypingFallback = true
            realtimeUsingOverlayFallback = false
        } else {
            realtimeUsingOverlayFallback = true
        }
        return applied
    }

    func transcriptionDidFail(error: Error) {
        isTranscriptionInProgress = false
        if let txError = error as? TranscriptionError {
            if txError == .modelNotLoaded {
                appLog("Engine still loading — speech dropped")
                if let request = activeTranscriptionRequest,
                   Self.shouldRecordHistoryFailure(for: request.source) {
                    if let retryID = request.historyRetryID {
                        TranscriptionHistoryStore.shared.updateFailure(id: retryID, errorMessage: txError.localizedDescription)
                    } else {
                        recordHistoryFailure(
                            error: txError,
                            speechDuration: request.duration,
                            source: request.source,
                            request: request
                        )
                    }
                }
                processNextInQueue()
                return
            }
            if txError == .audioTooShort || txError == .noSpeechDetected {
                if let request = activeTranscriptionRequest {
                    if Self.shouldRetainAlwaysOnBatchCarryover(
                        source: request.source,
                        profile: request.speechTiming?.profile,
                        error: txError
                    ) {
                        appLog(
                            "Timing: asr-fail-retained source=\(request.source) id=\(request.id) " +
                            "profile=\(request.speechTiming?.profile.rawValue ?? "manual") " +
                            "reason=\(txError.localizedDescription) samples=\(request.samples.count)"
                        )
                        retainAlwaysOnBatchCarryover(from: request, reason: txError)
                        #if DEBUG
                        print("[App] Retaining transcription chunk for carryover rescue — \(txError.localizedDescription)")
                        #endif
                        processNextInQueue()
                        return
                    }
                    if let retryID = request.historyRetryID {
                        TranscriptionHistoryStore.shared.updateFailure(id: retryID, errorMessage: txError.localizedDescription)
                    } else if Self.shouldRecordHistoryFailure(for: request.source) {
                        recordHistoryFailure(
                            error: txError,
                            speechDuration: request.duration,
                            source: request.source,
                            request: request
                        )
                    }
                    appLog(
                        "Timing: dropped source=\(request.source) id=\(request.id) " +
                        "profile=\(request.speechTiming?.profile.rawValue ?? "manual") " +
                        "reason=\(txError.localizedDescription) speech_ms=\(Int(request.duration * 1000))"
                    )
                }
                #if DEBUG
                print("[App] Dropped transcription chunk — \(txError.localizedDescription)")
                #endif
                processNextInQueue()
                return
            }
        }

        if !(error is TranscriptionError) || (error as? TranscriptionError) != .alreadyTranscribing {
            appError("Transcription failed: \(error.localizedDescription)")
            trackEvent("errorOccurred", parameters: ["source": "transcription", "error": error.localizedDescription])
            // Record failure in history (with audio for retry)
            if let request = activeTranscriptionRequest {
                if let retryID = request.historyRetryID {
                    TranscriptionHistoryStore.shared.updateFailure(id: retryID, errorMessage: error.localizedDescription)
                } else if Self.shouldRecordHistoryFailure(for: request.source) {
                    recordHistoryFailure(
                        error: error,
                        speechDuration: request.duration,
                        source: request.source,
                        request: request
                    )
                }
            }
        }
        processNextInQueue()
    }

    private func processNextInQueue() {
        isTranscriptionInProgress = false
        activeTranscriptionRequest = nil
        if !pendingSpeechQueue.isEmpty {
            let next = pendingSpeechQueue.removeFirst()
            lastSpeechDuration = next.duration
            #if DEBUG
            print("[App] Processing queued speech (\(pendingSpeechQueue.count) remaining)")
            #endif
            appLog(
                "Timing: dequeued source=\(next.source) id=\(next.id) " +
                "profile=\(next.speechTiming?.profile.rawValue ?? "manual") " +
                "remaining=\(pendingSpeechQueue.count)"
            )
            submitTranscription(next)
        } else if isManualRecording {
            // Stay in .recording state while manual recording is active
            appState.currentState = .recording
        } else if ShortcutConfig.shared.recordingMode == .manual {
            // Manual mode: mic is off between recordings
            clearManualRecordingOrigin()
            appState.currentState = .idle
        } else {
            clearManualRecordingOrigin()
            appState.currentState = .listening
        }
    }
}

// MARK: - RealtimeParakeetServiceDelegate

extension AppDelegate: RealtimeParakeetServiceDelegate {
    func realtimeParakeetService(_ service: RealtimeParakeetService, didStartUtterance sessionID: Int) {
        guard service === realtimeParakeetService else {
            appLog("Timing: realtime-start-dropped engine=parakeet-realtime-tdt session=\(sessionID) reason=stale-service")
            return
        }
        let pendingBlocks: [[Float]]
        let deferredFinish = realtimePendingFinish
        realtimeAudioLock.lock()
        realtimeSessionID = sessionID
        realtimeStartInFlight = false
        pendingBlocks = realtimePendingAudioBlocks
        realtimePendingAudioBlocks.removeAll(keepingCapacity: false)
        realtimeAudioLock.unlock()
        realtimePendingFinish = nil

        let speechToStartMs: Int
        if let speechStart = realtimeSpeechStartDetectedAt {
            speechToStartMs = Int(Date().timeIntervalSince(speechStart) * 1000)
        } else {
            speechToStartMs = -1
        }
        logRealtimeDiagnostics(
            "session-started engine=\(TranscriptionEngineChoice.parakeetRealtimeTdt.rawValue) session=\(sessionID) " +
            "speech_to_start_ms=\(speechToStartMs) buffered_blocks=\(pendingBlocks.count) deferred_finish=\(deferredFinish != nil)"
        )

        Task {
            await self.realtimeOperationQueue.enqueue { [weak self] in
                guard let self else { return }
                for block in pendingBlocks {
                    await service.appendAudio(samples: block)
                }
                if let deferredFinish {
                    await MainActor.run {
                        self.realtimeEndpointDetectedAt = deferredFinish.endpointDetectedAt
                    }
                    await service.finishUtterance(
                        endpointSegment: deferredFinish.samples,
                        speechDuration: deferredFinish.duration
                    )
                }
            }
        }
    }

    func realtimeParakeetService(_ service: RealtimeParakeetService, didUpdatePartial update: RealtimePartialUpdate) {
        guard service === realtimeParakeetService else {
            appLog("Timing: partial-dropped session=\(update.sessionID) reason=stale-service")
            return
        }
        deliverRealtimePartial(update)
    }

    func realtimeParakeetService(_ service: RealtimeParakeetService, didFinishUtterance result: RealtimeUtteranceResult) {
        guard service === realtimeParakeetService else {
            appLog("Timing: final-dropped session=\(result.sessionID) reason=stale-service")
            return
        }
        guard matchesRealtimeCallbackSession(result.sessionID) else {
            appLog(
                "Timing: final-dropped session=\(result.sessionID) reason=stale-session active=\(activeRealtimeSessionLabel())"
            )
            return
        }
        // Unblock new sessions early — the session is done, don't hold the gate
        // while commitLiveText/typeText runs (usleep yields main run loop).
        clearRealtimeCallbackSession(result.sessionID)
        realtimeStartInFlight = false
        let rawWordCount = WordCounter.countWords(in: result.text)
        appLog(
            "Realtime transcription: \"\(result.text)\" (\(rawWordCount) words, mode=\(result.finalizationMode.rawValue), cleanup=\(result.usedCleanup))"
        )
        logRealtimeSessionSummary(
            outcome: "finish",
            engine: TranscriptionEngineChoice.parakeetRealtimeTdt.rawValue,
            sessionID: result.sessionID,
            finalTextChars: result.text.count,
            usedCleanup: result.usedCleanup
        )

        let source = ShortcutConfig.shared.recordingMode == .alwaysOn ? "vad" : (isToggleRecording ? "toggle" : "ptt")
        let realtimeCleanedText = (LLMCleanupService.isEnabled && LLMCleanupService.modelID == "regex")
            ? applyRegexFillerCleanup(result.text) : result.text
        let realtimeFinalText = applyITNIfEnabled(realtimeCleanedText)
        let finalWordCount = recordCompletedTranscriptionUsage(
            text: realtimeFinalText,
            transcriptionDuration: 0,
            speechDuration: result.speechDuration,
            analyticsDurationSeconds: result.speechDuration,
            source: source,
            engine: TranscriptionEngineChoice.parakeetRealtimeTdt.rawValue,
            mode: "realtime",
            finalization: result.finalizationMode.rawValue,
            cleanup: result.usedCleanup,
            terminal: realtimeTargetIsTerminal
        )
        recordHistorySuccess(
            text: realtimeFinalText,
            wordCount: finalWordCount,
            speechDuration: result.speechDuration,
            transcriptionDuration: 0,
            source: source
        )
        let delivered = commitLiveText(realtimeFinalText, sessionID: result.sessionID)
        if delivered, let endpointAt = realtimeEndpointDetectedAt {
            let totalStopToTextMs = Int(Date().timeIntervalSince(endpointAt) * 1000)
            appLog("Timing: text-injected source=realtime total_stop_to_text_ms=\(totalStopToTextMs)")
        } else if realtimeShouldSuppressFinalCommit {
            appLog("Timing: partial-fallback session=\(result.sessionID) reason=finalCommitSuppressed")
        }

        if ShortcutConfig.shared.recordingMode != .manual,
           !realtimeTargetIsTerminal,
           shouldShowPresetOverlay || realtimeUsingOverlayFallback {
            overlayPanel.show(status: .result(realtimeFinalText, wordCount: finalWordCount))
        }
        let shouldContinueManualStreaming = ShortcutConfig.shared.recordingMode == .manual &&
            (isManualRecording || isToggleRecording)
        if shouldContinueManualStreaming {
            appState.currentState = .recording
            logRealtimeDiagnostics(
                "manual-rearm-after-finish engine=\(TranscriptionEngineChoice.parakeetRealtimeTdt.rawValue) " +
                "session=\(result.sessionID) model_endpoint=false"
            )
            beginRealtimeUtterance(
                timing: makeManualRealtimeSpeechStartTiming(),
                preserveBufferedBlocks: true
            )
            return
        }
        if ShortcutConfig.shared.recordingMode == .alwaysOn {
            appState.currentState = .listening
        } else if ShortcutConfig.shared.recordingMode == .manual {
            clearManualRecordingOrigin()
            appState.currentState = .idle
        }
        if startDeferredRealtimeUtteranceIfNeeded() {
            return
        }
        resetRealtimeDeliveryState()
    }

    func realtimeParakeetService(_ service: RealtimeParakeetService, didFail error: Error, sessionID: Int?) {
        guard service === realtimeParakeetService else {
            appLog("Timing: realtime-fail-dropped session=\(sessionID.map(String.init) ?? "unknown") reason=stale-service")
            return
        }
        if let sessionID, !matchesRealtimeCallbackSession(sessionID) {
            appLog(
                "Timing: realtime-fail-dropped session=\(sessionID) reason=stale-session active=\(activeRealtimeSessionLabel())"
            )
            return
        }
        // Unblock new sessions early.
        clearRealtimeCallbackSession(sessionID)
        realtimeStartInFlight = false
        appError("Realtime Parakeet failed: \(error.localizedDescription)")
        appLog("Timing: realtime-fail session=\(sessionID.map(String.init) ?? "unknown") reason=\(error.localizedDescription)")
        if let sessionID {
            logRealtimeSessionSummary(
                outcome: "error",
                engine: TranscriptionEngineChoice.parakeetRealtimeTdt.rawValue,
                sessionID: sessionID,
                finalTextChars: 0,
                error: error.localizedDescription
            )
        } else {
            logRealtimeDiagnostics(
                "session-summary outcome=error engine=\(TranscriptionEngineChoice.parakeetRealtimeTdt.rawValue) session=unknown error=\(error.localizedDescription)",
                level: .error
            )
        }
        trackEvent("errorOccurred", parameters: [
            "source": "realtimeParakeet",
            "error": error.localizedDescription,
        ])

        // Don't show internal state errors in the overlay — they're benign race conditions.
        if !(error is RealtimeParakeetServiceError),
           realtimeDeferredStartTiming == nil,
           !realtimeTargetIsTerminal,
           shouldShowPresetOverlay || realtimeUsingOverlayFallback {
            overlayPanel.show(status: .error(error.localizedDescription))
        }
        if startDeferredRealtimeUtteranceIfNeeded() {
            return
        }
        resetRealtimeDeliveryState()
        if ShortcutConfig.shared.recordingMode == .alwaysOn {
            appState.currentState = .listening
        } else if ShortcutConfig.shared.recordingMode == .manual {
            clearManualRecordingOrigin()
            appState.currentState = .idle
        }
    }
}

private extension AppDelegate {
    func handleRealtimeEouDidStart(sessionID: Int) {
        let pendingBlocks: [[Float]]
        let deferredFinish = realtimePendingFinish
        realtimeAudioLock.lock()
        realtimeSessionID = sessionID
        realtimeStartInFlight = false
        pendingBlocks = realtimePendingAudioBlocks
        realtimePendingAudioBlocks.removeAll(keepingCapacity: false)
        realtimeAudioLock.unlock()
        realtimePendingFinish = nil

        let speechToStartMs: Int
        if let speechStart = realtimeSpeechStartDetectedAt {
            speechToStartMs = Int(Date().timeIntervalSince(speechStart) * 1000)
        } else {
            speechToStartMs = -1
        }
        logRealtimeDiagnostics(
            "session-started engine=\(TranscriptionEngineChoice.parakeetEou.rawValue) session=\(sessionID) " +
            "speech_to_start_ms=\(speechToStartMs) buffered_blocks=\(pendingBlocks.count) deferred_finish=\(deferredFinish != nil)"
        )

        Task {
            await self.realtimeOperationQueue.enqueue { [weak self] in
                guard let self else { return }
                for block in pendingBlocks {
                    await self.appendRealtimeEouTransport(samples: block)
                }
                if let deferredFinish {
                    await MainActor.run {
                        self.realtimeEndpointDetectedAt = deferredFinish.endpointDetectedAt
                    }
                    await self.finishRealtimeEouTransport(
                        segment: AudioSegment(
                            samples: deferredFinish.samples,
                            sampleRate: 16000,
                            timestamp: deferredFinish.endpointDetectedAt
                        )
                    )
                }
            }
        }
    }

    func handleRealtimeEouDidUpdate(_ update: RealtimePartialUpdate) {
        deliverRealtimePartial(update)
    }

    func handleRealtimeEouDidFinish(_ result: RealtimeEouUtteranceResult) {
        guard matchesRealtimeCallbackSession(result.sessionID) else {
            appLog(
                "Timing: final-dropped session=\(result.sessionID) reason=stale-session active=\(activeRealtimeSessionLabel())"
            )
            return
        }

        clearRealtimeCallbackSession(result.sessionID)
        realtimeStartInFlight = false

        let rawWordCount = WordCounter.countWords(in: result.text)
        appLog(
            "Realtime EOU transcription: \"\(result.text)\" (\(rawWordCount) words, mode=\(result.finalizationMode.rawValue), cleanup=\(result.usedCleanup), model_endpoint=\(result.usedModelEndpoint))"
        )
        logRealtimeSessionSummary(
            outcome: "finish",
            engine: TranscriptionEngineChoice.parakeetEou.rawValue,
            sessionID: result.sessionID,
            finalTextChars: result.text.count,
            usedCleanup: result.usedCleanup,
            modelEndpoint: result.usedModelEndpoint
        )

        let eouSource = ShortcutConfig.shared.recordingMode == .alwaysOn ? "vad" : (isToggleRecording ? "toggle" : "ptt")
        let isDeferredCleanup = terminalInlineCleanupMode == .deferredCleanup
            && realtimeTargetIsTerminal
            && result.usedCleanup
            && result.text != result.streamText
        let isInlineCleanup = terminalInlineCleanupMode == .inlineCleanup
        let committedStreamText: String?
        if isDeferredCleanup {
            realtimeTerminalDeferredStreamText = result.streamText
            committedStreamText = realtimeTerminalTypedText.isEmpty ? nil : realtimeTerminalTypedText
        } else {
            realtimeTerminalDeferredStreamText = nil
            committedStreamText = nil
        }

        let eouRawText = (isDeferredCleanup || isInlineCleanup) ? result.streamText : result.text
        let eouCleanedText = (LLMCleanupService.isEnabled && LLMCleanupService.modelID == "regex")
            ? applyRegexFillerCleanup(eouRawText) : eouRawText
        let textToCommit = applyITNIfEnabled(eouCleanedText)
        let finalWordCount = recordCompletedTranscriptionUsage(
            text: textToCommit,
            transcriptionDuration: 0,
            speechDuration: result.speechDuration,
            analyticsDurationSeconds: result.speechDuration,
            source: eouSource,
            engine: TranscriptionEngineChoice.parakeetEou.rawValue,
            mode: "realtime",
            finalization: result.finalizationMode.rawValue,
            cleanup: result.usedCleanup,
            terminal: realtimeTargetIsTerminal,
            additionalParameters: [
                "shadowCleanup": realtimeShadowCleanupMode.rawValue,
                "modelEndpoint": result.usedModelEndpoint,
            ]
        )
        recordHistorySuccess(
            text: textToCommit,
            wordCount: finalWordCount,
            speechDuration: result.speechDuration,
            transcriptionDuration: 0,
            source: eouSource
        )
        let delivered = commitLiveText(textToCommit, sessionID: result.sessionID)
        if delivered, let endpointAt = realtimeEndpointDetectedAt {
            let totalStopToTextMs = Int(Date().timeIntervalSince(endpointAt) * 1000)
            appLog("Timing: text-injected source=realtime-eou total_stop_to_text_ms=\(totalStopToTextMs)")
        } else if realtimeShouldSuppressFinalCommit {
            appLog("Timing: partial-fallback session=\(result.sessionID) reason=finalCommitSuppressed")
        }

        if isDeferredCleanup, delivered {
            let cleanupText = result.text
            let committedText = committedStreamText.map { commitText in
                let streamText = result.streamText
                if streamText.hasPrefix(commitText) {
                    return streamText
                }
                return streamText
            } ?? result.streamText
            appLog("Deferred cleanup scheduled: stream=\"\(committedText)\" cleanup=\"\(cleanupText)\"")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                guard !self.realtimeStreamingArmed else {
                    appLog("Deferred cleanup skipped: new speech started")
                    return
                }
                let applied = self.keyboardInjector.applyStreamingDelta(
                    from: committedText + " ",
                    to: cleanupText + " "
                )
                if applied {
                    appLog("Deferred cleanup applied: \"\(cleanupText)\"")
                } else {
                    appLog("Deferred cleanup failed: backspace delta could not be applied")
                }
            }
        }

        let rtMode = realtimeLLMCleanupMode
        if rtMode == .deferredLLM, delivered, LLMCleanupService.isEnabled, LLMCleanupService.modelID != "regex" {
            let rawCommitted = textToCommit
            appLog("Realtime LLM deferred cleanup scheduled")
            Task { [weak self] in
                guard let self else { return }
                let llmCleaned = await LLMCleanupService.shared.cleanup(rawCommitted)
                let finalCleaned = self.applyITNIfEnabled(llmCleaned)
                let inWords = rawCommitted.split(separator: " ").count
                let outWords = finalCleaned.split(separator: " ").count
                guard outWords <= inWords else {
                    print("[RealtimeLLM] Deferred rejected: output has more words (\(outWords) vs \(inWords))")
                    return
                }
                guard finalCleaned != rawCommitted else { return }
                await MainActor.run {
                    let applied = self.keyboardInjector.applyStreamingDelta(
                        from: rawCommitted + " ",
                        to: finalCleaned + " "
                    )
                    print("[RealtimeLLM] Deferred cleanup \(applied ? "applied" : "failed"): \"\(finalCleaned)\"")
                }
            }
        } else if (rtMode == .shadowLLM || rtMode == .sentenceLLM), delivered, LLMCleanupService.isEnabled, LLMCleanupService.modelID != "regex" {
            let rawCommitted = textToCommit
            let runner = realtimeLLMShadowRunner
            let chunker = realtimeSentenceChunker
            let completion: (String) -> Void = { [weak self] finalText in
                guard let self else { return }
                let cleaned = self.applyITNIfEnabled(finalText)
                let inWords = rawCommitted.split(separator: " ").count
                let outWords = cleaned.split(separator: " ").count
                guard outWords <= inWords else {
                    print("[RealtimeLLM] Final cleanup rejected: output has more words (\(outWords) vs \(inWords))")
                    return
                }
                guard cleaned != rawCommitted else { return }
                let applied = self.keyboardInjector.applyStreamingDelta(from: rawCommitted + " ", to: cleaned + " ")
                print("[RealtimeLLM] Final cleanup \(applied ? "applied" : "failed")")
            }
            runner?.finalCleanup(rawCommitted, completion: completion)
            chunker?.finalCleanup(rawCommitted, completion: completion)
        } else {
            realtimeLLMShadowRunner?.reset()
            realtimeSentenceChunker?.reset()
        }

        if ShortcutConfig.shared.recordingMode != .manual,
           !realtimeTargetIsTerminal,
           shouldShowPresetOverlay || realtimeUsingOverlayFallback {
            overlayPanel.show(status: .result(textToCommit, wordCount: finalWordCount))
        }
        let shouldContinueManualStreaming = ShortcutConfig.shared.recordingMode == .manual &&
            (isManualRecording || isToggleRecording)
        if shouldContinueManualStreaming {
            appState.currentState = .recording
            logRealtimeDiagnostics(
                "manual-rearm-after-finish engine=\(TranscriptionEngineChoice.parakeetEou.rawValue) " +
                "session=\(result.sessionID) model_endpoint=\(result.usedModelEndpoint)"
            )
            beginRealtimeUtterance(
                timing: makeManualRealtimeSpeechStartTiming(),
                preserveBufferedBlocks: true
            )
            return
        }
        if ShortcutConfig.shared.recordingMode == .alwaysOn {
            appState.currentState = .listening
        } else if ShortcutConfig.shared.recordingMode == .manual {
            clearManualRecordingOrigin()
            appState.currentState = .idle
        }
        if startDeferredRealtimeUtteranceIfNeeded() {
            return
        }
        resetRealtimeDeliveryState()
    }

    func handleRealtimeEouDidFail(_ error: Error, sessionID: Int?) {
        if let sessionID, !matchesRealtimeCallbackSession(sessionID) {
            appLog(
                "Timing: realtime-eou-fail-dropped session=\(sessionID) reason=stale-session active=\(activeRealtimeSessionLabel())"
            )
            return
        }

        clearRealtimeCallbackSession(sessionID)
        realtimeStartInFlight = false

        appError("Realtime Parakeet EOU failed: \(error.localizedDescription)")
        appLog("Timing: realtime-eou-fail session=\(sessionID.map(String.init) ?? "unknown") reason=\(error.localizedDescription)")
        if let sessionID {
            logRealtimeSessionSummary(
                outcome: "error",
                engine: TranscriptionEngineChoice.parakeetEou.rawValue,
                sessionID: sessionID,
                finalTextChars: 0,
                error: error.localizedDescription
            )
        } else {
            logRealtimeDiagnostics(
                "session-summary outcome=error engine=\(TranscriptionEngineChoice.parakeetEou.rawValue) session=unknown error=\(error.localizedDescription)",
                level: .error
            )
        }
        trackEvent("errorOccurred", parameters: [
            "source": "realtimeParakeetEou",
            "error": error.localizedDescription,
        ])

        // Don't show internal state errors in the overlay — they're benign race conditions.
        if !(error is RealtimeParakeetServiceError),
           realtimeDeferredStartTiming == nil,
           !realtimeTargetIsTerminal,
           shouldShowPresetOverlay || realtimeUsingOverlayFallback {
            overlayPanel.show(status: .error(error.localizedDescription))
        }
        if startDeferredRealtimeUtteranceIfNeeded() {
            return
        }
        resetRealtimeDeliveryState()
        if ShortcutConfig.shared.recordingMode == .alwaysOn {
            appState.currentState = .listening
        } else if ShortcutConfig.shared.recordingMode == .manual {
            clearManualRecordingOrigin()
            appState.currentState = .idle
        }
    }
}

// MARK: - RealtimeEouServiceDelegate

extension AppDelegate: RealtimeEouServiceDelegate {
    func realtimeEouService(_ service: RealtimeEouService, didStartUtterance sessionID: Int) {
        guard service === realtimeEouService else {
            appLog("Timing: realtime-start-dropped engine=parakeet-eou session=\(sessionID) reason=stale-service")
            return
        }
        handleRealtimeEouDidStart(sessionID: sessionID)
    }

    func realtimeEouService(_ service: RealtimeEouService, didUpdatePartial update: RealtimePartialUpdate) {
        guard service === realtimeEouService else {
            appLog("Timing: partial-dropped session=\(update.sessionID) reason=stale-service")
            return
        }
        handleRealtimeEouDidUpdate(update)
    }

    func realtimeEouService(_ service: RealtimeEouService, didFinishUtterance result: RealtimeEouUtteranceResult) {
        guard service === realtimeEouService else {
            appLog("Timing: final-dropped session=\(result.sessionID) reason=stale-service")
            return
        }
        handleRealtimeEouDidFinish(result)
    }

    func realtimeEouService(_ service: RealtimeEouService, didFail error: Error, sessionID: Int?) {
        guard service === realtimeEouService else {
            appLog("Timing: realtime-eou-fail-dropped session=\(sessionID.map(String.init) ?? "unknown") reason=stale-service")
            return
        }
        handleRealtimeEouDidFail(error, sessionID: sessionID)
    }
}

// MARK: - HotkeyDelegate

extension AppDelegate: HotkeyDelegate {
    func hotkeyDidTrigger() {
        #if DEBUG
        print("[App] Action hotkey — no effect in always-on mode")
        #endif
    }

    func hotkeyDidRelease() {}

    func micToggleDidTrigger() {
        triggerMicToggleShortcut(source: "hotkey")
    }

    func llmCleanupToggleDidTrigger() {
        triggerLLMCleanupToggleShortcut(source: "hotkey")
    }

}

// MARK: - GlobalShortcutDelegate

extension AppDelegate: GlobalShortcutDelegate {
    func isToggleRecordingActiveForShortcuts() -> Bool {
        isToggleRecording
    }

    private func logManualStartDiagnostic(_ kind: ManualRecordingActivationKind) {
        let source: String
        switch kind {
        case .ptt:
            source = "ptt"
        case .toggle:
            source = "toggle"
        }

        let path = audioCapture.isRunning ? "hot-start" : "cold-start"
        appLog(
            "Timing: \(source)-\(path) " +
            "capture_running=\(audioCapture.isRunning) " +
            "keep_mic_ready=\(keepMicReady) " +
            "capture_policy_warm=\(shouldKeepCaptureRunningBetweenManualPresses) " +
            "overlay=\(overlayPanel.startupDiagnosticSummary)"
        )
    }

    private func invalidatePendingManualRecordingActivation() {
        manualRecordingActivationGeneration &+= 1
    }

    private func scheduleManualRecordingActivation(_ kind: ManualRecordingActivationKind) {
        manualRecordingActivationGeneration &+= 1
        let generation = manualRecordingActivationGeneration
        overlayPanel.show(status: .arming)

        DispatchQueue.main.async { [weak self] in
            self?.activateManualRecordingIfNeeded(kind, generation: generation)
        }
    }

    private func activateManualRecordingIfNeeded(_ kind: ManualRecordingActivationKind, generation: UInt) {
        guard manualRecordingActivationGeneration == generation else { return }
        guard ShortcutConfig.shared.recordingMode == .manual else { return }
        guard isManualRecording else { return }

        switch kind {
        case .ptt:
            guard !isToggleRecording else { return }
        case .toggle:
            guard isToggleRecording else { return }
        }

        if !audioCapture.isRunning {
            audioCapture.start()
        }

        guard manualRecordingActivationGeneration == generation else { return }
        guard audioCapture.isRunning else {
            failManualRecordingActivation()
            return
        }

        completeManualRecordingActivation(kind)
    }

    private func completeManualRecordingActivation(_ kind: ManualRecordingActivationKind) {
        switch kind {
        case .ptt:
            audioCapture.markRecordingStart()
        case .toggle:
            audioCapture.beginToggleRecording()
        }

        if selectedTranscriptionPreset.usesRealtimeEngine {
            beginRealtimeUtterance(timing: makeManualRealtimeSpeechStartTiming())
        }

        appState.currentState = .recording
        overlayPanel.show(status: .recording)

        switch kind {
        case .ptt:
            trackEvent("recordingStarted", parameters: [
                "type": "ptt",
                "shortcut": globalShortcutMonitor.pttShortcut.displayString,
            ])
            #if DEBUG
            print("[App] PTT recording started")
            #endif
        case .toggle:
            scheduleToggleTimers()
            trackEvent("recordingStarted", parameters: [
                "type": "toggle",
                "shortcut": globalShortcutMonitor.toggleShortcut.displayString,
            ])
            #if DEBUG
            print("[App] Toggle recording started (disk-backed)")
            #endif
        }

        // Only prewarm when cleanup is actively using a cloud model.
        if Self.shouldPrewarmLLMCleanupConnection(
            isCleanupEnabled: LLMCleanupService.isEnabled,
            cleanupModelID: LLMCleanupService.modelID
        ) {
            LLMCleanupService.shared.warmAPIConnection()
        }
    }

    private func failManualRecordingActivation() {
        isManualRecording = false
        isToggleRecording = false
        clearManualRecordingOrigin()
        resetRealtimeDeliveryState()
        Task { [weak self] in
            await self?.cancelRealtimeStreamingUtterances()
        }

        if case .error = appState.currentState {
            return
        }

        appState.currentState = .idle
        overlayPanel.show(status: .idle)
    }

    func modeToggleDidTrigger() {
        // Practice teaches one recording gesture; a double press must not silently
        // switch a new user into hands-free capture.
        guard UserDefaults.standard.bool(forKey: "hasCompletedOnboarding"),
              !viewModel.isOnboardingPreviewActive else { return }
        guard Self.shouldAllowModeToggle(
            isManualRecording: isManualRecording,
            isToggleRecording: isToggleRecording,
            isPTTShortcutHeld: globalShortcutMonitor.isPTTActive
        ) else {
            let reason = isToggleRecording ? "toggle recording active" : "manual=\(isManualRecording) pttHeld=\(globalShortcutMonitor.isPTTActive)"
            appLog("[ModeToggle] Blocked — \(reason)")
            return
        }
        let current = ShortcutConfig.shared.recordingMode
        let newMode: RecordingMode = (current == .alwaysOn) ? .manual : .alwaysOn
        switchRecordingMode(newMode)
        trackEvent("modeToggleUsed", parameters: ["newMode": newMode.rawValue])
        if shouldShowPresetOverlay {
            let label = newMode == .alwaysOn ? "Always-on mode" : "Manual mode"
            overlayPanel.show(status: .error(label))
        }
        #if DEBUG
        print("[App] Mode toggled → \(newMode.rawValue)")
        #endif
    }

    func pttDidPress() {
        guard ShortcutConfig.shared.recordingMode == .manual else { return }
        guard !isManualRecording else { return }
        guard transcriptionService.isReady else {
            #if DEBUG
            print("[App] PTT ignored — engine not ready")
            #endif
            if shouldShowPresetOverlay { overlayPanel.show(status: .error("Engine still loading…")) }
            return
        }

        captureManualRecordingOrigin()
        isManualRecording = true
        isToggleRecording = false
        logManualStartDiagnostic(.ptt)
        if audioCapture.isRunning {
            completeManualRecordingActivation(.ptt)
        } else {
            scheduleManualRecordingActivation(.ptt)
        }
    }

    func pttDidRelease() {
        guard isManualRecording, !isToggleRecording else { return }
        finishManualRecording()
    }

    func pttDidCancel() {
        guard isManualRecording, !isToggleRecording else { return }
        invalidatePendingManualRecordingActivation()
        isManualRecording = false
        clearManualRecordingOrigin()
        audioCapture.cancelManualRecording()
        audioCapture.cancelToggleRecording()
        cancelToggleTimers()
        resetRealtimeDeliveryState()
        Task { [weak self] in
            await self?.cancelRealtimeStreamingUtterances()
        }
        if !shouldKeepCaptureRunningBetweenManualPresses { audioCapture.stop() }
        appState.currentState = .idle
        // The only current cancel path is fn+Space handing off from PTT into toggle.
        // Avoid flashing idle overlay for a transition that continues immediately.
        #if DEBUG
        print("[App] PTT cancelled (toggle override)")
        #endif
    }

    func pttDidWarnTimeout(remainingSeconds: Int) {
        overlayPanel.show(status: .error("\(remainingSeconds)s left — recording limit approaching"))
    }

    func toggleDidPress() {
        guard ShortcutConfig.shared.recordingMode == .manual else { return }
        guard !isManualRecording || isToggleRecording else {
            // PTT is active — ignore toggle
            #if DEBUG
            print("[App] Toggle ignored — PTT active")
            #endif
            return
        }

        if isToggleRecording {
            // Stop toggle recording
            cancelToggleTimers()
            finishToggleRecording()
        } else {
            // Start toggle recording
            guard transcriptionService.isReady else {
                #if DEBUG
                print("[App] Toggle ignored — engine not ready")
                #endif
                if shouldShowPresetOverlay { overlayPanel.show(status: .error("Engine still loading…")) }
                return
            }
            captureManualRecordingOrigin()
            isManualRecording = true
            isToggleRecording = true
            logManualStartDiagnostic(.toggle)
            if audioCapture.isRunning {
                completeManualRecordingActivation(.toggle)
            } else {
                scheduleManualRecordingActivation(.toggle)
            }
        }
    }

    private func finishManualRecording() {
        invalidatePendingManualRecordingActivation()
        // Make key-up feel immediate; audio tail flush can continue invisibly.
        overlayPanel.hideImmediately()
        guard let recording = audioCapture.extractManualRecording() else {
            #if DEBUG
            print("[App] Manual recording too short or invalid — dropped")
            #endif
            isManualRecording = false
            isToggleRecording = false
            resetRealtimeDeliveryState()
            Task { [weak self] in
                await self?.cancelRealtimeStreamingUtterances()
            }
            if !shouldKeepCaptureRunningBetweenManualPresses { audioCapture.stop() }
            appState.currentState = .idle
            overlayPanel.show(status: .idle)
            return
        }

        if selectedTranscriptionPreset.usesRealtimeEngine {
            let segment = AudioSegment(samples: recording.samples, sampleRate: 16000, timestamp: Date())
            let timing = makeManualRealtimeSegmentTiming(duration: recording.duration)
            lastSpeechDuration = recording.duration
            if !shouldKeepCaptureRunningBetweenManualPresses { audioCapture.stop() }
            appState.currentState = .transcribing
            finishRealtimeUtterance(segment: segment, timing: timing)
            isManualRecording = false
            isToggleRecording = false
            return
        }

        isManualRecording = false
        isToggleRecording = false
        if !shouldKeepCaptureRunningBetweenManualPresses { audioCapture.stop() }

        lastSpeechDuration = recording.duration
        appState.currentState = .transcribing
        #if DEBUG
        print("[App] Transcribing manual recording (\(String(format: "%.1f", recording.duration))s)...")
        #endif
        enqueueTranscription(
            makePendingTranscriptionRequest(
                samples: recording.samples,
                duration: recording.duration,
                source: "ptt",
                speechTiming: nil,
                enqueuedAt: Date()
            )
        )
    }

    private func finishToggleRecording() {
        invalidatePendingManualRecordingActivation()
        guard isToggleRecording else { return }
        // Make key-up feel immediate; audio tail flush can continue invisibly.
        overlayPanel.hideImmediately()
        guard let recording = audioCapture.extractToggleRecordingResult(retainExtractedFile: true) else {
            #if DEBUG
            print("[App] Toggle recording too short or invalid — dropped")
            #endif
            isManualRecording = false
            isToggleRecording = false
            resetRealtimeDeliveryState()
            Task { [weak self] in
                await self?.cancelRealtimeStreamingUtterances()
            }
            if !shouldKeepCaptureRunningBetweenManualPresses { audioCapture.stop() }
            appState.currentState = .idle
            overlayPanel.show(status: .idle)
            return
        }

        if selectedTranscriptionPreset.usesRealtimeEngine {
            let segment = AudioSegment(samples: recording.samples, sampleRate: 16000, timestamp: Date())
            let timing = makeManualRealtimeSegmentTiming(duration: recording.duration)
            lastSpeechDuration = recording.duration
            if !shouldKeepCaptureRunningBetweenManualPresses { audioCapture.stop() }
            appState.currentState = .transcribing
            finishRealtimeUtterance(segment: segment, timing: timing)
            isManualRecording = false
            isToggleRecording = false
            return
        }

        isManualRecording = false
        isToggleRecording = false
        if !shouldKeepCaptureRunningBetweenManualPresses { audioCapture.stop() }

        lastSpeechDuration = recording.duration
        appState.currentState = .transcribing
        #if DEBUG
        print("[App] Transcribing toggle recording (\(String(format: "%.1f", recording.duration))s)...")
        #endif
        enqueueTranscription(
            makePendingTranscriptionRequest(
                samples: recording.samples,
                duration: recording.duration,
                source: "toggle",
                speechTiming: nil,
                enqueuedAt: Date(),
                retainedAudio: recording.retainedFileURL.map { .temporaryFile($0) }
            )
        )
    }

    // MARK: - Toggle Recording Timers

    private func scheduleToggleTimers() {
        cancelToggleTimers()

        #if DEBUG
        let useShortTimers = isDebugShortToggleTimersEnabled
        let warningDelay: TimeInterval = useShortTimers ? 15 : 540
        let autoStopDelay: TimeInterval = useShortTimers ? 30 : 600
        let warningLabel = useShortTimers ? "15s left — recording limit approaching" : "1 min left — recording limit approaching"
        let limitLabel = useShortTimers ? "Recording limit reached (30s)" : "Recording limit reached (10 min)"
        #else
        let warningDelay: TimeInterval = 540
        let autoStopDelay: TimeInterval = 600
        let warningLabel = "1 min left — recording limit approaching"
        let limitLabel = "Recording limit reached (10 min)"
        #endif

        let warningItem = DispatchWorkItem { [weak self] in
            guard let self, self.isToggleRecording else { return }
            self.overlayPanel.showToast(warningLabel)
            #if DEBUG
            print("[App] Toggle recording — warning shown at \(Int(warningDelay))s")
            #endif
        }
        toggleWarningWorkItem = warningItem
        DispatchQueue.main.asyncAfter(deadline: .now() + warningDelay, execute: warningItem)

        let autoStopItem = DispatchWorkItem { [weak self] in
            guard let self, self.isToggleRecording else { return }
            #if DEBUG
            print("[App] Toggle recording — limit reached at \(Int(autoStopDelay))s, auto-stopping")
            #endif
            self.overlayPanel.show(status: .error(limitLabel))
            self.cancelToggleTimers()
            self.finishToggleRecording()
        }
        toggleAutoStopWorkItem = autoStopItem
        DispatchQueue.main.asyncAfter(deadline: .now() + autoStopDelay, execute: autoStopItem)
    }

    private func cancelToggleTimers() {
        toggleWarningWorkItem?.cancel()
        toggleWarningWorkItem = nil
        toggleAutoStopWorkItem?.cancel()
        toggleAutoStopWorkItem = nil
        overlayPanel.dismissToast()
    }

    // MARK: - History Recording

    private func recordHistorySuccess(
        text: String,
        wordCount: Int,
        speechDuration: Double,
        transcriptionDuration: Double,
        source: String
    ) {
        let id = UUID()

        let record = TranscriptionRecord(
            id: id,
            text: text,
            timestamp: Date(),
            speechDuration: speechDuration,
            transcriptionDuration: transcriptionDuration,
            recordingMode: ShortcutConfig.shared.recordingMode.rawValue,
            source: source,
            wordCount: wordCount,
            succeeded: true,
            audioFileName: nil
        )
        TranscriptionHistoryStore.shared.insert(record)
    }

    private func recordHistoryFailure(
        error: Error,
        speechDuration: Double,
        source: String,
        request: PendingTranscriptionRequest
    ) {
        let id = UUID()
        let audioFileName = materializeAudioFileNameForFailure(request: request, historyID: id)

        // Don't clutter history with failures that have no audio — nothing the user can do with them.
        guard audioFileName != nil else { return }

        let record = TranscriptionRecord(
            id: id,
            text: "",
            timestamp: Date(),
            speechDuration: speechDuration,
            transcriptionDuration: 0,
            recordingMode: ShortcutConfig.shared.recordingMode.rawValue,
            source: source,
            wordCount: 0,
            succeeded: false,
            errorMessage: error.localizedDescription,
            audioFileName: audioFileName
        )
        TranscriptionHistoryStore.shared.insert(record)
    }

    func retryTranscription(id: UUID) {
        #if DEBUG
        print("[App] retryTranscription called for \(id)")
        #endif
        guard let record = TranscriptionHistoryStore.shared.entry(for: id) else {
            #if DEBUG
            print("[App] Retry — record not found for \(id)")
            #endif
            return
        }

        guard let audioFile = record.audioFileName,
              let samples = TranscriptionHistoryStore.shared.loadAudio(fileName: audioFile) else {
            #if DEBUG
            print("[App] Retry — audio gone (fileName=\(record.audioFileName ?? "nil")), deleting entry")
            #endif
            TranscriptionHistoryStore.shared.deleteEntry(id: id)
            NotificationCenter.default.post(name: .transcriptionHistoryDidChange, object: nil)
            return
        }

        #if DEBUG
        print("[App] Retry — enqueuing \(samples.count) samples for \(id)")
        #endif
        let duration = Double(samples.count) / 16000.0
        enqueueTranscription(
            makePendingTranscriptionRequest(
                samples: samples,
                duration: duration,
                source: "retry",
                speechTiming: nil,
                enqueuedAt: Date(),
                retainedAudio: .cachedFile(audioFile),
                historyRetryID: id
            )
        )
    }
}
