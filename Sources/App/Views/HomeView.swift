import SwiftUI

/// Display capture truth separately from the speech engine's readiness.
enum MicrophonePresentation: Equatable {
    case off, standby, handsFree, recording, transcribing, preparing, needsAttention

    static func resolve(state: AppState.State, captureRunning: Bool, engineReady: Bool,
                        loading: Bool, permissionsGranted: Bool, mode: RecordingMode) -> Self {
        if case .error = state { return .needsAttention }
        if !permissionsGranted { return .needsAttention }
        if loading { return .preparing }
        if state == .recording { return .recording }
        if state == .transcribing { return .transcribing }
        if !engineReady { return .preparing }
        guard captureRunning else { return .off }
        return mode == .alwaysOn ? .handsFree : .standby
    }

    var title: String {
        switch self {
        case .off: return "Mic off"
        case .standby: return "Mic active · fast standby"
        case .handsFree: return "Listening · hands-free"
        case .recording: return "Recording"
        case .transcribing: return "Transcribing"
        case .preparing: return "Preparing dictation"
        case .needsAttention: return "Needs attention"
        }
    }
}

struct DashboardView: View {
    @Environment(AppViewModel.self) private var model
    @Environment(TabSelection.self) private var selection
    @State private var history = TranscriptionHistoryViewModel()
    @State private var copied = false

    private var status: MicrophonePresentation {
        .resolve(state: model.appState, captureRunning: model.isCaptureRunning,
                 engineReady: model.isSpeechEngineReady, loading: model.isEngineLoading,
                 permissionsGranted: model.isAccessibilityGranted && model.isMicrophoneGranted,
                 mode: model.recordingMode)
    }

    private var guidance: String {
        switch status {
        case .off:
            return model.recordingMode == .alwaysOn
                ? "Listening is paused. Resume the microphone when you’re ready."
                : "The microphone will start when you dictate."
        case .standby: return "The microphone stays active for faster starts. macOS shows its mic indicator."
        case .handsFree: return "Speech is typed into your focused app. Pause the mic whenever you need."
        case .recording: return "Speak naturally. Your words are on their way."
        case .transcribing: return "Turning your speech into text."
        case .preparing: return "Your speech model is getting ready."
        case .needsAttention:
            if case .error(let message) = model.appState { return message }
            return "Finish microphone and Accessibility setup to dictate into other apps."
        }
    }

    private var headline: String {
        switch status {
        case .recording: return "Listening to you"
        case .transcribing: return "Finding your words"
        case .preparing: return "Getting ready"
        case .needsAttention: return "Let’s get you set up"
        case .handsFree: return "Ready when you are"
        case .off where model.recordingMode == .alwaysOn: return "Listening is paused"
        default: return "Ready to dictate"
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 20) {
                    ZStack {
                        Circle().fill(Color.btCardBackground).frame(width: 76, height: 76)
                        Circle().stroke(Color.btBorder, lineWidth: 1).frame(width: 76, height: 76)
                        if status == .needsAttention {
                            Image(systemName: "exclamationmark")
                                .font(.system(size: 28, weight: .light))
                                .foregroundStyle(Color.btText)
                        } else {
                            BlazingMark().fill(Color.btText).frame(width: 29, height: 38)
                        }
                    }
                    .accessibilityHidden(true)
                    VStack(spacing: 10) {
                        Text(headline).font(.system(size: 29, weight: .semibold))
                        Text(model.recordingMode == .manual
                             ? "Hold your shortcut. Speak. Release."
                             : "Speak into the text field you’re working in.")
                            .font(.system(size: 14)).foregroundStyle(Color.btSecondaryText)
                    }
                    if model.recordingMode == .manual {
                        Button {
                            selection.settingsSection = "Shortcuts"
                            selection.current = .general
                        } label: {
                            Text(model.pttShortcutLabel)
                        }
                        .buttonStyle(ShortcutKeycapButtonStyle(
                            label: model.pttShortcutLabel,
                            isPressed: model.isShortcutKeycapPressed,
                            rejectionCount: model.shortcutRejectionCount
                        ))
                            .help("Change your dictation shortcut")
                            .accessibilityLabel("Dictation shortcut: \(model.pttShortcutLabel). Change shortcut")
                    }
                    if status == .needsAttention || status == .preparing {
                        BTButton("Continue setup") { model.onOpenOnboardingPreview?() }
                    } else {
                        Button("Try a dictation") { model.onOpenOnboardingPreview?() }
                            .font(.system(size: 13, weight: .medium))
                            .buttonStyle(.plain).foregroundStyle(Color.btSecondaryText)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 48).padding(.bottom, 32)

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("RECENT").font(.system(size: 10, weight: .semibold)).tracking(1.5)
                        Spacer()
                        Button { selection.current = .history } label: {
                            Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .medium))
                        }.buttonStyle(.plain).help("Open history").accessibilityLabel("Open history")
                    }.foregroundStyle(Color.btSecondaryText)
                    if let entry = history.entries.first(where: { $0.succeeded && !$0.dismissed && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                        // macOS selectable Text can draw the full selection outside a
                        // line-limited layout. Keep this a bounded preview; Copy below
                        // still copies the complete transcript.
                        Text(entry.text.rangeOfCharacter(from: .alphanumerics) == nil ? "No words transcribed." : entry.text)
                            .font(.system(size: 15))
                            .lineSpacing(4)
                            .lineLimit(3)
                            .truncationMode(.tail)
                            .textSelection(.disabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .clipped()
                        HStack {
                            Text(entry.timestamp, format: .dateTime.hour().minute()).font(.system(size: 11))
                            Spacer()
                            if entry.text.rangeOfCharacter(from: .alphanumerics) == nil {
                                Button("View in history") { selection.current = .history }
                                    .font(.system(size: 12, weight: .medium)).buttonStyle(.plain)
                            } else {
                                Button {
                                    history.copyToClipboard(entry)
                                    withAnimation(.btSnappy) { copied = true }
                                } label: {
                                    // Reserve the wider label's width so the button never shifts.
                                    ZStack(alignment: .trailing) {
                                        Label("Copied", systemImage: "checkmark").hidden()
                                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                            .contentTransition(.symbolEffect(.replace))
                                    }
                                    .labelStyle(.titleAndIcon)
                                }
                                .font(.system(size: 12, weight: .medium)).buttonStyle(.plain)
                                .task(id: copied) {
                                    guard copied else { return }
                                    try? await Task.sleep(for: .seconds(2))
                                    withAnimation(.btSoft) { copied = false }
                                }
                            }
                        }.foregroundStyle(Color.btSecondaryText)
                    } else {
                        Text("A little less typing.")
                            .font(.system(size: 15, weight: .medium))
                        Text("Your first dictation will appear here.")
                            .font(.system(size: 13)).foregroundStyle(Color.btSecondaryText)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.btBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.btBorder.opacity(0.65), lineWidth: 1))

                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: model.isCaptureRunning ? "mic" : "mic.slash")
                    Text(status.title).font(.system(size: 12))
                    Spacer(minLength: 8)
                    if model.recordingMode == .alwaysOn || model.isCaptureRunning {
                        Button(model.isCaptureRunning ? "Pause" : "Resume") {
                            model.onToggleListening?(); model.refreshPermissionState()
                        }.buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                            .disabled(model.appState == .transcribing)
                    }
                }
                .foregroundStyle(Color.btSecondaryText)
                .padding(.horizontal, 6).padding(.top, 20)
                .help(guidance)
                .accessibilityElement(children: .contain)
                .accessibilityHint(guidance)
                if status == .needsAttention {
                    Text(guidance).font(.btCaption).foregroundStyle(Color.btSecondaryText).padding(.top, 12)
                }
            }
            .foregroundStyle(Color.btText)
            .padding(.horizontal, 40).padding(.bottom, 28)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .onAppear { history.loadRecent() }
        .onReceive(NotificationCenter.default.publisher(for: .transcriptionHistoryDidChange)) { _ in
            history.loadRecent(); copied = false
        }
    }
}
