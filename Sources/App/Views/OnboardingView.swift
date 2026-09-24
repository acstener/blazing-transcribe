import SwiftUI
import AVFoundation
import HotkeyModule

// MARK: - Main Onboarding Router

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(AppViewModel.self) private var viewModel
    @State private var currentStep = 0

    private let totalSteps = 4

    var body: some View {
        ZStack {
            Color.btBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar: step indicator + skip
                HStack {
                    StepIndicator(current: currentStep, total: totalSteps)
                    Spacer()
                    Button(viewModel.isOnboardingPreviewActive ? "Back to Dictate" : "Set up later") { completeOnboarding(event: "onboardingSkipped", params: ["atStep": currentStep]) }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.btSecondaryText)
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, BTSpacing.xl)
                .padding(.top, BTSpacing.lg)

                ScrollView {
                Group {
                    switch currentStep {
                    case 0: WelcomeStep(onContinue: advanceStep)
                    case 1: SetupStep(onContinue: advanceStep)
                    case 2: TryItStep(onContinue: advanceStep)
                    default: TrialStep(onComplete: {
                        completeOnboarding(event: "onboardingCompleted", params: [:])
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

// MARK: - Step 1: Setup (Engine + Permissions)

private struct SetupStep: View {
    let onContinue: () -> Void
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        VStack(spacing: BTSpacing.lg) {
            Text("Setting things up")
                .font(.btTitle)
                .foregroundStyle(Color.btText)
                .btStaggered(index: 0)

            Text("We need a couple of permissions and a one-time speech model download (about 500 MB).")
                .font(.btBody)
                .foregroundStyle(Color.btSecondaryText)
                .multilineTextAlignment(.center)
                .btStaggered(index: 1)

            PermissionChecklist(showDescriptions: true)
                .btStaggered(index: 2)

            if case .error(let message) = viewModel.appState {
                Text(message).font(.btCaption).foregroundStyle(.red)
                BTButton("Retry setup", style: .secondary) { viewModel.onReloadEngine?() }
            } else if !viewModel.isEngineLoading && !viewModel.isSpeechEngineReady {
                BTButton("Prepare speech model", style: .secondary) { viewModel.onReloadEngine?() }
            }

            PermissionGatedButton(title: "Continue") {
                onContinue()
            }
            .btStaggered(index: 3)
        }
        .padding(BTSpacing.xl)
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
}

// MARK: - Step 2: Try It (with Mode + Speed Selection)

private struct TryItStep: View {
    let onContinue: () -> Void
    @Environment(AppViewModel.self) private var viewModel
    @FocusState private var isFieldFocused: Bool
    @State private var transcribedText = ""
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
            TextEditor(text: $transcribedText)
                .font(.btBody)
                .focused($isFieldFocused)
                .scrollContentBackground(.hidden)
                .frame(height: 120)
                .padding(12)
                .background(Color.btCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.btBorder))
                .accessibilityLabel("Dictation practice")
                .overlay(alignment: .topLeading) {
                    if transcribedText.isEmpty {
                        Text(isRecording ? "Listening…" : "Your words will appear here.")
                            .font(.btBody).foregroundStyle(Color.btSecondaryText)
                            .padding(18).allowsHitTesting(false)
                    }
                }
            if hasVoiceResult {
                Label("That’s your voice, in words.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.btBody)
            } else if case .error(let message) = viewModel.appState {
                Text(message).font(.btCaption).foregroundStyle(Color.red)
            } else {
                Text(isRecording ? "Release your shortcut when you’re finished." : "Click the practice area before trying your shortcut.")
                    .font(.btCaption).foregroundStyle(Color.btSecondaryText)
            }
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
            viewModel.isOnboardingTextFieldFocused = true
            viewModel.onboardingTranscriptionResult = nil
            viewModel.onTrackOnboardingEvent?("onboardingStep2TryIt", [:])
            isFieldFocused = true
        }
        .onChange(of: isFieldFocused) { _, focused in
            viewModel.isOnboardingTextFieldFocused = focused
        }
        .onDisappear { viewModel.isOnboardingTextFieldFocused = false }
        .onChange(of: viewModel.onboardingTranscriptionResult) { _, result in
            guard let result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            transcribedText = result
            if !hasVoiceResult {
                hasVoiceResult = true
                viewModel.onTrackOnboardingEvent?("onboardingStep2Transcribed", [:])
            }
        }
    }
}

// MARK: - Step 3: Free Trial

private struct TrialStep: View {
    let onComplete: () -> Void
    @Environment(AppViewModel.self) private var viewModel
    @State private var checkDraw: CGFloat = 0

    var body: some View {
        VStack(spacing: BTSpacing.lg) {
            // Animated celebration checkmark
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.1))
                    .frame(width: 88, height: 88)
                    .scaleEffect(checkDraw > 0 ? 1 : 0.5)
                    .opacity(checkDraw > 0 ? 1 : 0)

                Circle()
                    .trim(from: 0, to: checkDraw)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 60, height: 60)
                    .rotationEffect(.degrees(-90))

                CheckmarkShape()
                    .trim(from: 0, to: max(0, (checkDraw - 0.5) * 2))
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .frame(width: 26, height: 20)
            }
            .onAppear {
                withAnimation(.easeOut(duration: 0.8).delay(0.2)) { checkDraw = 1 }
            }

            Text("You\u{2019}re all set.")
                .font(.btTitle)
                .foregroundStyle(Color.btText)
                .btStaggered(index: 1)

            VStack(spacing: BTSpacing.xs) {
                Text("Click a text field in any app, then hold \(viewModel.pttShortcutLabel) and speak.")
                Text("Open Blazing from the Dock or its menu bar icon whenever you need it.")
            }
            .font(.btBody)
            .foregroundStyle(Color.btSecondaryText)
            .multilineTextAlignment(.center)
            .btStaggered(index: 2)

            BTButton("Start dictating") {
                onComplete()
            }
            .btStaggered(index: 3)
        }
        .padding(BTSpacing.xl)
        .onAppear {
            viewModel.onTrackOnboardingEvent?("onboardingStep3Trial", [:])
        }
    }
}

// MARK: - Visual Components

private struct AnimatedWaveform: View {
    private let barCount = 7

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
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

// MARK: - Permission Checklist

private struct PermissionChecklist: View {
    var showDescriptions = false
    @Environment(AppViewModel.self) private var viewModel

    private var modelDescription: String {
        if let progress = viewModel.currentEngineDownloadProgress, progress < 1 {
            let completedBytes = viewModel.currentEngineDownloadCompletedBytes
            let totalBytes = viewModel.currentEngineDownloadTotalBytes
            if totalBytes > 0 {
                let done = ByteCountFormatter.string(fromByteCount: completedBytes, countStyle: .file)
                let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
                return "Downloading speech model… \(done) of \(total)"
            }
            return "Downloading speech model…"
        }
        if viewModel.isEngineLoading {
            return "Preparing transcription models"
        }
        return viewModel.isSpeechEngineReady ? "Speech model ready" : "Speech model needs attention"
    }

    var body: some View {
        BTCard {
            VStack(spacing: 2) {
                PermissionRow(
                    label: "Local models ready",
                    description: showDescriptions ? modelDescription : nil,
                    granted: viewModel.isSpeechEngineReady,
                    showSpinner: viewModel.isEngineLoading,
                    progress: viewModel.currentEngineDownloadProgress
                )
                PermissionRow(
                    label: "Accessibility granted",
                    description: showDescriptions ? "Needed to type in any app" : nil,
                    granted: viewModel.isAccessibilityGranted,
                    actionLabel: "Grant Access",
                    action: { KeyboardInjector.requestAccessibilityPermission() }
                )
                PermissionRow(
                    label: "Microphone access",
                    description: showDescriptions ? "For speech recognition" : nil,
                    granted: viewModel.isMicrophoneGranted,
                    actionLabel: "Grant Access",
                    action: { requestMicrophoneAccess() }
                )
            }
        }
        .task { await pollPermissions() }
    }

    private func requestMicrophoneAccess() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        } else {
            // Already denied or restricted — system dialog won't show again, open Settings
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @MainActor
    private func pollPermissions() async {
        while !Task.isCancelled {
            viewModel.refreshPermissionState()
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

private struct PermissionRow: View {
    let label: String
    var description: String?
    let granted: Bool
    var showSpinner: Bool = false
    var progress: Double? = nil
    var actionLabel: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: BTSpacing.sm + 2) {
            ZStack {
                if granted {
                    Circle()
                        .fill(Color.green.opacity(0.12))
                        .frame(width: 34, height: 34)
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.green)
                } else if showSpinner {
                    Circle()
                        .fill(Color.btAccent.opacity(0.08))
                        .frame(width: 34, height: 34)
                    ProgressView()
                        .scaleEffect(0.55)
                } else {
                    Circle()
                        .strokeBorder(Color.btBorder, lineWidth: 1.5)
                        .frame(width: 34, height: 34)
                }
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 13, weight: granted ? .semibold : .medium))
                    .foregroundStyle(granted ? Color.btText : Color.btSecondaryText)
                if let description {
                    Text(description)
                        .font(.btCaption)
                        .foregroundStyle(Color.btSecondaryText.opacity(0.7))
                }
                if let progress, progress < 1, !granted {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.btBorder)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.btAccent)
                                .frame(width: geo.size.width * max(0, min(1, progress)))
                        }
                    }
                    .frame(height: 4)
                    .animation(.btSnappy, value: progress)
                }
            }

            Spacer()

            if !granted, let actionLabel, let action {
                Button(action: action) {
                    Text(actionLabel)
                        .font(.btLabel)
                        .foregroundStyle(Color.btAccent)
                        .padding(.horizontal, BTSpacing.sm + 2)
                        .padding(.vertical, 5)
                        .background(Color.btAccent.opacity(0.1))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, BTSpacing.sm + 2)
        .padding(.vertical, BTSpacing.sm)
        .animation(.btSpring, value: granted)
    }
}

// MARK: - Permission-Gated Button

private struct PermissionGatedButton: View {
    let title: String
    let action: () -> Void
    @Environment(AppViewModel.self) private var viewModel

    private var canContinue: Bool {
        viewModel.isSpeechEngineReady && !viewModel.isEngineLoading &&
        viewModel.isAccessibilityGranted &&
        viewModel.isMicrophoneGranted
    }

    private var waitingMessage: String {
        if viewModel.isEngineLoading {
            return "Setting up..."
        }

        let missingPermissions = [
            viewModel.isAccessibilityGranted ? nil : "Accessibility access",
            viewModel.isMicrophoneGranted ? nil : "Microphone access",
        ].compactMap { $0 }

        guard !missingPermissions.isEmpty else {
            return "Waiting for permissions..."
        }

        return "Waiting for \(missingPermissions.joined(separator: " + "))..."
    }

    var body: some View {
        if canContinue {
            BTButton(title, action: action)
        } else {
            Text(waitingMessage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.btSecondaryText)
                .padding(.horizontal, BTSpacing.md)
                .padding(.vertical, BTSpacing.sm)
                .background(Color.btBorder.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: BTSpacing.buttonCornerRadius))
        }
    }
}

