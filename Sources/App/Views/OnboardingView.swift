import SwiftUI
import AVFoundation
import HotkeyModule

// MARK: - Main Onboarding Router

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(AppViewModel.self) private var viewModel
    @State private var currentStep = 0

    private let totalSteps = 4
    private var isFinalStep: Bool { currentStep >= totalSteps - 1 }

    var body: some View {
        ZStack {
            Color.btBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar: step indicator + skip
                HStack {
                    StepIndicator(current: currentStep, total: totalSteps)
                    Spacer()
                    // The final step has its own "I'll try later".
                    if !isFinalStep {
                        Button(viewModel.isOnboardingPreviewActive ? "Back to Dictate" : "Set up later") { completeOnboarding(event: "onboardingSkipped", params: ["atStep": currentStep]) }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.btSecondaryText)
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, BTSpacing.xl)
                .padding(.top, BTSpacing.lg)

                ScrollView {
                Group {
                    switch currentStep {
                    case 0: WelcomeStep(onContinue: advanceStep)
                    case 1: SetupStep(onContinue: advanceStep)
                    case 2: TryItStep(onContinue: advanceStep)
                    default: TryAnywhereStep(onFinish: { launchAtLogin, triedAnywhere in
                        LaunchAtLoginService.apply(launchAtLogin)
                        completeOnboarding(event: "onboardingCompleted", params: [
                            "triedAnywhere": triedAnywhere,
                            "launchAtLogin": launchAtLogin,
                        ])
                    })
                    }
                }
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .padding(.vertical, BTSpacing.lg)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if viewModel.isOnboardingPreviewActive {
                currentStep = viewModel.isSpeechEngineReady && !viewModel.isEngineLoading
                    && viewModel.isAccessibilityGranted && viewModel.isMicrophoneGranted ? 2 : 1
            }
        }
    }

    private func advanceStep() {
        currentStep += 1
    }

    private func completeOnboarding(event: String, params: [String: Any]) {
        viewModel.onTrackOnboardingEvent?(event, params)
        viewModel.isPracticeDictationActive = false
        viewModel.isOnboardingPreviewActive = false
        viewModel.onCloseOnboardingPreview?()
        hasCompletedOnboarding = true
    }
}

// MARK: - Step 0: Welcome

private struct WelcomeStep: View {
    let onContinue: () -> Void
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        VStack(spacing: BTSpacing.lg) {
            AnimatedWaveform()
                .frame(width: 80, height: 56)
                .btStaggered(index: 0)

            VStack(spacing: BTSpacing.sm) {
                Text("Blazing Transcribe")
                    .font(.btTitle)
                    .foregroundStyle(Color.btText)
                    .btStaggered(index: 1)

                Text("Turn your voice into text in any app.")
                    .font(.btBody)
                    .foregroundStyle(Color.btSecondaryText)
                    .btStaggered(index: 2)
            }

            BTButton("Get Started") {
                onContinue()
            }
            .btStaggered(index: 3)
        }
        .padding(BTSpacing.xl)
        .onAppear {
            viewModel.onTrackOnboardingEvent?("onboardingStep0Viewed", [:])
        }
    }
}

// MARK: - Step 1: Setup (self-checking checklist)

private struct SetupStep: View {
    let onContinue: () -> Void
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var hasRequestedMicrophone = false
    @State private var hasRequestedAccessibility = false

    private var microphoneAuthorization: SetupChecklist.MicrophoneAuthorization {
        if viewModel.isMicrophoneGranted { return .granted }
        switch microphoneStatus {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    private var microphoneRow: SetupChecklist.Row {
        SetupChecklist.microphone(
            authorization: microphoneAuthorization,
            hasRequested: hasRequestedMicrophone,
            hasPermissionError: viewModel.isMicrophonePermissionError
        )
    }

    private var accessibilityRow: SetupChecklist.Row {
        SetupChecklist.accessibility(
            granted: viewModel.isAccessibilityGranted,
            hasRequested: hasRequestedAccessibility
        )
    }

    private var modelRow: SetupChecklist.Row {
        SetupChecklist.speechModel(
            isReady: viewModel.isSpeechEngineReady,
            isLoading: viewModel.isEngineLoading,
            isDownloadPending: viewModel.isCurrentEngineDownloadPending,
            downloadFraction: viewModel.modelDownloadFraction,
            completedBytes: viewModel.currentEngineDownloadCompletedBytes,
            totalBytes: viewModel.currentEngineDownloadTotalBytes,
            errorMessage: viewModel.modelLoadErrorMessage,
            isRetryScheduled: viewModel.isModelDownloadRetryScheduled
        )
    }

    var body: some View {
        let mic = microphoneRow
        let accessibility = accessibilityRow
        let model = modelRow
        let canContinue = SetupChecklist.canContinue(microphone: mic, accessibility: accessibility)
        let doneCount = SetupChecklist.completedCount([mic, accessibility, model])

        VStack(spacing: BTSpacing.lg) {
            VStack(spacing: BTSpacing.sm) {
                Text("Let’s get you set up")
                    .font(.btTitle)
                    .foregroundStyle(Color.btText)
                Text("Three quick things. Each one ticks itself off when it’s done.")
                    .font(.btBody)
                    .foregroundStyle(Color.btSecondaryText)
                    .multilineTextAlignment(.center)
            }
            .btStaggered(index: 0)

            VStack(alignment: .trailing, spacing: 6) {
                Text("\(doneCount) of 3 ready")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.btSecondaryText)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .btSnappy, value: doneCount)
                BTCard {
                    VStack(spacing: 0) {
                        SetupChecklistRowView(row: mic, systemImage: "mic", action: microphoneAction(for: mic))
                        Divider().padding(.leading, 52)
                        SetupChecklistRowView(row: accessibility, systemImage: "keyboard") {
                            hasRequestedAccessibility = true
                            viewModel.onRequestAccessibilityPermission?()
                        }
                        Divider().padding(.leading, 52)
                        SetupChecklistRowView(row: model, systemImage: "waveform") {
                            viewModel.onRetryModelDownload?()
                        }
                    }
                }
            }
            .btStaggered(index: 1)

            FnConflictWarning()

            VStack(spacing: BTSpacing.sm) {
                BTButton("Continue") { onContinue() }
                    .disabled(!canContinue)
                    .opacity(canContinue ? 1 : 0.4)
                    .animation(reduceMotion ? nil : .btSnappy, value: canContinue)
                Text(SetupChecklist.continueHint(microphone: mic, accessibility: accessibility, speechModel: model))
                    .font(.btCaption)
                    .foregroundStyle(Color.btSecondaryText)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
            }
            .btStaggered(index: 2)
        }
        .padding(BTSpacing.xl)
        .task { await pollPermissions() }
        .onAppear {
            viewModel.onTrackOnboardingEvent?("onboardingStep1Setup", [:])
            viewModel.onSwitchRecordingMode?(.manual)
            viewModel.onSwitchPreset?(.stable)
            // Trigger engine download if models were cleared and no download is already running
            if viewModel.isEngineLoading && viewModel.currentEngineDownloadProgress == nil {
                viewModel.onReloadEngine?()
            }
        }
    }

    private func microphoneAction(for row: SetupChecklist.Row) -> () -> Void {
        if case .failed = row.status {
            return { viewModel.onRecheckMicrophonePermission?() }
        }
        return {
            hasRequestedMicrophone = true
            viewModel.onRequestMicrophonePermission?()
        }
    }

    /// Permissions have no change notifications; poll while the checklist is on screen.
    @MainActor
    private func pollPermissions() async {
        while !Task.isCancelled {
            viewModel.refreshPermissionState()
            viewModel.refreshFnKeySystemAction()
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            if status != microphoneStatus { microphoneStatus = status }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

// MARK: - Step 2: Try It (practice box)

private struct TryItStep: View {
    let onContinue: () -> Void
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFieldFocused: Bool
    @State private var transcribedText = ""
    @State private var revealingText: String?
    @State private var hasVoiceResult = false
    @State private var shortcutState = ShortcutSettingsState()
    @State private var showShortcutEditor = false

    private var isRecording: Bool { viewModel.appState == .recording }
    private var isBusy: Bool { isRecording || viewModel.appState == .transcribing }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your first dictation").font(.btTitle)
                Text("Hold \(viewModel.pttShortcutLabel), say a sentence, then release.")
                    .font(.btBody).foregroundStyle(Color.btSecondaryText)
                ShortcutKeycaps(
                    label: viewModel.pttShortcutLabel,
                    isPressed: viewModel.isShortcutKeycapPressed,
                    rejectionCount: viewModel.shortcutRejectionCount,
                    size: .compact
                )
                .padding(.vertical, 4)
                Text("Try: ‘A little less typing. A little more thinking.’")
                    .font(.btCaption).foregroundStyle(Color.btSecondaryText)
            }
            FnConflictWarning()
            VStack(alignment: .trailing, spacing: 8) {
                PracticeMicMeter(meter: viewModel.audioLevelMeter, isRecording: isRecording)
                TextEditor(text: $transcribedText)
                    .font(.btBody)
                    .focused($isFieldFocused)
                    .scrollContentBackground(.hidden)
                    .frame(height: 120)
                    .overlay(alignment: .topLeading) {
                        if let revealingText {
                            // Covers the editor while the words arrive, then fades to the real text.
                            WordRevealText(text: revealingText)
                                .id(revealingText)
                                .padding(.horizontal, 5)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .background(Color.btCardBackground)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                    .padding(12)
                    .background(Color.btCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(isRecording ? Color.btEmber.opacity(0.6) : Color.btBorder))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isRecording)
                    .accessibilityLabel("Dictation practice")
                    .overlay(alignment: .topLeading) {
                        if transcribedText.isEmpty {
                            Text(isRecording ? "Listening…" : "Your words will appear here.")
                                .font(.btBody).foregroundStyle(Color.btSecondaryText)
                                .padding(18).allowsHitTesting(false)
                        }
                    }
            }
            statusLine
            KeyboardSetupHelp()
            DisclosureGroup("Use a different shortcut", isExpanded: $showShortcutEditor) {
                ShortcutRecorderField(
                    title: "Hold to dictate", subtitle: "Choose a key or combination that feels natural.",
                    shortcut: shortcutState.pttShortcut.displayString,
                    captureHint: "Press a key or combination. Esc cancels.",
                    onCapture: { captured in
                        if let shortcut = shortcutState.updatePTT(keyCode: captured.keyCode,
                            modifiers: captured.modifiers.rawValue, modifierKeyCode: captured.modifierKeyCode) {
                            viewModel.onUpdatePTTShortcut?(shortcut)
                            viewModel.pttShortcutLabel = shortcut.displayString
                        }
                    },
                    onReset: {
                        let shortcut = shortcutState.resetPTT()
                        viewModel.onUpdatePTTShortcut?(shortcut)
                        viewModel.pttShortcutLabel = shortcut.displayString
                    }
                ).padding(.top, 12)
                if let error = shortcutState.shortcutError { Text(error).foregroundStyle(.red).font(.btCaption) }
            }.font(.system(size: 13, weight: .medium))
            HStack {
                Text("Mode and cleanup options are in Settings.")
                    .font(.btCaption).foregroundStyle(Color.btSecondaryText)
                Spacer()
                if hasVoiceResult {
                    BTButton("Continue", action: onContinue).disabled(isBusy)
                }
            }
        }
        .padding(.horizontal, BTSpacing.xl)
        .foregroundStyle(Color.btText)
        .onAppear {
            viewModel.isPracticeDictationActive = true
            viewModel.isOnboardingTextFieldFocused = true
            viewModel.onboardingTranscriptionResult = nil
            viewModel.onTrackOnboardingEvent?("onboardingStep2TryIt", [:])
            isFieldFocused = true
        }
        .onChange(of: isFieldFocused) { _, focused in
            viewModel.isOnboardingTextFieldFocused = focused
        }
        .onDisappear {
            viewModel.isOnboardingTextFieldFocused = false
            viewModel.isPracticeDictationActive = false
        }
        .onChange(of: viewModel.pttShortcutLabel) { _, _ in
            // Keep the recorder in sync when the fn warning switches the shortcut.
            shortcutState = ShortcutSettingsState()
        }
        .onChange(of: viewModel.onboardingTranscriptionResult) { _, result in
            guard let result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            transcribedText = result
            if !reduceMotion {
                revealingText = result
            }
            if !hasVoiceResult {
                hasVoiceResult = true
                viewModel.onTrackOnboardingEvent?("onboardingStep2Transcribed", [:])
            }
        }
        .task(id: revealingText) {
            guard let text = revealingText else { return }
            let duration = WordReveal.totalDuration(forWordCount: WordReveal.words(in: text).count)
            try? await Task.sleep(for: .seconds(duration + 0.15))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { revealingText = nil }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if hasVoiceResult {
            Label("That’s your voice, in words.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.btBody)
        } else if viewModel.isMicrophonePermissionError && !viewModel.isMicrophoneGranted {
            HStack(spacing: BTSpacing.sm) {
                Text("Blazing can’t use the microphone. Switch it on in System Settings, then try again.")
                    .font(.btCaption).foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                BTButton("Try again", style: .secondary) { viewModel.onRecheckMicrophonePermission?() }
            }
        } else if case .error(let message) = viewModel.appState, !viewModel.isMicrophonePermissionError {
            Text(message).font(.btCaption).foregroundStyle(Color.red)
        } else {
            Text(isRecording ? "Release your shortcut when you’re finished." : "Click the practice area before trying your shortcut.")
                .font(.btCaption).foregroundStyle(Color.btSecondaryText)
        }
    }
}

// MARK: - Step 3: Try it anywhere

private struct TryAnywhereStep: View {
    /// (launch at login, dictated into another app)
    let onFinish: (Bool, Bool) -> Void
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var launchAtLogin = LaunchAtLoginService.initialToggleValue
    /// Whether the first external delivery had already happened when this step appeared.
    @State private var wasDoneOnAppear: Bool?

    /// Celebrate only when the first external delivery happens while this step is on screen.
    private var celebrates: Bool { isDone && wasDoneOnAppear == false }

    private var isDone: Bool { viewModel.hasCompletedFirstExternalDelivery }
    private var label: String { viewModel.pttShortcutLabel }

    var body: some View {
        VStack(spacing: BTSpacing.lg) {
            ZStack {
                if isDone {
                    FirstDictationMark(celebrates: celebrates)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.95).combined(with: .opacity))
                } else {
                    ShortcutKeycaps(
                        label: label,
                        isPressed: viewModel.isShortcutKeycapPressed,
                        rejectionCount: viewModel.shortcutRejectionCount
                    )
                    .transition(.opacity)
                }
            }
            .frame(height: 88)

            VStack(spacing: BTSpacing.sm) {
                Text(isDone ? "That’s it. You’re dictating." : "Now try it anywhere")
                    .font(.btTitle)
                    .foregroundStyle(Color.btText)
                    .contentTransition(.opacity)
                Group {
                    if isDone {
                        Text("Your words went straight into another app. Hold \(label) whenever you’d rather talk than type.")
                    } else {
                        Text("Open Notes, Mail or any app with a text box. Click where the words should go, then hold \(label) and speak.")
                    }
                }
                .font(.btBody)
                .foregroundStyle(Color.btSecondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }

            if !isDone {
                HStack(spacing: 6) {
                    Image(systemName: "eye")
                        .font(.system(size: 11))
                    Text("We’ll notice when it works. Come back here after.")
                        .font(.btCaption)
                }
                .foregroundStyle(Color.btSecondaryText)
                .transition(.opacity)
            }

            BTCard {
                Toggle(isOn: $launchAtLogin) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open Blazing at login")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.btText)
                            Text("So your shortcut works as soon as you sign in.")
                                .font(.btCaption)
                                .foregroundStyle(Color.btSecondaryText)
                        }
                        Spacer(minLength: BTSpacing.md)
                    }
                }
                .toggleStyle(.btSwitch)
            }
            .frame(maxWidth: 420)

            if isDone {
                BTButton("Finish") { onFinish(launchAtLogin, true) }
                    .transition(.opacity)
            } else {
                BTButton("I’ll try later", style: .secondary) { onFinish(launchAtLogin, false) }
                    .transition(.opacity)
            }
        }
        .padding(BTSpacing.xl)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .btSoft, value: isDone)
        .onAppear {
            if wasDoneOnAppear == nil { wasDoneOnAppear = isDone }
            viewModel.isPracticeDictationActive = false
            viewModel.isOnboardingTextFieldFocused = false
            viewModel.onTrackOnboardingEvent?("onboardingStep3TryAnywhere", [
                "alreadyDelivered": isDone,
            ])
        }
        .onChange(of: viewModel.hasCompletedFirstExternalDelivery) { _, delivered in
            guard delivered else { return }
            viewModel.onTrackOnboardingEvent?("onboardingFirstExternalDictationSeen", [:])
        }
    }
}

/// The ✓ for a first real dictation. Ember and drawn in only when it just happened
/// (a one-time live moment); a quiet neutral check otherwise.
private struct FirstDictationMark: View {
    let celebrates: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draw: CGFloat = 0

    private var tint: Color { celebrates ? Color.btEmber : Color.btText }

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.12))
                .frame(width: 88, height: 88)
                .scaleEffect(draw > 0 ? 1 : 0.95)
            Circle()
                .trim(from: 0, to: draw)
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 60, height: 60)
                .rotationEffect(.degrees(-90))
            CheckmarkShape()
                .trim(from: 0, to: max(0, (draw - 0.5) * 2))
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .frame(width: 26, height: 20)
        }
        .accessibilityElement()
        .accessibilityLabel("First dictation done")
        .onAppear {
            if celebrates && !reduceMotion {
                withAnimation(.easeOut(duration: 0.6).delay(0.1)) { draw = 1 }
            } else {
                draw = 1
            }
        }
    }
}

// MARK: - Visual Components

private struct AnimatedWaveform: View {
    private let barCount = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Reduce Motion: a still waveform (paused timeline), no loop.
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<barCount, id: \.self) { i in
                    let phase = t * 2.2 + Double(i) * 0.55
                    let height = 12.0 + 40.0 * (0.5 + 0.5 * sin(phase))
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(
                            LinearGradient(
                                colors: [Color.btAccent, Color.btAccent.opacity(0.7)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 5, height: height)
                }
            }
        }
    }
}

private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.width * 0.38, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}


// MARK: - Step Indicator

private struct StepIndicator: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { i in
                Capsule()
                    .fill(i <= current ? Color.btAccent : Color.btBorder)
                    .frame(width: i == current ? 28 : 8, height: 4)
            }
        }
    }
}
