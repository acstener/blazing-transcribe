import SwiftUI
import AVFoundation

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
                    Button("Skip") { completeOnboarding(event: "onboardingSkipped", params: ["atStep": currentStep]) }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.btSecondaryText)
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, BTSpacing.xl)
                .padding(.top, BTSpacing.lg)

                Spacer()

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
                .frame(maxWidth: 520)

                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

                Text("The fastest local transcription tool for Mac.")
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

            Text("We need a couple of permissions and a small model download.")
                .font(.btBody)
                .foregroundStyle(Color.btSecondaryText)
                .multilineTextAlignment(.center)
                .btStaggered(index: 1)

            PermissionChecklist(showDescriptions: true)
                .btStaggered(index: 2)

            PermissionGatedButton(title: "Continue") {
                viewModel.onSwitchRecordingMode?(.manual)
                onContinue()
            }
            .btStaggered(index: 3)
        }
        .padding(BTSpacing.xl)
        .onAppear {
            viewModel.onTrackOnboardingEvent?("onboardingStep1Setup", [:])
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
    @State private var hasTrackedFirstTranscription = false

    private var isRecording: Bool { viewModel.appState == .recording }
    private var hasResult: Bool { !transcribedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var isTurbo: Bool { viewModel.transcriptionPreset == .powerUserFastest }

    private var instructionText: String {
        if viewModel.recordingMode == .alwaysOn {
            return "Start speaking \u{2014} it\u{2019}ll pick up your voice automatically."
        }
        if isTurbo {
            return "Hold fn and start speaking. Text appears as you talk."
        }
        return "Hold fn, say something, release."
    }

    var body: some View {
        VStack(spacing: BTSpacing.md) {
            Text("Try it out")
                .font(.btTitle)
                .foregroundStyle(Color.btText)
                .btStaggered(index: 0)

            // Mode + Speed picker
            BTCard {
                VStack(alignment: .leading, spacing: BTSpacing.md) {
                    VStack(alignment: .leading, spacing: BTSpacing.sm) {
                        Text("Mode")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.btSecondaryText)
                            .textCase(.uppercase)

                        HStack(spacing: BTSpacing.sm) {
                            ModeOption(
                                icon: "mic.fill",
                                title: "Manual",
                                subtitle: "Hold fn to record",
                                isSelected: viewModel.recordingMode == .manual
                            ) {
                                viewModel.onSwitchRecordingMode?(.manual)
                            }

                            ModeOption(
                                icon: "waveform",
                                title: "Always-on",
                                subtitle: "VAD auto-detects speech",
                                isSelected: viewModel.recordingMode == .alwaysOn
                            ) {
                                viewModel.onSwitchRecordingMode?(.alwaysOn)
                            }
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: BTSpacing.sm) {
                        Text("Speed")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.btSecondaryText)
                            .textCase(.uppercase)

                        HStack(spacing: BTSpacing.sm) {
                            ModeOption(
                                icon: "checkmark.shield.fill",
                                title: "Stable",
                                subtitle: "Accurate, reliable",
                                isSelected: viewModel.transcriptionPreset == .stable
                            ) {
                                viewModel.onSwitchPreset?(.stable)
                            }

                            ModeOption(
                                icon: "hare.fill",
                                title: "Turbo",
                                subtitle: "Fastest, realtime",
                                isSelected: viewModel.transcriptionPreset == .powerUserFastest
                            ) {
                                viewModel.onSwitchPreset?(.powerUserFastest)
                            }
                        }
                    }
                }
            }
            .btStaggered(index: 1)

            // Instruction text adapts to mode + speed
            Text(instructionText)
                .font(.btBody)
                .foregroundStyle(Color.btSecondaryText)
                .multilineTextAlignment(.center)

            // Real text field — keyboard injector types directly into this
            TextEditor(text: $transcribedText)
                .font(.btBody)
                .foregroundStyle(Color.btText)
                .focused($isFieldFocused)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 100, maxHeight: 140)
                .padding(BTSpacing.sm)
                .background(Color.btCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: BTSpacing.cardCornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: BTSpacing.cardCornerRadius)
                        .stroke(
                            isRecording ? Color.accentColor.opacity(0.6) : (hasResult ? Color.accentColor.opacity(0.5) : Color.btBorder),
                            lineWidth: isRecording || hasResult ? 1.5 : 1
                        )
                        .animation(.btSnappy, value: isRecording)
                )
                .btShadowSubtle()
                .overlay(alignment: .center) {
                    if transcribedText.isEmpty {
                        Text("Your words will appear here...")
                            .font(.btBody)
                            .foregroundStyle(Color.btSecondaryText.opacity(0.4))
                            .allowsHitTesting(false)
                    }
                }
                .btStaggered(index: 2)

            HStack {
                BTButton("Skip", style: .secondary) { onContinue() }
                Spacer()
                if hasResult {
                    BTButton("Continue \u{2192}") { onContinue() }
                }
            }
        }
        .padding(.horizontal, BTSpacing.xl)
        .padding(.vertical, BTSpacing.md)
        .onAppear {
            viewModel.onTrackOnboardingEvent?("onboardingStep2TryIt", [:])
            // Delay focus to ensure TextEditor is fully in the responder chain
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isFieldFocused = true
            }
        }
        .onChange(of: transcribedText) { _, text in
            if !text.isEmpty && !hasTrackedFirstTranscription {
                hasTrackedFirstTranscription = true
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
                Text("Blazing Transcribe is free to use.")
                Text("No account required. No strings attached.")
            }
            .font(.btBody)
            .foregroundStyle(Color.btSecondaryText)
            .multilineTextAlignment(.center)
            .btStaggered(index: 2)

            BTButton("Start Using Blazing Transcribe") {
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
                                colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
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
                    .fill(i <= current ? Color.accentColor : Color.btBorder)
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
            let completed = viewModel.currentEngineDownloadCompletedFiles
            let total = viewModel.currentEngineDownloadTotalFiles
            return total > 0 ? "Downloading \(completed)/\(total) files..." : "Downloading models..."
        }
        if viewModel.isEngineLoading {
            return "Preparing transcription models"
        }
        return "Transcription models loaded"
    }

    var body: some View {
        BTCard {
            VStack(spacing: 2) {
                PermissionRow(
                    label: "Local models ready",
                    description: showDescriptions ? modelDescription : nil,
                    granted: !viewModel.isEngineLoading,
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
            viewModel.isAccessibilityGranted = KeyboardInjector.hasAccessibilityPermission
            viewModel.isMicrophoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
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
                        .fill(Color.accentColor.opacity(0.08))
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
                                .fill(Color.accentColor)
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
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, BTSpacing.sm + 2)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.1))
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
        !viewModel.isEngineLoading &&
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

